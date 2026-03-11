#!/bin/bash
# ============================================================
#  url-watchdog.sh — Reinicia el servidor si las URLs fallan
#  Versión: 2.2.0
# ============================================================
# Uso:
#   url-watchdog.sh            → ejecución normal (systemd timer)
#   url-watchdog.sh --test     → notificación de prueba + info Fritz
#   url-watchdog.sh --status   → estado actual por consola y Telegram
#   url-watchdog.sh --reset    → limpia el estado de fallo activo
# ============================================================
VERSION="2.3.0"

set -uo pipefail

ENV_FILE="/etc/url-watchdog/.env"
COMMON_LIB="/usr/local/bin/url-watchdog-common.sh"
MODE="normal"

for arg in "$@"; do
  case "$arg" in
    --test|--status|--reset) MODE="${arg:2}" ;;
    *) echo "[ERROR] Argumento desconocido: $arg" >&2; exit 1 ;;
  esac
done

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

require_vars "url-watchdog.sh" \
  URLS MAX_FAIL_MINUTES HTTP_TIMEOUT FAIL_MODE \
  STATE_DIR STATE_FILE STATE_IP_FILE STATE_WAN_FILE STATE_FRITZ_FILE \
  STATE_SILENCE_FILE STATE_FRITZ_UPTIME_FILE STATE_LAN_FAIL_FILE \
  STATE_IP_CHANGES_FILE STATE_PARTIAL_FAIL_FILE STATE_TLS_CHECK_FILE \
  NOTIFY_QUEUE_FILE \
  LOG_FILE LOG_MAX_BYTES \
  FRITZ_IP FRITZ_USER FRITZ_PASSWORD \
  FRITZ_WAN_WAIT_MINUTES FRITZ_WAIT_MINUTES \
  TELEGRAM_MAX_RETRIES TELEGRAM_RETRY_DELAY \
  IP_CHANGE_ALERT_THRESHOLD INSTABILITY_THRESHOLD CERT_EXPIRY_WARN_DAYS

# Validar FAIL_MODE (#2 quorum)
[[ "$FAIL_MODE" =~ ^(all|any|quorum)$ ]] || {
  echo "[ERROR] FAIL_MODE debe ser 'all', 'any' o 'quorum'. Valor actual: '${FAIL_MODE}'" >&2
  exit 1
}

IFS=',' read -ra URL_ARRAY <<< "$URLS"

# Validar FAIL_QUORUM si mode=quorum (#2)
if [ "$FAIL_MODE" = "quorum" ]; then
  [[ "${FAIL_QUORUM:-}" =~ ^[0-9]+$ ]] || {
    echo "[ERROR] FAIL_MODE=quorum requiere FAIL_QUORUM definido como entero >= 1." >&2
    exit 1
  }
  [ "${FAIL_QUORUM}" -ge 1 ] || {
    echo "[ERROR] FAIL_QUORUM debe ser >= 1." >&2; exit 1
  }
  [ "${FAIL_QUORUM}" -le "${#URL_ARRAY[@]}" ] || {
    echo "[ERROR] FAIL_QUORUM (${FAIL_QUORUM}) no puede superar el número de URLs (${#URL_ARRAY[@]})." >&2
    exit 1
  }
fi

# Asegurar LOG_FILE con directorio existente
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

rotate_log

# Asegurar STATE_DIR
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"

# Defaults para variables de modo dual (compatibilidad con .env de versiones anteriores)
: "${WATCHDOG_INTERVAL_MINUTES:=5}"
: "${STATE_WATCHMODE_FILE:=${STATE_DIR}/watchdog.watchmode}"
: "${STATE_LASTRUN_FILE:=${STATE_DIR}/watchdog.lastrun}"

[[ "$WATCHDOG_INTERVAL_MINUTES" =~ ^[0-9]+$ ]] && [ "$WATCHDOG_INTERVAL_MINUTES" -ge 1 ] || {
  echo "[ERROR] WATCHDOG_INTERVAL_MINUTES debe ser un entero >= 1 (actual: '${WATCHDOG_INTERVAL_MINUTES}')." >&2
  exit 1
}

# ============================================================
# FAILED_URL_COUNT: set by check_urls(), used by check_instability()
FAILED_URL_COUNT=0

# check_urls: comprueba todas las URLs.
# Efectos secundarios:
#   - Registra en log OK/FALLO con latencia (#5)
#   - Actualiza FAILED_URL_COUNT (global, para check_instability)
# Retorna: 0 = dentro del umbral (no actuar), 1 = supera umbral (actuar)
check_urls() {
  local failed=0 total=${#URL_ARRAY[@]} url raw_out http_code time_sec time_ms curl_exit reason
  for url in "${URL_ARRAY[@]}"; do
    url=$(echo "$url" | tr -d '[:space:]')

    # Capturar código HTTP y latencia en una sola llamada (#5)
    raw_out=$(curl --silent --max-time "$HTTP_TIMEOUT" \
      --output /dev/null \
      --write-out "%{http_code}|%{time_total}" \
      "$url" 2>/dev/null)
    curl_exit=$?

    http_code="${raw_out%%|*}"
    time_sec="${raw_out##*|}"
    time_ms=$(awk "BEGIN {printf \"%d\", ${time_sec:-0} * 1000}" 2>/dev/null || echo "?")

    if [[ "$http_code" =~ ^[2-3][0-9]{2}$ ]]; then
      log "OK        $url (HTTP ${http_code}, ${time_ms}ms)"
    else
      case "$curl_exit" in
        6)  reason="DNS no resuelto" ;;
        7)  reason="Conexión rechazada" ;;
        28) reason="Timeout (>${HTTP_TIMEOUT}s)" ;;
        35) reason="Error SSL/TLS" ;;
        *)
          if   [ "$http_code" = "000" ];    then reason="Sin respuesta (curl exit ${curl_exit})"
          elif [[ "$http_code" =~ ^5 ]];    then reason="Error servidor (HTTP ${http_code})"
          elif [[ "$http_code" =~ ^4 ]];    then reason="Error cliente (HTTP ${http_code})"
          else                                   reason="HTTP ${http_code} (curl exit ${curl_exit})"
          fi ;;
      esac
      log "FALLO     $url — ${reason}"
      (( failed++ )) || true
    fi
  done

  FAILED_URL_COUNT=$failed

  if   [ "$FAIL_MODE" = "all" ]    && [ "$failed" -eq "$total" ]; then return 1
  elif [ "$FAIL_MODE" = "any" ]    && [ "$failed" -gt 0 ];        then return 1
  elif [ "$FAIL_MODE" = "quorum" ] && [ "$failed" -ge "${FAIL_QUORUM:-2}" ]; then return 1
  fi
  return 0
}

check_fritz_unexpected_reboot() {
  [ ! -f "$STATE_FRITZ_UPTIME_FILE" ] && return
  [ -f "$STATE_FRITZ_FILE" ] && return  # fuimos nosotros

  local stored last_uptime_secs last_ts
  stored=$(cat "$STATE_FRITZ_UPTIME_FILE" 2>/dev/null || echo "0|0")
  IFS='|' read -r last_uptime_secs last_ts <<< "$stored"

  [[ "$last_uptime_secs" =~ ^[0-9]+$ ]] || return
  [[ "$last_ts" =~ ^[0-9]+$ ]]           || return

  local now elapsed_since_check
  now=$(date +%s)
  elapsed_since_check=$(( now - last_ts ))

  local check_interval="${FRITZ_REBOOT_CHECK_INTERVAL:-300}"
  [ "$elapsed_since_check" -lt "$check_interval" ] && return

  local raw http_code body
  raw=$(fritz_soap_call "/upnp/control/deviceinfo" \
    "urn:dslforum-org:service:DeviceInfo:1" "GetInfo")
  http_code=$(printf '%s' "$raw" | head -1)
  [ "$http_code" != "200" ] && return
  body=$(printf '%s' "$raw" | tail -n +2)

  local current_uptime_secs
  current_uptime_secs=$(xml_field "$body" "NewUpTime")
  [[ "${current_uptime_secs:-}" =~ ^[0-9]+$ ]] || return

  if [ "$current_uptime_secs" -lt 300 ]; then
    local current_fmt
    current_fmt=$(format_uptime "$current_uptime_secs")
    log "[FRITZ] ⚠️  Reboot inesperado detectado. Uptime actual: ${current_fmt}"
    telegram_notify "⚠️ *Proxmox Watchdog — Reboot inesperado de FritzBox*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

La FritzBox se reinició sin ser solicitada por el watchdog.
*Uptime actual:* ${current_fmt}"
  fi

  _write_state "$STATE_FRITZ_UPTIME_FILE" "${current_uptime_secs}|${now}"
}

check_ip_anomaly() {
  local current_ip="$1"
  [ -z "$current_ip" ] && return
  local today
  today=$(date '+%Y-%m-%d')
  local stored_date stored_count
  if [ -f "$STATE_IP_CHANGES_FILE" ]; then
    IFS='|' read -r stored_date stored_count < "$STATE_IP_CHANGES_FILE"
    if [ "$stored_date" = "$today" ]; then
      [[ "$stored_count" =~ ^[0-9]+$ ]] || stored_count=0
      stored_count=$(( stored_count + 1 ))
      _write_state "$STATE_IP_CHANGES_FILE" "${today}|${stored_count}"
      if [ "$stored_count" -ge "$IP_CHANGE_ALERT_THRESHOLD" ]; then
        log "[IP] ⚠️  IP cambiada ${stored_count} veces hoy (umbral: ${IP_CHANGE_ALERT_THRESHOLD})"
        telegram_notify "⚠️ *Proxmox Watchdog — Anomalía de IP*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

La IP pública ha cambiado \`${stored_count}\` veces hoy (umbral: \`${IP_CHANGE_ALERT_THRESHOLD}\`).
Puede indicar inestabilidad en la conexión del ISP."
      fi
      return
    fi
  fi
  _write_state "$STATE_IP_CHANGES_FILE" "${today}|1"
}

check_public_ip() {
  local current_ip
  if ! current_ip=$(get_public_ip); then
    log "[IP] No se pudo obtener la IP pública. Se omite la comprobación."
    return
  fi
  if [ ! -f "$STATE_IP_FILE" ]; then
    _write_state "$STATE_IP_FILE" "$current_ip"
    log "[IP] IP pública registrada: ${current_ip}"
    telegram_notify "$(build_status_message "✅ *Proxmox Watchdog — Arranque*" "$current_ip")"
    return
  fi
  local previous_ip
  previous_ip=$(cat "$STATE_IP_FILE")
  if [ "$current_ip" != "$previous_ip" ]; then
    _write_state "$STATE_IP_FILE" "$current_ip"
    log "[IP] ⚠️  IP cambiada: ${previous_ip} → ${current_ip}"
    check_ip_anomaly "$current_ip"
    telegram_notify "🌐 *Proxmox Watchdog — IP cambiada*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

*Anterior:* \`${previous_ip}\`
*Nueva:* \`${current_ip}\`"
  fi
}

# ---------- MODOS ESPECIALES --------------------------------

if [ "$MODE" = "test" ]; then
  log "[TEST] Iniciando comprobación... (v${VERSION})"
  flush_notification_queue
  current_ip=$(get_public_ip || echo "no disponible")
  fritz_result=$(get_fritz_info) || true
  fritz_ok=$?
  if [ "$fritz_ok" -eq 0 ]; then
    IFS='|' read -r _ fritz_model fritz_router_uptime fritz_wan_status fritz_wan_uptime _ \
      <<< "$fritz_result"
    fritz_block="
*FritzBox \`${FRITZ_IP}\`:*
  • Modelo: ${fritz_model}
  • Uptime router: ${fritz_router_uptime}
  • Estado WAN: ${fritz_wan_status}
  • Uptime conexión: ${fritz_wan_uptime}"
  else
    case "$fritz_result" in
      auth_error) fritz_block="
*FritzBox \`${FRITZ_IP}\`:* ❌ Credenciales incorrectas" ;;
      conn_error) fritz_block="
*FritzBox \`${FRITZ_IP}\`:* ❌ No se pudo conectar" ;;
      *)          fritz_block="
*FritzBox \`${FRITZ_IP}\`:* ❌ Error inesperado" ;;
    esac
  fi
  msg=$(build_status_message "🔧 *Proxmox Watchdog — Test (v${VERSION})*" \
    "$current_ip" "$fritz_block")
  telegram_notify "$msg" && log "[TEST] OK." || log "[TEST] Fallo al enviar."
  exit 0
fi

if [ "$MODE" = "status" ]; then
  current_ip=$(get_public_ip || echo "no disponible")
  msg=$(build_status_message "📊 *Proxmox Watchdog — Estado (v${VERSION})*" "$current_ip")
  echo "$msg"
  log "[STATUS] Consulta manual."
  telegram_notify "$msg"
  exit 0
fi

if [ "$MODE" = "reset" ]; then
  removed=()
  for f in "$STATE_FILE" "$STATE_WAN_FILE" "$STATE_FRITZ_FILE" "$STATE_LAN_FAIL_FILE" \
            "$STATE_WATCHMODE_FILE" "$STATE_LASTRUN_FILE"; do
    [ -f "$f" ] && rm -f "$f" && removed+=("$(basename "$f")")
  done
  [ ${#removed[@]} -eq 0 ] \
    && log "[RESET] Sin estado activo." \
    || log "[RESET] Limpiado: ${removed[*]}"
  exit 0
fi

# ---------- LÓGICA PRINCIPAL --------------------------------

# ---------- CONTROL DE FRECUENCIA ---------------------------
# Modo normal:     ejecuta cada WATCHDOG_INTERVAL_MINUTES (bajo consumo).
# Modo vigilancia: ejecuta cada minuto mientras alguna URL falle.
# El timer siempre dispara cada minuto; el script decide si realmente corre.
if [ ! -f "$STATE_WATCHMODE_FILE" ]; then
  _last_ts=$(_read_state_ts "$STATE_LASTRUN_FILE" 0)
  _now_ts=$(date +%s)
  if (( _now_ts - _last_ts < WATCHDOG_INTERVAL_MINUTES * 60 )); then
    exit 0
  fi
fi
_write_state "$STATE_LASTRUN_FILE" "$(date +%s)"

flush_notification_queue
check_public_ip
check_fritz_unexpected_reboot
check_tls_expiry            # comprobación TLS diaria (#8)

check_urls
_urls_ok=$?

# --- Transición a modo vigilancia (#watchmode) ---------------
# Se activa en cuanto alguna URL falla (independientemente de FAIL_MODE/FAIL_QUORUM,
# que controlan cuándo se toman acciones, no cuándo se intensifica la monitorización).
if [ "$FAILED_URL_COUNT" -gt 0 ] && [ ! -f "$STATE_WATCHMODE_FILE" ]; then
  _write_state "$STATE_WATCHMODE_FILE" "$(date +%s)"
  rm -f "$STATE_PARTIAL_FAIL_FILE" 2>/dev/null || true
  log "[WATCHMODE] 🔍 Modo vigilancia activado — ${FAILED_URL_COUNT}/${#URL_ARRAY[@]} URL(s) sin respuesta."
  telegram_notify "🔍 *Watchdog — Modo vigilancia activado*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

*${FAILED_URL_COUNT}/${#URL_ARRAY[@]}* URL(s) no responden.
Comprobando cada minuto hasta recuperación completa.
Modo detección: \`${FAIL_MODE}\`$([ "${FAIL_MODE}" = "quorum" ] && echo " (quorum: ${FAIL_QUORUM:-2}/${#URL_ARRAY[@]})")"
fi

if [ "$_urls_ok" -eq 0 ]; then
  # Dentro del umbral — comprobar si hay fallos parciales (#7)
  if [ "$FAILED_URL_COUNT" -gt 0 ]; then
    # En modo vigilancia se suprime check_instability: las comprobaciones son cada minuto
    # y el usuario ya fue notificado de la activación del modo vigilancia.
    [ ! -f "$STATE_WATCHMODE_FILE" ] && check_instability "$FAILED_URL_COUNT" "${#URL_ARRAY[@]}"
  else
    # Todo OK: resetear contadores de inestabilidad y LAN
    rm -f "$STATE_PARTIAL_FAIL_FILE" 2>/dev/null || true
    rm -f "$STATE_LAN_FAIL_FILE"     2>/dev/null || true
  fi

  if [ -f "$STATE_FILE" ]; then
    NOW=$(date +%s)
    first_fail_ts=$(_read_state_ts "$STATE_FILE")
    TOTAL_MIN=$(( (NOW - first_fail_ts) / 60 ))
    if   [ -f "$STATE_FRITZ_FILE" ]; then
      recovery_detail="Acciones: reconexión WAN forzada + reboot FritzBox"
      recovery_emoji="🔄"
    elif [ -f "$STATE_WAN_FILE" ]; then
      recovery_detail="Acciones: reconexión WAN forzada (reboot Fritz no necesario)"
      recovery_emoji="🔌"
    else
      recovery_detail="Recuperación espontánea (sin acciones sobre la FritzBox)"
      recovery_emoji="✨"
    fi
    log "✅ Conectividad restaurada tras ${TOTAL_MIN} min. ${recovery_detail}"
    incident_end
    telegram_notify "✅ *Proxmox Watchdog — Conexión restaurada*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

${recovery_emoji} ${recovery_detail}

*Duración del fallo:* ${TOTAL_MIN} min"
    rm -f "$STATE_FILE" "$STATE_WAN_FILE" "$STATE_FRITZ_FILE" "$STATE_LAN_FAIL_FILE"
    rm -f "$STATE_WATCHMODE_FILE" 2>/dev/null || true
  elif [ -f "$STATE_WATCHMODE_FILE" ] && [ "$FAILED_URL_COUNT" -eq 0 ]; then
    # Modo vigilancia activo sin incidente formal: URLs se recuperaron antes del umbral
    rm -f "$STATE_WATCHMODE_FILE" "$STATE_PARTIAL_FAIL_FILE" 2>/dev/null || true
    log "[WATCHMODE] ✅ Modo normal restaurado — todas las URLs responden. Intervalo: ${WATCHDOG_INTERVAL_MINUTES} min."
    telegram_notify "✅ *Watchdog — Modo normal restaurado*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

Todas las URLs responden correctamente.
Volviendo a comprobaciones cada *${WATCHDOG_INTERVAL_MINUTES} min*."
  fi
  exit 0
fi

# URLs han superado el umbral de fallo — resetear inestabilidad parcial
rm -f "$STATE_PARTIAL_FAIL_FILE" 2>/dev/null || true

NOW=$(date +%s)

# FASE 1: Primer fallo
if [ ! -f "$STATE_FILE" ]; then
  _write_state "$STATE_FILE" "$NOW"
  incident_start > /dev/null
  log "Primer fallo. Esperando ${MAX_FAIL_MINUTES} min antes de actuar..."
  exit 0
fi

FIRST_FAIL=$(_read_state_ts "$STATE_FILE")
ELAPSED_MIN=$(( (NOW - FIRST_FAIL) / 60 ))

# FASE 2: Reconexión WAN forzada
if [ ! -f "$STATE_WAN_FILE" ]; then
  if [ "$ELAPSED_MIN" -ge "$MAX_FAIL_MINUTES" ]; then

    # Verificar LAN antes de actuar sobre Fritz (#1)
    if ! check_local_network; then
      if [ ! -f "$STATE_LAN_FAIL_FILE" ]; then
        _write_state "$STATE_LAN_FAIL_FILE" "$NOW"
        incident_action "lan_failure"
        log_alert "🔴 LAN local rota — el gateway no responde.
El watchdog NO actuará sobre la FritzBox hasta que la red local se recupere.
Comprueba los cables y switches de la red interna."
      else
        log "[WATCH] LAN local sigue rota. Fallo ${ELAPSED_MIN} min. Esperando recuperación de LAN..."
      fi
      exit 0
    fi

    # LAN OK — limpiar estado LAN si existía
    rm -f "$STATE_LAN_FAIL_FILE" 2>/dev/null || true

    log_alert "⏳ Fallo ${ELAPSED_MIN} min. Intentando reconexión WAN..."
    if force_wan_reconnect; then
      incident_action "wan_reconnect"
      _write_state "$STATE_WAN_FILE" "$NOW"
      log "[WAN] Esperando ${FRITZ_WAN_WAIT_MINUTES} min para verificar..."
    else
      log_alert "⚠️  WAN no disponible. Pasando a reboot Fritz..."
      if reboot_fritzbox; then
        incident_action "wan_reconnect_failed"
        incident_action "fritz_reboot"
        _write_state "$STATE_WAN_FILE"   "$NOW"
        _write_state "$STATE_FRITZ_FILE" "$NOW"
        log "[FRITZ] Esperando ${FRITZ_WAIT_MINUTES} min..."
      else
        log_alert "⚠️  No se pudo reiniciar la Fritz. Reintentando en el siguiente ciclo."
      fi
    fi
  else
    log "[WATCH] Fallo ${ELAPSED_MIN} min (límite: ${MAX_FAIL_MINUTES} min)"
  fi
  exit 0
fi

# FASE 3: Reboot Fritz si WAN no se recuperó
if [ ! -f "$STATE_FRITZ_FILE" ]; then
  wan_ts=$(_read_state_ts "$STATE_WAN_FILE")
  WAN_ELAPSED_MIN=$(( (NOW - wan_ts) / 60 ))
  if [ "$WAN_ELAPSED_MIN" -ge "$FRITZ_WAN_WAIT_MINUTES" ]; then
    log_alert "⏳ WAN sin recuperar tras ${WAN_ELAPSED_MIN} min. Reiniciando Fritz..."
    if reboot_fritzbox; then
      incident_action "fritz_reboot"
      _write_state "$STATE_FRITZ_FILE" "$NOW"
      log "[FRITZ] Esperando ${FRITZ_WAIT_MINUTES} min..."
    else
      log_alert "⚠️  No se pudo reiniciar la Fritz. Reintentando en el siguiente ciclo."
    fi
  else
    log "[WATCH] Reconexión WAN hace ${WAN_ELAPSED_MIN} min, esperando ${FRITZ_WAN_WAIT_MINUTES} min..."
  fi
  exit 0
fi

# FASE 4: Reboot servidor
fritz_ts=$(_read_state_ts "$STATE_FRITZ_FILE")
FRITZ_ELAPSED_MIN=$(( (NOW - fritz_ts) / 60 ))
log_alert "⏳ Fritz reiniciada hace ${FRITZ_ELAPSED_MIN} min sin conexión (límite: ${FRITZ_WAIT_MINUTES} min)"

if [ "$FRITZ_ELAPSED_MIN" -ge "$FRITZ_WAIT_MINUTES" ]; then
  incident_action "server_reboot"
  log_alert "🔴 ¡LÍMITE ALCANZADO! Reiniciando servidor..."
  rm -f "$STATE_FILE" "$STATE_WAN_FILE" "$STATE_FRITZ_FILE" "$STATE_LAN_FAIL_FILE"
  /sbin/reboot
fi
