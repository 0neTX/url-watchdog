#!/bin/bash
# ============================================================
#  telegram-bot.sh — Bot Telegram para control del watchdog
#  Versión: 2.2.1
# ============================================================
VERSION="2.2.1"

set -o pipefail

ENV_FILE="/etc/url-watchdog/.env"
COMMON_LIB="/usr/local/bin/url-watchdog-common.sh"

if [ ! -f "$ENV_FILE" ]; then
  echo "[ERROR] No se encuentra: $ENV_FILE" >&2; exit 1
fi
if [ ! -f "$COMMON_LIB" ]; then
  echo "[ERROR] Librería no encontrada: $COMMON_LIB" >&2
  echo "[ERROR] Ejecuta el instalador o copia el fichero manualmente." >&2
  exit 1
fi

# shellcheck source=/usr/local/bin/url-watchdog-common.sh
source "$COMMON_LIB"
load_env "$ENV_FILE"

require_vars "telegram-bot.sh" \
  TELEGRAM_TOKEN TELEGRAM_CHAT_ID ALLOWED_CHAT_IDS \
  LOG_FILE LOG_MAX_BYTES BOT_OFFSET_FILE BOT_POLL_TIMEOUT \
  BOT_START_REASON_FILE BOT_PID_FILE \
  STATE_DIR STATE_FILE STATE_WAN_FILE STATE_FRITZ_FILE STATE_SILENCE_FILE \
  STATE_FRITZ_UPTIME_FILE STATE_CONFIRM_FILE NOTIFY_QUEUE_FILE \
  STATE_PARTIAL_FAIL_FILE STATE_LAN_FAIL_FILE \
  FRITZ_IP FRITZ_USER FRITZ_PASSWORD \
  FRITZ_WAN_WAIT_MINUTES FRITZ_WAIT_MINUTES HTTP_TIMEOUT \
  CONFIRM_TIMEOUT LOG_DEFAULT_LINES HISTORY_DEFAULT_N \
  INCIDENTS_FILE TRACEROUTE_DEFAULT_HOST SPEEDTEST_URLS \
  TELEGRAM_MAX_RETRIES TELEGRAM_RETRY_DELAY \
  UPDATE_URL_COMMON UPDATE_URL_WATCHDOG UPDATE_URL_BOT \
  UPDATE_URL_REPORT UPDATE_URL_CHECKSUMS

IFS=',' read -ra URL_ARRAY <<< "$URLS"
BL="[BOT]"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

rotate_log
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
mkdir -p "$(dirname "$BOT_OFFSET_FILE")"

# Precalcular array de IDs autorizados
IFS=',' read -ra ALLOWED_IDS_ARRAY <<< "$ALLOWED_CHAT_IDS"
for i in "${!ALLOWED_IDS_ARRAY[@]}"; do
  ALLOWED_IDS_ARRAY[$i]=$(echo "${ALLOWED_IDS_ARRAY[$i]}" | tr -d '[:space:]')
done

# --- Motivo de arranque -------------------------------------

detect_start_reason() {
  if [ -f "$BOT_START_REASON_FILE" ]; then
    local stored_reason
    stored_reason=$(cat "$BOT_START_REASON_FILE")
    rm -f "$BOT_START_REASON_FILE"
    [ "$stored_reason" = "update" ] && { echo "update"; return; }
  fi
  local uptime_secs
  uptime_secs=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 9999)
  [ "$uptime_secs" -lt 300 ] && { echo "boot"; return; }
  if [ -f "$BOT_PID_FILE" ]; then
    local prev_pid
    prev_pid=$(cat "$BOT_PID_FILE" 2>/dev/null || echo "")
    if [ -n "$prev_pid" ] && ! kill -0 "$prev_pid" 2>/dev/null; then
      local exit_code
      exit_code=$(systemctl show telegram-bot.service \
        --property=ExecMainStatus 2>/dev/null | cut -d= -f2)
      [ "${exit_code:-0}" != "0" ] && { echo "crash"; return; }
      echo "manual_restart"; return
    fi
  fi
  echo "unknown"
}

notify_start_reason() {
  local reason="$1" emoji msg
  case "$reason" in
    boot)           emoji="🟢"; msg="Arranque inicial del sistema" ;;
    manual_restart) emoji="🔄"; msg="Reinicio manual (systemctl restart)" ;;
    crash)          emoji="💥"; msg="Reinicio tras caída inesperada (crash)" ;;
    update)         emoji="⬆️"; msg="Reinicio tras actualización (/update)" ;;
    *)              emoji="❓"; msg="Motivo de arranque desconocido" ;;
  esac
  log "$BL Arrancado v${VERSION}. Motivo: ${msg}"
  telegram_notify "${emoji} *Bot Watchdog v${VERSION} — Arrancado*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

*Motivo:* ${msg}"
}

# --- Autorización -------------------------------------------

is_authorized() {
  local chat_id="$1" id
  for id in "${ALLOWED_IDS_ARRAY[@]}"; do
    [ "$chat_id" = "$id" ] && return 0
  done
  return 1
}

# --- Polling ------------------------------------------------

get_updates() {
  local offset="$1"
  _curl_telegram_api "getUpdates" \
    --max-time "$(( BOT_POLL_TIMEOUT + 5 ))" \
    --get \
    --data-urlencode "timeout=${BOT_POLL_TIMEOUT}" \
    --data-urlencode "offset=${offset}" \
    --data-urlencode "allowed_updates=message"
}

parse_updates() {
  jq -r '
    if .ok then
      .result[] |
      [
        (.update_id | tostring),
        (.message.chat.id  | tostring),
        (.message.from.username // "desconocido"),
        (.message.text // "" | gsub("\n"; "↵"))
      ] | join("\u0001")
    else empty end
  ' 2>/dev/null
}

# --- Helpers de diagnóstico ---------------------------------

# Comprueba una URL y devuelve "OK|HTTP|ms" o "FAIL|motivo"
_check_url_detail() {
  local url="$1"
  local raw_out http_code time_sec time_ms curl_exit reason
  raw_out=$(curl --silent --max-time 15 \
    --output /dev/null \
    --write-out "%{http_code}|%{time_total}" \
    --connect-timeout 5 "$url" 2>/dev/null)
  curl_exit=$?
  http_code="${raw_out%%|*}"
  time_sec="${raw_out##*|}"
  time_ms=$(awk "BEGIN {printf \"%d\", ${time_sec:-0} * 1000}" 2>/dev/null || echo "?")

  if [[ "$http_code" =~ ^[2-3][0-9]{2}$ ]]; then
    printf 'OK|%s|%s' "$http_code" "$time_ms"
  else
    case "$curl_exit" in
      6)  reason="DNS no resuelto" ;;
      7)  reason="Conexión rechazada" ;;
      28) reason="Timeout (>15s)" ;;
      35) reason="Error SSL/TLS" ;;
      *)  reason="HTTP ${http_code:-000} (exit ${curl_exit})" ;;
    esac
    printf 'FAIL|%s' "$reason"
  fi
}

# --- Handlers -----------------------------------------------

# /ping [url] — sin argumento: comprueba todas las URLs del watchdog (#9)
cmd_ping() {
  local chat_id="$1" url="${2:-}"

  if [ -z "$url" ]; then
    # Modo sin argumento: comprobar todas las URLs monitorizadas
    telegram_send "$chat_id" "⏳ Comprobando todas las URLs monitorizadas..."
    log "$BL [ping] Comprobando todas las URLs"
    local lines=""
    for u in "${URL_ARRAY[@]}"; do
      u=$(echo "$u" | tr -d '[:space:]')
      local detail label
      detail=$(_check_url_detail "$u")
      label=$(printf '%s' "$u" | sed 's|https\?://||' | cut -d'/' -f1)
      if [[ "$detail" == OK* ]]; then
        local hcode="${detail#OK|}"; hcode="${hcode%%|*}"
        local ms="${detail##*|}"
        lines+="  ✅ \`${label}\` — HTTP ${hcode} (${ms}ms)\n"
      else
        local reason="${detail#FAIL|}"
        lines+="  ❌ \`${label}\` — ${reason}\n"
      fi
    done
    telegram_send "$chat_id" "📡 *Ping — URLs del watchdog*

$(printf '%b' "$lines")"
    return
  fi

  # Modo con argumento: URL concreta
  [[ "$url" =~ ^https?:// ]] || url="https://${url}"
  telegram_send "$chat_id" "⏳ Comprobando \`${url}\`..."
  log "$BL [ping] Comprobando ${url}"

  local detail
  detail=$(_check_url_detail "$url")
  if [[ "$detail" == OK* ]]; then
    local hcode="${detail#OK|}"; hcode="${hcode%%|*}"
    local ms="${detail##*|}"
    telegram_send "$chat_id" "✅ *Ping OK*
  • URL: \`${url}\`
  • HTTP: ${hcode}
  • Tiempo: ${ms} ms"
  else
    local reason="${detail#FAIL|}"
    telegram_send "$chat_id" "❌ *Ping FALLÓ*
  • URL: \`${url}\`
  • Motivo: ${reason}"
  fi
}

cmd_traceroute() {
  local chat_id="$1" host="${2:-$TRACEROUTE_DEFAULT_HOST}"
  if ! [[ "$host" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    telegram_send "$chat_id" "❌ Host inválido."; return
  fi
  telegram_send "$chat_id" "⏳ Ejecutando traceroute a \`${host}\`... (puede tardar hasta 30s)"
  log "$BL [traceroute] Destino: ${host}"

  local result
  result=$(traceroute -m 20 -w 2 -q 1 "$host" 2>&1 | head -30) || true

  if [ -z "${result:-}" ]; then
    telegram_send "$chat_id" "❌ traceroute no disponible. Instálalo con: \`apt install traceroute\`"
    return
  fi
  [ "${#result}" -gt 3500 ] && result="${result:0:3500}
...(truncado)"
  telegram_send "$chat_id" "🔍 *Traceroute → \`${host}\`*
\`\`\`
${result}
\`\`\`"
}

cmd_speedtest() {
  local chat_id="$1"
  telegram_send "$chat_id" "⏳ Midiendo velocidad de descarga... (puede tardar 20-30s)"
  log "$BL [speedtest] Iniciando test de descarga"

  IFS=',' read -ra ST_URLS <<< "$SPEEDTEST_URLS"
  local results=() url label speed_mbps elapsed_ms bytes_dl

  for url in "${ST_URLS[@]}"; do
    url=$(echo "$url" | tr -d '[:space:]')
    label=$(echo "$url" | sed 's|https\?://||' | cut -d'/' -f1)

    local start_ts end_ts
    start_ts=$(date +%s%3N)
    bytes_dl=$(curl --silent --max-time 20 --location --output /dev/null \
      --write-out "%{size_download}" "$url" 2>/dev/null) || bytes_dl=0
    end_ts=$(date +%s%3N)

    elapsed_ms=$(( end_ts - start_ts ))
    [ "$elapsed_ms" -le 0 ] && elapsed_ms=1

    if [ "${bytes_dl:-0}" -gt 0 ]; then
      speed_mbps=$(awk "BEGIN {printf \"%.1f\", ($bytes_dl * 8) / ($elapsed_ms * 1000)}")
      results+=("  • ${label}: *${speed_mbps} Mbps*")
      log "$BL [speedtest] ${label}: ${speed_mbps} Mbps (${bytes_dl} bytes en ${elapsed_ms}ms)"
    else
      results+=("  • ${label}: ❌ sin respuesta")
      log "$BL [speedtest] ${label}: sin respuesta"
    fi
  done

  telegram_send "$chat_id" "📶 *Test de velocidad (bajada)*

$(printf '%s\n' "${results[@]}")

_Ficheros de 10MB descargados desde CDNs públicos_"
}

cmd_history() {
  local chat_id="$1" arg="${2:-$HISTORY_DEFAULT_N}"
  local n="$HISTORY_DEFAULT_N" filter=""

  # Soporte para /history --failed (#9)
  if [ "$arg" = "--failed" ] || [ "$arg" = "-f" ]; then
    filter="--failed"
    n="$HISTORY_DEFAULT_N"
  elif [[ "$arg" =~ ^[0-9]+$ ]]; then
    n="$arg"
  fi
  [ "$n" -gt 50 ] && n=50

  log "$BL [history] Consultando últimos ${n} incidentes${filter:+ (solo con acciones)}"

  if [ ! -f "$INCIDENTS_FILE" ]; then
    telegram_send "$chat_id" "ℹ️ No hay historial de incidentes aún."
    return
  fi

  local history
  history=$(incident_history "$n" "$filter")
  [ "${#history}" -gt 3800 ] && \
    history="${history:0:3800}
...(truncado, usa /history con un número menor)"

  local title="📜 *Historial de incidentes (últimos ${n})*"
  [ -n "$filter" ] && title="📜 *Historial — incidentes con acciones (últimos ${n})*"

  telegram_send "$chat_id" "${title}

${history}"
}

# /stats [days] — estadísticas desde incidents.json (#6)
cmd_stats() {
  local chat_id="$1" period="${2:-30}"
  [[ "$period" =~ ^[0-9]+$ ]] || period=30
  [ "$period" -gt 365 ] && period=365

  log "$BL [stats] Estadísticas de los últimos ${period} días"

  if [ ! -f "$INCIDENTS_FILE" ]; then
    telegram_send "$chat_id" "ℹ️ No hay historial de incidentes aún."
    return
  fi

  local raw
  raw=$(incident_stats "$period" 0)
  local total n_resolved avg_dur max_dur n_wan n_fritz n_server n_spont n_active
  IFS='|' read -r total n_resolved avg_dur max_dur n_wan n_fritz n_server n_spont n_active <<< "$raw"

  # Uptime estimado basado en tiempo total de downtime vs período
  local uptime_pct="100.00"
  if [ "${n_resolved:-0}" -gt 0 ] && [ "${avg_dur:-0}" -gt 0 ]; then
    uptime_pct=$(awk "BEGIN {
      total_down = ${avg_dur} * ${n_resolved}
      period_min = ${period} * 1440
      pct = 100 - (total_down / period_min * 100)
      if (pct < 0) pct = 0
      printf \"%.2f\", pct
    }")
  fi

  # Comparativa con período anterior (#10 weekly usa esto también)
  local raw_prev
  raw_prev=$(incident_stats "$period" "$period")
  local prev_total
  IFS='|' read -r prev_total _ <<< "$raw_prev"

  local trend_arrow=""
  if [ "${prev_total:-0}" -gt 0 ]; then
    if [ "${total:-0}" -lt "$prev_total" ]; then
      trend_arrow=" ↘️ (vs ${prev_total} anterior)"
    elif [ "${total:-0}" -gt "$prev_total" ]; then
      trend_arrow=" ↗️ (vs ${prev_total} anterior)"
    else
      trend_arrow=" → (igual que período anterior)"
    fi
  fi

  telegram_send "$chat_id" "📊 *Estadísticas — últimos ${period} días*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

*Incidentes:* ${total}${trend_arrow}
  • Resueltos: ${n_resolved}
  • Activos: ${n_active}
  • Espontáneos: ${n_spont}

*Tiempos:*
  • Duración media: ${avg_dur} min
  • Duración máxima: ${max_dur} min
  • Uptime estimado: \`${uptime_pct}%\`

*Acciones tomadas:*
  • Reconexiones WAN: ${n_wan}
  • Reboots Fritz: ${n_fritz}
  • Reboots servidor: ${n_server}

_Fuente: \`${INCIDENTS_FILE}\`_"
}

# /version (#13 / #20)
cmd_version() {
  local chat_id="$1"
  local common_ver watchdog_ver bot_ver report_ver
  common_ver=$(grep  -m1 '^VERSION=' /usr/local/bin/url-watchdog-common.sh \
    2>/dev/null | cut -d'"' -f2 || echo "?")
  watchdog_ver=$(grep -m1 '^VERSION=' /usr/local/bin/url-watchdog.sh \
    2>/dev/null | cut -d'"' -f2 || echo "?")
  bot_ver=$(grep     -m1 '^VERSION=' /usr/local/bin/telegram-bot.sh \
    2>/dev/null | cut -d'"' -f2 || echo "?")
  report_ver=$(grep  -m1 '^VERSION=' /usr/local/bin/url-watchdog-report.sh \
    2>/dev/null | cut -d'"' -f2 || echo "?")

  telegram_send "$chat_id" "ℹ️ *Versiones instaladas*

  • url-watchdog-common.sh: \`${common_ver}\`
  • url-watchdog.sh: \`${watchdog_ver}\`
  • telegram-bot.sh: \`${bot_ver}\`
  • url-watchdog-report.sh: \`${report_ver}\`"

  log "$BL [version] Consulta de versiones desde chat ${chat_id}."
}

cmd_help() {
  local chat_id="$1"
  telegram_send "$chat_id" "🤖 *Proxmox Watchdog Bot v${VERSION}*

*Consulta*
  /status — estado del watchdog
  /fritz — info de la FritzBox
  /ip — IP pública actual
  /log [n|tail] — últimas N líneas o seguimiento 60s
  /schedule — próxima ejecución del watchdog
  /history [n|--failed] — últimos N incidentes (--failed: solo con acciones)
  /stats [days] — estadísticas e incidentes (default: 30 días)
  /version — versiones de scripts instalados

*Diagnóstico*
  /ping [url] — comprobar URL(s); sin argumento: todas las monitorizadas
  /traceroute [host] — trazar ruta hasta un host
  /speedtest — test de velocidad de descarga
  /diagnose — diagnóstico completo (LAN, Fritz, URLs, log)

*Acciones*
  /reset — limpiar estado de fallo
  /silence [min|status|off] — silenciar, ver estado o desactivar silencio
  /restart wan — reconexión WAN forzada + informe en ${FRITZ_WAN_WAIT_MINUTES} min
  /restart router — reboot FritzBox + informe en ${FRITZ_WAIT_MINUTES} min
  /restart server — reboot del servidor (requiere /confirm)
  /reboot\_fritz — reboot Fritz sin informe posterior
  /reboot\_server — reboot servidor sin informe posterior
  /update — actualizar scripts desde GitHub

⚠️ /restart server y /reboot\_server requieren /confirm en ${CONFIRM_TIMEOUT}s"
}

cmd_status() {
  local chat_id="$1" current_ip
  current_ip=$(get_public_ip || echo "no disponible")
  telegram_send "$chat_id" "$(build_status_message "📊 *Estado del Watchdog*" "$current_ip")"
}

cmd_fritz() {
  local chat_id="$1"
  telegram_send "$chat_id" "⏳ Consultando FritzBox..."
  local fritz_result fritz_ok
  fritz_result=$(get_fritz_info false) || true; fritz_ok=$?
  if [ "$fritz_ok" -eq 0 ]; then
    IFS='|' read -r _ model router_uptime wan_status wan_uptime _ <<< "$fritz_result"
    telegram_send "$chat_id" "📡 *FritzBox \`${FRITZ_IP}\`*
  • Modelo: ${model}
  • Uptime router: ${router_uptime}
  • Estado WAN: ${wan_status}
  • Uptime conexión: ${wan_uptime}"
  else
    case "$fritz_result" in
      auth_error) telegram_send "$chat_id" "❌ Credenciales incorrectas." ;;
      conn_error) telegram_send "$chat_id" "❌ No se pudo conectar a \`${FRITZ_IP}\`." ;;
      *)          telegram_send "$chat_id" "❌ Error inesperado." ;;
    esac
  fi
}

cmd_ip() {
  local chat_id="$1" ip
  if ip=$(get_public_ip); then
    telegram_send "$chat_id" "🌐 IP pública: \`${ip}\`"
  else
    telegram_send "$chat_id" "❌ No se pudo obtener la IP pública."
  fi
}

# /log [n|tail] — sin arg: default lines, tail: seguimiento 60s (#9)
cmd_log() {
  local chat_id="$1" n="${2:-$LOG_DEFAULT_LINES}"

  if [ "$n" = "tail" ]; then
    if [ ! -f "$LOG_FILE" ]; then
      telegram_send "$chat_id" "❌ El fichero de log no existe aún."; return
    fi
    local initial_lines
    initial_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    telegram_send "$chat_id" "📋 *Log — seguimiento activo 60s*
Actualizaré en +30s y +60s si hay nuevas entradas."
    log "$BL [log tail] Iniciado desde chat ${chat_id}, línea inicial: ${initial_lines}"
    (
      sleep 30
      local cur new_lines n_new
      cur=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
      n_new=$(( cur - initial_lines ))
      if [ "$n_new" -gt 0 ]; then
        new_lines=$(tail -n "$n_new" "$LOG_FILE" 2>/dev/null)
        [ "${#new_lines}" -gt 3500 ] && new_lines="...(truncado)
$(printf '%s' "$new_lines" | tail -c 3500)"
        telegram_send "$chat_id" "📋 *Log +30s*
\`\`\`
${new_lines}
\`\`\`"
      else
        telegram_send "$chat_id" "ℹ️ *Log +30s:* sin nuevas entradas."
      fi
      # Reanclar al valor actual para que +60s solo muestre lo nuevo desde +30s
      # (independiente de rotaciones que puedan haber ocurrido antes de +30s)
      local base_after_30s="$cur"
      sleep 30
      local cur2 n_new2
      cur2=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
      n_new2=$(( cur2 - base_after_30s ))
      if [ "$n_new2" -gt 0 ]; then
        local extra
        extra=$(tail -n "$n_new2" "$LOG_FILE" 2>/dev/null)
        [ "${#extra}" -gt 3500 ] && extra="...(truncado)
$(printf '%s' "$extra" | tail -c 3500)"
        telegram_send "$chat_id" "📋 *Log +60s*
\`\`\`
${extra}
\`\`\`"
      else
        telegram_send "$chat_id" "ℹ️ *Log +60s:* sin nuevas entradas."
      fi
    ) &
    return
  fi

  [[ "$n" =~ ^[0-9]+$ ]] || n="$LOG_DEFAULT_LINES"
  [ "$n" -gt 100 ] && n=100
  if [ ! -f "$LOG_FILE" ]; then
    telegram_send "$chat_id" "❌ El fichero de log no existe aún."; return
  fi
  local lines
  lines=$(tail -n "$n" "$LOG_FILE")
  if [ "${#lines}" -gt 3800 ]; then
    lines="...(truncado)
$(echo "$lines" | tail -c 3500)"
  fi
  telegram_send "$chat_id" "📋 *Últimas ${n} líneas del log:*
\`\`\`
${lines}
\`\`\`"
}

cmd_schedule() {
  local chat_id="$1" timer_info
  timer_info=$(systemctl list-timers url-watchdog.timer --no-pager 2>/dev/null \
    | grep url-watchdog \
    | awk '{print "Próxima: "$1" "$2"\nÚltima: "$5" "$6}') || true
  [ -z "${timer_info:-}" ] && \
    timer_info="Timer no encontrado. Ejecuta: systemctl status url-watchdog.timer"
  telegram_send "$chat_id" "🕐 *Planificación del Watchdog*

${timer_info}

*Intervalo:* cada 1 minuto"
}

cmd_reset() {
  local chat_id="$1" removed=()
  for f in "$STATE_FILE" "$STATE_WAN_FILE" "$STATE_FRITZ_FILE" "${STATE_LAN_FAIL_FILE:-}"; do
    [ -f "$f" ] && rm -f "$f" && removed+=("$(basename "$f")")
  done
  if [ ${#removed[@]} -eq 0 ]; then
    telegram_send "$chat_id" "ℹ️ No había estado activo que limpiar."
  else
    telegram_send "$chat_id" "✅ Estado limpiado: \`${removed[*]}\`"
    log "$BL [reset] Estado limpiado por Telegram."
  fi
}

# /silence [min|status|off] (#9)
cmd_silence() {
  local chat_id="$1" arg="${2:-30}"

  if [ "$arg" = "status" ]; then
    if [ ! -f "$STATE_SILENCE_FILE" ]; then
      telegram_send "$chat_id" "ℹ️ No hay silencio activo."; return
    fi
    local silence_until now remaining
    silence_until=$(_read_state_ts "$STATE_SILENCE_FILE")
    now=$(date +%s)
    if [ "$now" -lt "$silence_until" ]; then
      remaining=$(( (silence_until - now) / 60 ))
      telegram_send "$chat_id" "🔕 *Silencio activo:* ${remaining} min restantes."
    else
      rm -f "$STATE_SILENCE_FILE"
      telegram_send "$chat_id" "ℹ️ El silencio ya ha expirado."
    fi
    return
  fi

  if [ "$arg" = "off" ]; then
    if [ -f "$STATE_SILENCE_FILE" ]; then
      rm -f "$STATE_SILENCE_FILE"
      telegram_send "$chat_id" "🔔 Silencio desactivado. Las notificaciones están activas."
      log "$BL [silence] Silencio desactivado desde Telegram."
    else
      telegram_send "$chat_id" "ℹ️ No había silencio activo."
    fi
    return
  fi

  local minutes="$arg"
  [[ "$minutes" =~ ^[0-9]+$ ]] || minutes=30
  [ "$minutes" -gt 1440 ] && minutes=1440
  _write_state "$STATE_SILENCE_FILE" "$(( $(date +%s) + minutes * 60 ))"
  telegram_send "$chat_id" "🔕 Notificaciones silenciadas durante *${minutes} minutos*.
Usa \`/silence status\` para ver el tiempo restante, o \`/silence off\` para desactivar."
  log "$BL [silence] Silencio ${minutes} min activado desde Telegram."
}

cmd_reboot_fritz() {
  local chat_id="$1"
  telegram_send "$chat_id" "⏳ Enviando reboot a FritzBox..."
  if reboot_fritzbox; then
    telegram_send "$chat_id" "✅ Reboot de FritzBox enviado."
    log "$BL [reboot_fritz] Reboot Fritz desde Telegram."
  else
    telegram_send "$chat_id" "❌ No se pudo enviar el reboot a la FritzBox."
  fi
}

_confirm_set() {
  local chat_id="$1" op="$2"
  _write_state "$STATE_CONFIRM_FILE" "${chat_id}|$(date +%s)|${op}"
}

cmd_reboot_server() {
  local chat_id="$1"
  _confirm_set "$chat_id" "reboot_server"
  telegram_send "$chat_id" "⚠️ *¿Reiniciar el servidor?*

Envía /confirm en los próximos *${CONFIRM_TIMEOUT} segundos* para confirmar.
Cualquier otro mensaje cancelará la operación."
  log "$BL [reboot_server] Solicitud de reboot desde chat ${chat_id}. Esperando /confirm."
}

cmd_confirm() {
  local chat_id="$1"
  if [ ! -f "$STATE_CONFIRM_FILE" ]; then
    telegram_send "$chat_id" "ℹ️ No hay ninguna operación pendiente."; return
  fi

  local stored_chat stored_ts stored_op
  IFS='|' read -r stored_chat stored_ts stored_op < "$STATE_CONFIRM_FILE"

  if [ "$chat_id" != "$stored_chat" ]; then
    telegram_send "$chat_id" "❌ No tienes operación pendiente."; return
  fi

  [[ "$stored_ts" =~ ^[0-9]+$ ]] || stored_ts=0
  local elapsed=$(( $(date +%s) - stored_ts ))
  if [ "$elapsed" -gt "$CONFIRM_TIMEOUT" ]; then
    rm -f "$STATE_CONFIRM_FILE"
    telegram_send "$chat_id" "⏰ Confirmación expirada (${CONFIRM_TIMEOUT}s). Repite el comando."
    log "$BL [confirm] Confirmación de '${stored_op}' expirada tras ${elapsed}s."
    return
  fi

  rm -f "$STATE_CONFIRM_FILE"

  case "${stored_op:-reboot_server}" in
    reboot_server|restart_server)
      telegram_send "$chat_id" "🔴 Reiniciando servidor en 5 segundos..."
      log "$BL [confirm] REBOOT SERVIDOR confirmado (op: ${stored_op}). Reiniciando..."
      sleep 5
      /sbin/reboot
      ;;
    *)
      telegram_send "$chat_id" "❌ Operación desconocida: ${stored_op}."
      ;;
  esac
}

# ---- /diagnose — diagnóstico completo (#12) ----------------
cmd_diagnose() {
  local chat_id="$1"
  telegram_send "$chat_id" "🔍 Ejecutando diagnóstico completo... (puede tardar 30s)"
  log "$BL [diagnose] Diagnóstico completo solicitado desde chat ${chat_id}"

  # IP pública
  local current_ip
  current_ip=$(get_public_ip 2>/dev/null || echo "no disponible")

  # LAN y gateway (#1)
  local gateway gw_line
  gateway=$(ip route get 1.1.1.1 2>/dev/null | awk '/via/ {print $3}' | head -1)
  if [ -z "$gateway" ]; then
    gw_line="❌ Sin ruta por defecto"
  elif ping -c 1 -W 2 "$gateway" > /dev/null 2>&1; then
    gw_line="✅ Gateway \`${gateway}\` responde"
  else
    gw_line="❌ Gateway \`${gateway}\` no responde"
  fi

  # Fritz
  local fritz_result fritz_ok fritz_line
  fritz_result=$(get_fritz_info false) || true; fritz_ok=$?
  if [ "$fritz_ok" -eq 0 ]; then
    IFS='|' read -r _ model router_uptime wan_status wan_uptime _ <<< "$fritz_result"
    fritz_line="✅ ${model} — WAN: ${wan_status} — Uptime: ${router_uptime}"
  else
    fritz_line="❌ No accesible (${fritz_result})"
  fi

  # URLs con latencia (#5)
  local url_lines=""
  for u in "${URL_ARRAY[@]}"; do
    u=$(echo "$u" | tr -d '[:space:]')
    local detail label
    detail=$(_check_url_detail "$u")
    label=$(printf '%s' "$u" | sed 's|https\?://||' | cut -d'/' -f1)
    if [[ "$detail" == OK* ]]; then
      local hcode="${detail#OK|}"; hcode="${hcode%%|*}"
      local ms="${detail##*|}"
      url_lines+="  ✅ \`${label}\` — HTTP ${hcode} (${ms}ms)\n"
    else
      local reason="${detail#FAIL|}"
      url_lines+="  ❌ \`${label}\` — ${reason}\n"
    fi
  done

  # TLS próximos a expirar
  local tls_lines=""
  if command -v openssl > /dev/null 2>&1; then
    local warn_days="${CERT_EXPIRY_WARN_DAYS:-14}"
    local now_ts
    now_ts=$(date +%s)
    for u in "${URL_ARRAY[@]}"; do
      u=$(echo "$u" | tr -d '[:space:]')
      [[ "$u" =~ ^https:// ]] || continue
      local host expiry_date expiry_ts days_left
      host=$(printf '%s' "$u" | sed 's|https://||' | cut -d'/' -f1 | cut -d':' -f1)
      expiry_date=$(echo | timeout 4 openssl s_client -connect "${host}:443" \
        -servername "$host" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      [ -z "$expiry_date" ] && continue
      expiry_ts=$(date -d "$expiry_date" +%s 2>/dev/null) || continue
      days_left=$(( (expiry_ts - now_ts) / 86400 ))
      if [ "$days_left" -le 0 ]; then
        tls_lines+="  ❌ \`${host}\` — EXPIRADO\n"
      elif [ "$days_left" -le "$warn_days" ]; then
        tls_lines+="  ⚠️ \`${host}\` — ${days_left} días\n"
      else
        tls_lines+="  ✅ \`${host}\` — ${days_left} días\n"
      fi
    done
  fi

  # Últimas 5 líneas del log
  local last_log=""
  [ -f "$LOG_FILE" ] && last_log=$(tail -n 5 "$LOG_FILE" 2>/dev/null \
    | sed 's/\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] //')

  local tls_section=""
  [ -n "$tls_lines" ] && tls_section="
*Certificados TLS:*
$(printf '%b' "$tls_lines")"

  telegram_send "$chat_id" "🔍 *Diagnóstico completo*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

*IP pública:* \`${current_ip}\`
*LAN:* ${gw_line}

*FritzBox:* ${fritz_line}

*URLs monitorizadas:*
$(printf '%b' "$url_lines")${tls_section}
*Últimas entradas del log:*
\`\`\`
${last_log}
\`\`\`"
}

# ---- /restart wan|router|server ----------------------------

_restart_status_report() {
  local target="$1" chat_id="$2"
  local current_ip connectivity fritz_section ok_count=0 fail_count=0

  for url in "${URL_ARRAY[@]}"; do
    url=$(echo "$url" | tr -d '[:space:]')
    local code
    code=$(curl --silent --max-time "$HTTP_TIMEOUT" --output /dev/null \
      --write-out "%{http_code}" "$url" 2>/dev/null) || true
    if [[ "${code:-000}" =~ ^[2-3][0-9]{2}$ ]]; then
      (( ok_count++ )) || true
    else
      (( fail_count++ )) || true
    fi
  done
  local total=$(( ok_count + fail_count ))

  if   [ "$fail_count" -eq 0 ]; then connectivity="✅ Conectividad OK (${ok_count}/${total} URLs)"
  elif [ "$ok_count"   -eq 0 ]; then connectivity="❌ Sin conectividad (0/${total} URLs)"
  else                               connectivity="⚠️ Parcial: ${ok_count}/${total} URLs"
  fi

  current_ip=$(get_public_ip 2>/dev/null || echo "no disponible")

  fritz_section=""
  if [ "$target" != "server" ]; then
    local fritz_result fritz_ok
    fritz_result=$(get_fritz_info false) || true; fritz_ok=$?
    if [ "$fritz_ok" -eq 0 ]; then
      IFS='|' read -r _ model router_uptime wan_status wan_uptime _ <<< "$fritz_result"
      fritz_section="
*FritzBox:*
  • Estado WAN: ${wan_status}
  • Uptime router: ${router_uptime}
  • Uptime conexión: ${wan_uptime}"
    else
      fritz_section="
*FritzBox:* ❌ No accesible aún"
    fi
  fi

  telegram_send "$chat_id" "📋 *Estado tras /restart ${target}*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

${connectivity}
*IP pública:* \`${current_ip}\`${fritz_section}"
  log "$BL [restart/${target}] Informe post-reinicio. Conectividad: ${connectivity}"
}

cmd_restart() {
  local chat_id="$1" target="${2:-}"

  case "$target" in

    wan)
      local lockfile="${STATE_DIR}/restart-wan.lock"
      if [ -f "$lockfile" ]; then
        telegram_send "$chat_id" "⚠️ Ya hay una operación /restart wan en curso."
        return
      fi
      log "$BL [restart/wan] Reconexión WAN solicitada desde Telegram."
      telegram_send "$chat_id" "🔌 *Reconexión WAN forzada*

Enviando ForceTermination + RequestConnection a la FritzBox...
Comprobaré el estado en *${FRITZ_WAN_WAIT_MINUTES} min*."
      (
        touch "$lockfile"
        trap 'rm -f "$lockfile"' EXIT
        if force_wan_reconnect; then
          log "$BL [restart/wan] WAN enviada. Esperando ${FRITZ_WAN_WAIT_MINUTES} min..."
          timeout "$(( FRITZ_WAN_WAIT_MINUTES * 60 + 30 ))" \
            sleep "$(( FRITZ_WAN_WAIT_MINUTES * 60 ))" || true
          _restart_status_report "wan" "$chat_id"
        else
          log "$BL [restart/wan] No se pudo forzar reconexión WAN."
          telegram_send "$chat_id" "❌ *Reconexión WAN fallida*

No se pudo contactar con la FritzBox en \`${FRITZ_IP}\`.
Comprueba que el acceso TR-064 está habilitado."
        fi
      ) &
      ;;

    router)
      local lockfile="${STATE_DIR}/restart-router.lock"
      if [ -f "$lockfile" ]; then
        telegram_send "$chat_id" "⚠️ Ya hay una operación /restart router en curso."
        return
      fi
      log "$BL [restart/router] Reboot FritzBox solicitado desde Telegram."
      telegram_send "$chat_id" "🔄 *Reboot FritzBox*

Enviando comando de reboot a \`${FRITZ_IP}\`...
Comprobaré el estado en *${FRITZ_WAIT_MINUTES} min*."
      (
        touch "$lockfile"
        trap 'rm -f "$lockfile"' EXIT
        if reboot_fritzbox; then
          log "$BL [restart/router] Reboot Fritz enviado. Esperando ${FRITZ_WAIT_MINUTES} min..."
          timeout "$(( FRITZ_WAIT_MINUTES * 60 + 30 ))" \
            sleep "$(( FRITZ_WAIT_MINUTES * 60 ))" || true
          _restart_status_report "router" "$chat_id"
        else
          log "$BL [restart/router] No se pudo enviar reboot."
          telegram_send "$chat_id" "❌ *Reboot FritzBox fallido*

No se pudo contactar con la FritzBox en \`${FRITZ_IP}\`."
        fi
      ) &
      ;;

    server)
      _confirm_set "$chat_id" "restart_server"
      telegram_send "$chat_id" "⚠️ *¿Reiniciar el servidor?*

Envía /confirm en los próximos *${CONFIRM_TIMEOUT} segundos* para confirmar.
Cualquier otro mensaje cancelará la operación.

_Nota: el bot enviará la notificación de arranque cuando el servidor vuelva._"
      log "$BL [restart/server] Solicitud reboot servidor desde chat ${chat_id}."
      ;;

    ""|*)
      telegram_send "$chat_id" "❌ Uso: /restart <wan|router|server>

  /restart wan — reconexión WAN forzada
  /restart router — reboot completo de la FritzBox
  /restart server — reboot del servidor (requiere /confirm en ${CONFIRM_TIMEOUT}s)"
      ;;
  esac
}

# ---- /update con verificación SHA256 -----------------------

cmd_update() {
  local chat_id="$1"
  telegram_send "$chat_id" "⬆️ Iniciando actualización de scripts..."
  log "$BL [update] Actualización iniciada desde Telegram por chat ${chat_id}."

  local checksums_tmp
  checksums_tmp=$(_mktemp_secure "sha256sums")
  local http_code
  http_code=$(curl --silent --max-time 30 \
    --write-out "%{http_code}" \
    --output "$checksums_tmp" \
    "$UPDATE_URL_CHECKSUMS" 2>/dev/null) || http_code="000"

  if [ "$http_code" != "200" ] || [ ! -s "$checksums_tmp" ]; then
    rm -f "$checksums_tmp"
    telegram_send "$chat_id" "❌ No se pudo descargar SHA256SUMS (HTTP ${http_code}).
Actualización cancelada. Comprueba UPDATE\_URL\_CHECKSUMS en el .env."
    log "$BL [update] ❌ Fallo descargando SHA256SUMS (HTTP ${http_code})."
    return
  fi

  local -a SCRIPT_NAMES=(
    "url-watchdog-common.sh"
    "url-watchdog.sh"
    "telegram-bot.sh"
    "url-watchdog-report.sh"
  )
  local -A SCRIPT_URLS=(
    ["url-watchdog-common.sh"]="$UPDATE_URL_COMMON"
    ["url-watchdog.sh"]="$UPDATE_URL_WATCHDOG"
    ["telegram-bot.sh"]="$UPDATE_URL_BOT"
    ["url-watchdog-report.sh"]="$UPDATE_URL_REPORT"
  )

  local failed=0

  for script in "${SCRIPT_NAMES[@]}"; do
    local url="${SCRIPT_URLS[$script]}"
    local dest="/usr/local/bin/${script}"
    local tmp
    tmp=$(_mktemp_secure "update-${script}")

    local dl_code
    dl_code=$(curl --silent --max-time 30 \
      --write-out "%{http_code}" --output "$tmp" \
      "$url" 2>/dev/null) || dl_code="000"

    if [ "$dl_code" != "200" ] || [ ! -s "$tmp" ]; then
      log "$BL [update] ❌ Fallo descargando ${script} (HTTP ${dl_code})."
      rm -f "$tmp"; (( failed++ )) || true; continue
    fi

    local expected_hash
    expected_hash=$(grep "[[:space:]]${script}$" "$checksums_tmp" \
      | awk '{print $1}' | head -1)
    if [ -z "${expected_hash:-}" ]; then
      log "$BL [update] ❌ ${script} no encontrado en SHA256SUMS."
      rm -f "$tmp"; (( failed++ )) || true; continue
    fi

    local actual_hash
    actual_hash=$(sha256sum "$tmp" | awk '{print $1}')
    if [ "$actual_hash" != "$expected_hash" ]; then
      log "$BL [update] ❌ ${script}: hash no coincide (esperado ${expected_hash}, obtenido ${actual_hash})."
      rm -f "$tmp"; (( failed++ )) || true; continue
    fi

    if ! bash -n "$tmp" 2>/dev/null; then
      log "$BL [update] ❌ ${script}: errores de sintaxis bash."
      rm -f "$tmp"; (( failed++ )) || true; continue
    fi

    local new_ver
    new_ver=$(grep -m1 '^VERSION=' "$tmp" 2>/dev/null | cut -d'"' -f2 || echo "?")
    mv "$tmp" "$dest" && chmod +x "$dest"
    log "$BL [update] ✅ ${script} actualizado a v${new_ver}."
  done

  rm -f "$checksums_tmp"

  if [ "$failed" -gt 0 ]; then
    telegram_send "$chat_id" "⚠️ Actualización completada con *${failed} errores*.
Revisa el log con /log. Los scripts con error NO fueron reemplazados."
    log "$BL [update] Completada con ${failed} errores."
    return
  fi

  telegram_send "$chat_id" "✅ Scripts actualizados y verificados. Recargando servicios..."
  systemctl daemon-reload

  printf 'update\n' > "$BOT_START_REASON_FILE"
  printf '%s\n' "$$" > "$BOT_PID_FILE"

  telegram_send "$chat_id" "♻️ Reiniciando bot con la nueva versión..."
  log "$BL [update] Reiniciando bot..."

  systemctl restart telegram-bot.service &
  sleep 2
  exit 0
}

# --- Dispatcher ---------------------------------------------

dispatch_command() {
  local chat_id="$1" username="$2" text="$3"
  local cmd arg
  cmd=$(echo "$text" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
  arg=$(echo "$text" | awk '{print $2}')
  cmd="${cmd%%@*}"

  log "$BL [cmd] chat=${chat_id} user=@${username} cmd=${cmd}${arg:+ arg=${arg}}"

  case "$cmd" in
    /help)          cmd_help "$chat_id" ;;
    /status)        cmd_status "$chat_id" ;;
    /fritz)         cmd_fritz "$chat_id" ;;
    /ip)            cmd_ip "$chat_id" ;;
    /log)           cmd_log "$chat_id" "$arg" ;;
    /schedule)      cmd_schedule "$chat_id" ;;
    /history)       cmd_history "$chat_id" "$arg" ;;
    /stats)         cmd_stats "$chat_id" "$arg" ;;
    /version)       cmd_version "$chat_id" ;;
    /ping)          cmd_ping "$chat_id" "$arg" ;;
    /traceroute)    cmd_traceroute "$chat_id" "$arg" ;;
    /speedtest)     cmd_speedtest "$chat_id" ;;
    /diagnose)      cmd_diagnose "$chat_id" ;;
    /reset)         cmd_reset "$chat_id" ;;
    /silence)       cmd_silence "$chat_id" "$arg" ;;
    /restart)       cmd_restart "$chat_id" "$arg" ;;
    /reboot_fritz)  cmd_reboot_fritz "$chat_id" ;;
    /reboot_server) cmd_reboot_server "$chat_id" ;;
    /confirm)       cmd_confirm "$chat_id" ;;
    /update)        cmd_update "$chat_id" ;;
    /start)         cmd_help "$chat_id" ;;
    *)
      if [ -f "$STATE_CONFIRM_FILE" ]; then
        local stored_chat
        stored_chat=$(cut -d'|' -f1 "$STATE_CONFIRM_FILE")
        if [ "$chat_id" = "$stored_chat" ]; then
          rm -f "$STATE_CONFIRM_FILE"
          telegram_send "$chat_id" "❌ Operación cancelada."
          log "$BL [confirm] Cancelada por mensaje inesperado."
          return
        fi
      fi
      telegram_send "$chat_id" "❓ Comando no reconocido. Usa /help."
      ;;
  esac
}

# --- Bucle principal ----------------------------------------

START_REASON=$(detect_start_reason)
printf '%s\n' "$$" > "$BOT_PID_FILE"
flush_notification_queue
notify_start_reason "$START_REASON"

log "$BL Escuchando comandos... (PID: $$, v${VERSION})"

offset=0
[ -f "$BOT_OFFSET_FILE" ] && offset=$(cat "$BOT_OFFSET_FILE")

while true; do
  response=$(get_updates "$offset") || response=""

  if ! printf '%s' "$response" | jq -e '.ok == true' > /dev/null 2>&1; then
    log "$BL Error al obtener updates. Reintentando en 10s..."
    sleep 10
    continue
  fi

  while IFS=$'\x01' read -r update_id chat_id username text; do
    [ -z "${update_id:-}" ] && continue

    offset=$(( update_id + 1 ))
    printf '%s\n' "$offset" > "$BOT_OFFSET_FILE"

    [ -z "${text:-}" ] && continue

    log "$BL [recv] update_id=${update_id} chat=${chat_id} user=@${username} text=$(printf '%s' "$text" | head -c 200)"

    if ! is_authorized "$chat_id"; then
      log "$BL [auth] DENEGADO — chat=${chat_id} user=@${username}"
      continue
    fi

    [[ "$text" == /* ]] && dispatch_command "$chat_id" "$username" "$text"

  done < <(printf '%s' "$response" | parse_updates)

done
