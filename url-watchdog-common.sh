#!/bin/bash
# ============================================================
#  url-watchdog-common.sh — Librería compartida v2.2.0
#  Uso: source /usr/local/bin/url-watchdog-common.sh
#  Requiere que las variables del .env estén cargadas antes.
# ============================================================
# shellcheck disable=SC2034
VERSION="2.4.0"

# ============================================================
# ÍNDICE DE MEJORAS v2.2.0
#  #1  check_local_network: verifica LAN antes de actuar sobre Fritz
#  #2  check_urls: FAIL_MODE=quorum con FAIL_QUORUM=N
#  #5  check_urls: latencia por URL en el log
#  #6  incident_stats: estadísticas calculadas desde incidents.json
#       incident_history: nuevo filtro --failed
#  #7  check_instability: alerta de fallos parciales repetidos
#  #8  check_tls_expiry: aviso de certificados TLS próximos a expirar
#  #9  build_status_message: muestra modo quorum con fracción
#  #12 (en bot) /diagnose usa check_local_network y latencias
# v2.4.0:
#  #A  check_local_network: comprobación DNS además del gateway (return 2)
#  #B  validate_config: valida URLs y enteros clave al arranque
#  #C  check_urls: alerta de latencia alta (LATENCY_WARN_MS, STATE_LATENCY_PREFIX)
# ============================================================

# --- Utilidades internas ------------------------------------

_mktemp_secure() {
  local prefix="${1:-tmp}"
  local dir="${STATE_DIR:-/run/url-watchdog}"
  mkdir -p "$dir" 2>/dev/null
  chmod 700 "$dir" 2>/dev/null || true
  mktemp --tmpdir="$dir" "${prefix}.XXXXXX"
}

_xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

# Lee un timestamp de fichero de estado con validación numérica.
_read_state_ts() {
  local file="$1" default="${2:-0}"
  local val
  val=$(cat "$file" 2>/dev/null || echo "$default")
  [[ "$val" =~ ^[0-9]+$ ]] || val="$default"
  printf '%s' "$val"
}

# Escritura atómica: tmp + mv evita ficheros vacíos ante SIGTERM.
_write_state() {
  local file="$1" content="$2"
  printf '%s\n' "$content" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# --- Validación de variables --------------------------------

require_vars() {
  local script="${1:-script}"; shift
  local var
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      echo "[ERROR] ${script}: variable requerida no definida: ${var}" >&2
      exit 1
    fi
  done
}

# --- Validación de configuración (#B) -----------------------
# Verifica que las URLs tengan esquema http(s):// y que los enteros
# clave sean números válidos. Llama a exit 1 si hay errores.
# Requiere: URL_ARRAY ya poblado.
validate_config() {
  local script="${1:-script}" errors=0

  # Validar esquema de cada URL
  local _url
  for _url in "${URL_ARRAY[@]}"; do
    _url=$(echo "$_url" | tr -d '[:space:]')
    if ! [[ "$_url" =~ ^https?:// ]]; then
      echo "[ERROR] ${script}: URL sin esquema http(s)://: '${_url}'" >&2
      (( errors++ )) || true
    fi
  done

  # Validar enteros clave: "VARIABLE:minimo"
  local _entry _var _min _val
  for _entry in "MAX_FAIL_MINUTES:1" "HTTP_TIMEOUT:1" \
                "FRITZ_WAN_WAIT_MINUTES:1" "FRITZ_WAIT_MINUTES:1" \
                "LATENCY_WARN_MS:0"; do
    _var="${_entry%%:*}"
    _min="${_entry##*:}"
    _val="${!_var:-}"
    [ -z "$_val" ] && continue   # variable no definida: require_vars ya habrá fallado
    if ! [[ "$_val" =~ ^[0-9]+$ ]] || [ "$_val" -lt "$_min" ]; then
      echo "[ERROR] ${script}: ${_var} debe ser un entero >= ${_min} (actual: '${_val}')" >&2
      (( errors++ )) || true
    fi
  done

  # Advertencia de coherencia: tiempo de espera WAN vs Fritz
  if [[ "${FRITZ_WAN_WAIT_MINUTES:-0}" =~ ^[0-9]+$ ]] && \
     [[ "${FRITZ_WAIT_MINUTES:-0}" =~ ^[0-9]+$ ]] && \
     [ "${FRITZ_WAN_WAIT_MINUTES:-0}" -ge "${FRITZ_WAIT_MINUTES:-1}" ]; then
    echo "[WARN] ${script}: FRITZ_WAN_WAIT_MINUTES (${FRITZ_WAN_WAIT_MINUTES}) >= FRITZ_WAIT_MINUTES (${FRITZ_WAIT_MINUTES}). Considera reducir FRITZ_WAN_WAIT_MINUTES." >&2
  fi

  [ "$errors" -gt 0 ] && exit 1
  return 0
}

# --- Logging ------------------------------------------------

rotate_log() {
  [ ! -f "$LOG_FILE" ] && return
  local size
  size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
    local lockfile="${STATE_DIR:-/run/url-watchdog}/rotate-log.lock"
    mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true
    (
      flock -n 9 || return
      local lines keep
      lines=$(wc -l < "$LOG_FILE")
      keep=$(( lines / 2 ))
      tail -n "$keep" "$LOG_FILE" > "${LOG_FILE}.tmp" \
        && mv "${LOG_FILE}.tmp" "$LOG_FILE"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [LOG] Rotación aplicada." >> "$LOG_FILE"
    ) 9>"$lockfile"
  fi
}

log() {
  local msg
  msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

# --- Llamadas HTTP seguras ----------------------------------

_curl_telegram_api() {
  local method="$1"; shift
  local cfg result rc
  cfg=$(_mktemp_secure "tg")
  trap 'rm -f "$cfg"' RETURN
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' \
    "$TELEGRAM_TOKEN" "$method" > "$cfg"
  result=$(curl --config "$cfg" --silent "$@" 2>/dev/null)
  rc=$?
  printf '%s' "$result"
  return $rc
}

# --- Cola de notificaciones ---------------------------------

enqueue_notification() {
  local text="$1" encoded
  encoded=$(printf '%s' "$text" | base64 -w 0)
  printf '%s\n' "$encoded" >> "$NOTIFY_QUEUE_FILE"
}

_telegram_send_raw() {
  local chat_id="$1" text="$2" http_code
  http_code=$(_curl_telegram_api "sendMessage" \
    --max-time 10 \
    --write-out "%{http_code}" --output /dev/null \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "parse_mode=Markdown" \
    --data-urlencode "text=${text}")
  [ "$http_code" = "200" ]
}

flush_notification_queue() {
  [ ! -f "$NOTIFY_QUEUE_FILE" ] && return
  [ ! -s "$NOTIFY_QUEUE_FILE" ] && return

  local lockfile="${STATE_DIR:-/run/url-watchdog}/queue.lock"
  mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true

  (
    flock -n 9 || {
      log "[QUEUE] Cola en uso por otro proceso, omitiendo flush."
      return
    }

    local total pending=0 sent=0
    total=$(wc -l < "$NOTIFY_QUEUE_FILE")
    log "[QUEUE] Enviando ${total} notificaciones pendientes..."

    local tmp_queue="${NOTIFY_QUEUE_FILE}.tmp"
    : > "$tmp_queue"

    while IFS= read -r encoded; do
      [ -z "$encoded" ] && continue
      local text
      text=$(printf '%s' "$encoded" | base64 -d 2>/dev/null)
      if _telegram_send_raw "$TELEGRAM_CHAT_ID" "$text"; then
        (( sent++ )) || true
      else
        printf '%s\n' "$encoded" >> "$tmp_queue"
        (( pending++ )) || true
      fi
    done < "$NOTIFY_QUEUE_FILE"

    mv "$tmp_queue" "$NOTIFY_QUEUE_FILE"
    [ "$pending" -eq 0 ] && rm -f "$NOTIFY_QUEUE_FILE"
    log "[QUEUE] Enviadas: ${sent}/${total}. Pendientes: ${pending}."
  ) 9>"$lockfile"
}

# --- Telegram -----------------------------------------------

telegram_notify() {
  { [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; } && return

  if [ -f "$STATE_SILENCE_FILE" ]; then
    local silence_until now
    silence_until=$(_read_state_ts "$STATE_SILENCE_FILE")
    now=$(date +%s)
    if [ "$now" -lt "$silence_until" ]; then
      local remaining=$(( (silence_until - now) / 60 ))
      log "[TELEGRAM] Silencio activo (${remaining} min). Notificación suprimida."
      return 0
    else
      rm -f "$STATE_SILENCE_FILE"
    fi
  fi

  local text="$1" attempt=1 raw http_code body api_error error_detail
  while [ "$attempt" -le "$TELEGRAM_MAX_RETRIES" ]; do
    raw=$(_curl_telegram_api "sendMessage" \
      --max-time 10 \
      --write-out "\n%{http_code}" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "parse_mode=Markdown" \
      --data-urlencode "text=${text}")
    http_code=$(printf '%s' "$raw" | tail -n1)
    body=$(printf '%s' "$raw" | head -n -1)

    if [ "$http_code" = "200" ]; then return 0; fi

    api_error=$(printf '%s' "$body" \
      | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
    error_detail="${api_error:-sin respuesta o timeout}"
    log "[TELEGRAM] Intento ${attempt}/${TELEGRAM_MAX_RETRIES} fallido — HTTP ${http_code}: ${error_detail}"

    if [ "$attempt" -lt "$TELEGRAM_MAX_RETRIES" ]; then
      log "[TELEGRAM] Reintentando en ${TELEGRAM_RETRY_DELAY}s..."
      sleep "$TELEGRAM_RETRY_DELAY"
    fi
    (( attempt++ )) || true
  done

  log "[TELEGRAM] ⚠️  Notificación encolada para reenvío posterior."
  enqueue_notification "$text"
}

telegram_send() {
  local chat_id="$1" text="$2"
  local attempt=1 http_code

  while [ "$attempt" -le "${TELEGRAM_MAX_RETRIES:-3}" ]; do
    http_code=$(_curl_telegram_api "sendMessage" \
      --max-time 10 \
      --write-out "%{http_code}" --output /dev/null \
      --data-urlencode "chat_id=${chat_id}" \
      --data-urlencode "parse_mode=Markdown" \
      --data-urlencode "text=${text}")

    [ "$http_code" = "200" ] && return 0

    if [ "$attempt" -lt "${TELEGRAM_MAX_RETRIES:-3}" ]; then
      sleep "${TELEGRAM_RETRY_DELAY:-5}"
    fi
    (( attempt++ )) || true
  done

  log "[TELEGRAM] telegram_send a chat ${chat_id} fallida tras ${TELEGRAM_MAX_RETRIES:-3} intentos (HTTP ${http_code:-?})."
  return 1
}

log_alert() {
  log "$*"
  telegram_notify "🖥 *Proxmox Watchdog*
⚠️ $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

$*"
}

# --- Red local (#1 + #A) ------------------------------------
# Comprueba ruta por defecto, respuesta del gateway y resolución DNS.
# Retorna:
#   0 — LAN + DNS OK
#   1 — sin ruta o gateway no responde
#   2 — gateway OK pero DNS no responde
check_local_network() {
  local gateway
  gateway=$(ip route get 1.1.1.1 2>/dev/null | awk '/via/ {print $3}' | head -1)
  if [ -z "$gateway" ]; then
    log "[LAN] Sin ruta por defecto hacia 1.1.1.1."
    return 1
  fi
  if ! ping -c 1 -W 2 "$gateway" > /dev/null 2>&1; then
    log "[LAN] Gateway ${gateway} no responde al ping."
    return 1
  fi
  # Comprobación DNS (#A): resolución de nombre externo via getent (glibc)
  if ! timeout 3 getent hosts "example.com" > /dev/null 2>&1; then
    log "[LAN] ⚠️  DNS no responde (resolución de example.com fallida)."
    return 2
  fi
  return 0
}

# --- IP pública ---------------------------------------------

get_public_ip() {
  local providers=(
    "https://api.ipify.org"
    "https://ifconfig.me/ip"
    "https://icanhazip.com"
  )
  local ip provider first=true
  for provider in "${providers[@]}"; do
    if [ "$first" = "true" ]; then
      first=false
    else
      sleep 1
    fi
    ip=$(curl --silent --max-time 5 "$provider" 2>/dev/null | tr -d '[:space:]')
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "$ip"; return 0
    fi
  done
  return 1
}

# --- Inestabilidad parcial (#7) -----------------------------
# Alerta cuando hay fallos parciales repetidos sin llegar al umbral de acción.
# Solo aplica en modos all y quorum; en any cualquier fallo ya es total.
# Requiere: STATE_PARTIAL_FAIL_FILE, INSTABILITY_THRESHOLD, FAIL_MODE,
#           FAIL_QUORUM (si mode=quorum), URL_ARRAY.
check_instability() {
  local failed="$1" total="$2"

  # Determinar si es fallo parcial según el modo
  local is_partial=false
  case "${FAIL_MODE:-all}" in
    all)    [ "$failed" -gt 0 ] && [ "$failed" -lt "$total" ] && is_partial=true ;;
    quorum) [ "$failed" -gt 0 ] && [ "$failed" -lt "${FAIL_QUORUM:-2}" ] && is_partial=true ;;
    any)    ;; # any: fallo parcial = fallo total, no aplica aquí
  esac

  if [ "$is_partial" = "false" ]; then
    # Sin fallos o fallo total — resetear contador parcial
    rm -f "${STATE_PARTIAL_FAIL_FILE:-}" 2>/dev/null || true
    return
  fi

  local today count
  today=$(date '+%Y-%m-%d')
  if [ -f "${STATE_PARTIAL_FAIL_FILE:-}" ]; then
    local stored_date stored_count
    IFS='|' read -r stored_date stored_count < "$STATE_PARTIAL_FAIL_FILE"
    if [ "$stored_date" = "$today" ]; then
      [[ "$stored_count" =~ ^[0-9]+$ ]] || stored_count=0
      count=$(( stored_count + 1 ))
    else
      count=1
    fi
  else
    count=1
  fi
  _write_state "${STATE_PARTIAL_FAIL_FILE}" "${today}|${count}"

  local threshold="${INSTABILITY_THRESHOLD:-3}"
  if [ "$count" -ge "$threshold" ]; then
    log "[WATCH] ⚠️ Inestabilidad: ${failed}/${total} URLs fallan (${count} ciclos con fallos parciales hoy)"
    telegram_notify "⚠️ *Proxmox Watchdog — Conectividad inestable*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

*${failed}/${total}* URLs han fallado en los últimos ciclos hoy (${count} ciclos con fallos parciales).
La conexión es inestable pero no ha alcanzado el umbral de acción.
Modo: \`${FAIL_MODE}\`$([ "$FAIL_MODE" = "quorum" ] && echo " (quorum: ${FAIL_QUORUM:-2}/${total})")

Usa /diagnose para analizar la conexión."
    # Resetear para evitar spam — próxima alerta tras otros $threshold ciclos
    _write_state "${STATE_PARTIAL_FAIL_FILE}" "${today}|0"
  fi
}

# --- TLS cert expiry (#8) -----------------------------------
# Comprueba la fecha de expiración de certificados TLS de las URLs HTTPS.
# Solo se ejecuta una vez al día (STATE_TLS_CHECK_FILE).
# Requiere: openssl, URL_ARRAY, CERT_EXPIRY_WARN_DAYS, STATE_TLS_CHECK_FILE.
check_tls_expiry() {
  local warn_days="${CERT_EXPIRY_WARN_DAYS:-14}"
  [ "$warn_days" -le 0 ] && return
  command -v openssl > /dev/null 2>&1 || { log "[TLS] openssl no disponible, omitiendo comprobación."; return; }

  # Una sola comprobación por día
  local today
  today=$(date '+%Y-%m-%d')
  if [ -f "${STATE_TLS_CHECK_FILE:-}" ]; then
    local last_check
    last_check=$(cat "$STATE_TLS_CHECK_FILE" 2>/dev/null)
    [ "$last_check" = "$today" ] && return
  fi
  _write_state "${STATE_TLS_CHECK_FILE}" "$today"

  local url host expiry_date expiry_ts now_ts days_left
  now_ts=$(date +%s)

  for url in "${URL_ARRAY[@]}"; do
    url=$(echo "$url" | tr -d '[:space:]')
    [[ "$url" =~ ^https:// ]] || continue

    host=$(printf '%s' "$url" | sed 's|https://||' | cut -d'/' -f1 | cut -d':' -f1)
    [ -z "$host" ] && continue

    expiry_date=$(echo \
      | timeout 5 openssl s_client -connect "${host}:443" \
          -servername "$host" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null \
      | cut -d= -f2)
    [ -z "$expiry_date" ] && { log "[TLS] No se pudo leer certificado de ${host}."; continue; }

    expiry_ts=$(date -d "$expiry_date" +%s 2>/dev/null) || continue
    days_left=$(( (expiry_ts - now_ts) / 86400 ))

    if [ "$days_left" -le 0 ]; then
      log "[TLS] ❌ Certificado EXPIRADO: ${host} (expiró hace $(( -days_left )) días)"
      telegram_notify "❌ *Watchdog — Certificado TLS EXPIRADO*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

El certificado de \`${host}\` ha *expirado*.
Renuévalo urgentemente — curl puede empezar a rechazar la URL monitorizad."
    elif [ "$days_left" -le "$warn_days" ]; then
      log "[TLS] ⚠️ Certificado próximo a expirar: ${host} (${days_left} días)"
      telegram_notify "⚠️ *Watchdog — Certificado TLS próximo a expirar*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

El certificado de \`${host}\` expira en *${days_left} días*.
Renuévalo antes de que expire para evitar falsos positivos en la monitorización."
    else
      log "[TLS] ✅ ${host}: certificado válido (${days_left} días restantes)"
    fi
  done
}

# --- FritzBox TR-064 ----------------------------------------

fritz_soap_call() {
  local location="$1" uri="$2" action="$3"
  local safe_action safe_uri
  safe_action=$(_xml_escape "$action")
  safe_uri=$(_xml_escape "$uri")

  local soap_body
  soap_body="<?xml version='1.0' encoding='utf-8'?>"
  soap_body+="<s:Envelope s:encodingStyle='http://schemas.xmlsoap.org/soap/encoding/'"
  soap_body+=" xmlns:s='http://schemas.xmlsoap.org/soap/envelope/'>"
  soap_body+="<s:Body>"
  soap_body+="<u:${safe_action} xmlns:u='${safe_uri}'></u:${safe_action}>"
  soap_body+="</s:Body></s:Envelope>"

  local netrc raw rc http_code body
  netrc=$(_mktemp_secure "fritz-nr")
  trap 'rm -f "$netrc"' RETURN
  printf 'machine %s login %s password %s\n' \
    "$FRITZ_IP" "$FRITZ_USER" "$FRITZ_PASSWORD" > "$netrc"

  raw=$(curl -k -m 5 --anyauth --netrc-file "$netrc" \
    "http://${FRITZ_IP}:49000${location}" \
    -H 'Content-Type: text/xml; charset="utf-8"' \
    -H "SoapAction:${uri}#${action}" \
    --data-binary "$soap_body" \
    --silent --write-out "\n%{http_code}" 2>/dev/null)
  rc=$?

  http_code=$(printf '%s' "$raw" | tail -n1)
  body=$(printf '%s' "$raw" | head -n -1)
  printf '%s\n%s' "$http_code" "$body"
  return $rc
}

xml_field() {
  printf '%s' "$1" \
    | grep -o "<${2}>[^<]*</${2}>" \
    | sed "s/<[^>]*>//g"
}

format_uptime() {
  local secs="${1:-0}" d h m result=""
  d=$(( secs / 86400 ))
  h=$(( (secs % 86400) / 3600 ))
  m=$(( (secs % 3600) / 60 ))
  [ "$d" -gt 0 ] && result="${d}d "
  [ "$h" -gt 0 ] && result="${result}${h}h "
  printf '%s' "${result}${m}m"
}

reboot_fritzbox() {
  log "[FRITZ] Enviando reboot a FritzBox (${FRITZ_IP})..."
  local raw http_code
  raw=$(fritz_soap_call "/upnp/control/deviceconfig" \
    "urn:dslforum-org:service:DeviceConfig:1" "Reboot")
  http_code=$(printf '%s' "$raw" | head -1)
  if [ "$http_code" = "200" ]; then
    log "[FRITZ] ✅ Reboot enviado."; return 0
  else
    log "[FRITZ] ⚠️  Fallo al enviar reboot (HTTP ${http_code})."; return 1
  fi
}

force_wan_reconnect() {
  local raw http_code connected=false
  for wan_service in "WANPPPConnection:1" "WANIPConnection:1"; do
    local wan_path wan_uri
    [ "$wan_service" = "WANPPPConnection:1" ] \
      && wan_path="/upnp/control/wanpppconn1" \
      || wan_path="/upnp/control/wanipconn1"
    wan_uri="urn:dslforum-org:service:${wan_service}"

    raw=$(fritz_soap_call "$wan_path" "$wan_uri" "ForceTermination")
    http_code=$(printf '%s' "$raw" | head -1)
    if [ "$http_code" = "200" ]; then
      log "[FRITZ] [WAN] ForceTermination OK. Esperando 5s..."
      sleep 5
      raw=$(fritz_soap_call "$wan_path" "$wan_uri" "RequestConnection")
      http_code=$(printf '%s' "$raw" | head -1)
      if [ "$http_code" = "200" ]; then
        log "[FRITZ] [WAN] RequestConnection OK."; connected=true
      else
        log "[FRITZ] [WAN] RequestConnection falló (HTTP ${http_code})."
      fi
      break
    fi
  done
  [ "$connected" = true ] && return 0 || return 1
}

# Devuelve: "ok|modelo|uptime_router_fmt|wan_display|uptime_wan_fmt|uptime_router_secs"
#       o:  "auth_error" / "conn_error" / "unknown_error:CODE"
get_fritz_info() {
  local update_uptime_state="${1:-true}"
  local raw http_code body

  raw=$(fritz_soap_call "/upnp/control/deviceinfo" \
    "urn:dslforum-org:service:DeviceInfo:1" "GetInfo")
  http_code=$(printf '%s' "$raw" | head -1)
  body=$(printf '%s' "$raw" | tail -n +2)

  if   [ "$http_code" = "401" ]; then printf 'auth_error';                    return 1
  elif [ "$http_code" = "000" ]; then printf 'conn_error';                    return 1
  elif [ "$http_code" != "200" ]; then printf 'unknown_error:%s' "$http_code"; return 1
  fi

  local model router_uptime_secs router_uptime_fmt
  model=$(xml_field "$body" "NewModelName")
  router_uptime_secs=$(xml_field "$body" "NewUpTime")
  router_uptime_fmt=$(format_uptime "${router_uptime_secs:-0}")

  if [ "$update_uptime_state" = "true" ]; then
    _write_state "$STATE_FRITZ_UPTIME_FILE" "${router_uptime_secs:-0}|$(date +%s)"
  fi

  local wan_status wan_uptime_fmt
  for wan_service in "WANPPPConnection:1" "WANIPConnection:1"; do
    local wan_path wan_uri
    [ "$wan_service" = "WANPPPConnection:1" ] \
      && wan_path="/upnp/control/wanpppconn1" \
      || wan_path="/upnp/control/wanipconn1"
    wan_uri="urn:dslforum-org:service:${wan_service}"

    raw=$(fritz_soap_call "$wan_path" "$wan_uri" "GetStatusInfo")
    http_code=$(printf '%s' "$raw" | head -1)
    body=$(printf '%s' "$raw" | tail -n +2)
    if [ "$http_code" = "200" ]; then
      wan_status=$(xml_field "$body" "NewConnectionStatus")
      wan_uptime_fmt=$(format_uptime "$(xml_field "$body" "NewUptime")")
      break
    fi
  done

  local wan_display
  case "$wan_status" in
    Connected)    wan_display="✅ Connected" ;;
    Disconnected) wan_display="❌ Disconnected" ;;
    Connecting)   wan_display="🔄 Connecting..." ;;
    *)            wan_display="❓ ${wan_status:-desconocido}" ;;
  esac

  printf 'ok|%s|%s|%s|%s|%s' \
    "${model:-desconocido}" \
    "$router_uptime_fmt" \
    "$wan_display" \
    "${wan_uptime_fmt:-n/a}" \
    "${router_uptime_secs:-0}"
  return 0
}

# --- Mensaje de estado --------------------------------------

build_status_message() {
  local prefix="$1" current_ip="$2" extra="${3:-}"
  local fase="✅ Sin fallos activos"

  if [ -f "$STATE_FILE" ]; then
    local first_fail now elapsed
    first_fail=$(_read_state_ts "$STATE_FILE")
    now=$(date +%s)
    elapsed=$(( (now - first_fail) / 60 ))
    if [ -f "$STATE_FRITZ_FILE" ]; then
      local fritz_ts fritz_elapsed
      fritz_ts=$(_read_state_ts "$STATE_FRITZ_FILE")
      fritz_elapsed=$(( (now - fritz_ts) / 60 ))
      fase="🔴 Fallo activo: ${elapsed} min — Fritz reiniciada hace ${fritz_elapsed} min"
    elif [ -f "$STATE_WAN_FILE" ]; then
      local wan_ts wan_elapsed
      wan_ts=$(_read_state_ts "$STATE_WAN_FILE")
      wan_elapsed=$(( (now - wan_ts) / 60 ))
      fase="🟠 Fallo activo: ${elapsed} min — Reconexión WAN hace ${wan_elapsed} min"
    else
      fase="🟡 Fallo activo desde hace ${elapsed} min"
    fi
  fi

  # Alerta de inestabilidad (#7)
  local instability_info=""
  if [ -f "${STATE_PARTIAL_FAIL_FILE:-}" ]; then
    local today stored_date stored_count
    today=$(date '+%Y-%m-%d')
    IFS='|' read -r stored_date stored_count < "$STATE_PARTIAL_FAIL_FILE"
    if [ "$stored_date" = "$today" ] && [ "${stored_count:-0}" -gt 0 ]; then
      instability_info="
⚡ *Fallos parciales hoy:* ${stored_count} ciclos"
    fi
  fi

  local disablereboot_info=""
  if [ -f "${STATE_DISABLEREBOOT_FILE:-}" ]; then
    disablereboot_info="
🚫 *Acciones correctivas deshabilitadas* (/disablereboot on)"
  fi

  local silence_info=""
  if [ -f "$STATE_SILENCE_FILE" ]; then
    local silence_until now remaining
    silence_until=$(_read_state_ts "$STATE_SILENCE_FILE")
    now=$(date +%s)
    if [ "$now" -lt "$silence_until" ]; then
      remaining=$(( (silence_until - now) / 60 ))
      silence_info="
🔕 *Silencio activo:* ${remaining} min restantes"
    fi
  fi

  local queue_info=""
  if [ -f "$NOTIFY_QUEUE_FILE" ] && [ -s "$NOTIFY_QUEUE_FILE" ]; then
    local queued
    queued=$(wc -l < "$NOTIFY_QUEUE_FILE")
    queue_info="
📬 *Notificaciones en cola:* ${queued}"
  fi

  local watchmode_info=""
  local _wm_file="${STATE_WATCHMODE_FILE:-${STATE_DIR}/watchdog.watchmode}"
  if [ -f "$_wm_file" ]; then
    local _wm_ts _wm_min
    _wm_ts=$(_read_state_ts "$_wm_file" 0)
    _wm_min=$(( ($(date +%s) - _wm_ts) / 60 ))
    watchmode_info="
🔍 *Modo vigilancia activo* (${_wm_min} min — comprobando cada minuto)"
  fi

  # Descripción del modo (#2 quorum)
  local mode_desc
  case "${FAIL_MODE:-all}" in
    all)    mode_desc="all" ;;
    any)    mode_desc="any" ;;
    quorum) mode_desc="quorum ${FAIL_QUORUM:-2}/${#URL_ARRAY[@]}" ;;
    *)      mode_desc="${FAIL_MODE}" ;;
  esac

  echo "${prefix}
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

*Estado:* ${fase}${instability_info}${watchmode_info}
*IP pública:* \`${current_ip:-desconocida}\`
*URLs monitorizadas:*
$(printf '  • %s\n' "${URL_ARRAY[@]}")
*Flujo:* >${MAX_FAIL_MINUTES}min → WAN reconect → +${FRITZ_WAN_WAIT_MINUTES}min → Fritz reboot → +${FRITZ_WAIT_MINUTES}min → server reboot
*Modo:* ${mode_desc}${disablereboot_info}${silence_info}${queue_info}${extra}"
}

# --- Historial de incidentes --------------------------------

_incidents_init() {
  local dir
  dir=$(dirname "$INCIDENTS_FILE")
  [ -d "$dir" ] || mkdir -p "$dir"
  [ -f "$INCIDENTS_FILE" ] || printf '[]' > "$INCIDENTS_FILE"
}

incident_start() {
  _incidents_init
  local id start tmp
  id=$(date '+%Y%m%d-%H%M%S')
  start=$(date '+%Y-%m-%dT%H:%M:%S')
  tmp="${INCIDENTS_FILE}.tmp"

  local max="${INCIDENTS_MAX_ENTRIES:-500}"
  local count
  count=$(jq 'length' "$INCIDENTS_FILE" 2>/dev/null || printf '0')
  if [ "$count" -ge "$max" ]; then
    local trim=$(( count - max + 1 ))
    jq --argjson trim "$trim" '.[$trim:]' \
      "$INCIDENTS_FILE" > "$tmp" && mv "$tmp" "$INCIDENTS_FILE"
    log "[INCIDENTS] Rotación: eliminadas ${trim} entradas antiguas."
  fi

  jq --arg id "$id" --arg start "$start" \
    '. += [{"id":$id,"start":$start,"end":null,
            "duration_min":null,"actions":[],"resolved":false}]' \
    "$INCIDENTS_FILE" > "$tmp" && mv "$tmp" "$INCIDENTS_FILE"

  printf '%s' "$id"
}

incident_action() {
  _incidents_init
  local action="$1" tmp
  tmp="${INCIDENTS_FILE}.tmp"
  jq --arg action "$action" '
    ([ to_entries[] | select(.value.resolved == false) ] | last) as $entry |
    if $entry then
      .[$entry.key].actions |= (
        if index($action) then . else . + [$action] end
      )
    else . end
  ' "$INCIDENTS_FILE" > "$tmp" && mv "$tmp" "$INCIDENTS_FILE"
}

incident_end() {
  _incidents_init
  local end now_ts tmp
  end=$(date '+%Y-%m-%dT%H:%M:%S')
  now_ts=$(date +%s)
  tmp="${INCIDENTS_FILE}.tmp"
  jq --arg end "$end" --argjson now_ts "$now_ts" '
    ([ to_entries[] | select(.value.resolved == false) ] | last) as $entry |
    if $entry then
      (.[$entry.key].start | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $start_ts |
      .[$entry.key].end          = $end |
      .[$entry.key].resolved     = true |
      .[$entry.key].duration_min = (($now_ts - $start_ts) / 60 | floor)
    else . end
  ' "$INCIDENTS_FILE" > "$tmp" && mv "$tmp" "$INCIDENTS_FILE"
}

# Historial con filtro opcional.
# Uso: incident_history [n] [--failed]
#   n        — número de incidentes (default: 5)
#   --failed — mostrar solo los que requirieron alguna acción (#9)
incident_history() {
  _incidents_init
  local n="${1:-5}" filter="${2:-}"
  local total
  total=$(jq 'length' "$INCIDENTS_FILE" 2>/dev/null || printf '0')
  if [ "$total" -eq 0 ]; then
    printf 'No hay incidentes registrados aún.'
    return
  fi

  jq -r --argjson n "$n" --argjson filter_failed "$([ "$filter" = "--failed" ] && echo true || echo false)" '
    (if $filter_failed then map(select((.actions | length) > 0)) else . end) |
    .[-$n:] | reverse[] |
    [
      .id,
      .start,
      (if .duration_min then (.duration_min|tostring)+" min" else "en curso" end),
      (if (.actions|length)>0 then .actions|join(", ") else "ninguna" end),
      (if .resolved then "Resuelto" else "Activo" end)
    ] | join("\u0001")
  ' "$INCIDENTS_FILE" | awk -F'\x01' '
    NR > 1 { print "" }
    {
      status = ($5 == "Resuelto") ? "✅ Resuelto" : "🔴 Activo"
      print "*" $1 "*"
      print "  Inicio: " $2
      print "  Duración: " $3
      print "  Acciones: " $4
      print "  Estado: " status
    }
  '
}

# Estadísticas de incidentes de un período (#6).
# Uso: incident_stats [days] [offset_days]
#   days        — tamaño del período en días (default: 30)
#   offset_days — empezar hace N días (default: 0 = ahora)
# Salida: total|resueltos|dur_media|dur_max|n_wan|n_fritz|n_server|n_espontaneos|n_activos
incident_stats() {
  _incidents_init
  local days="${1:-30}" offset="${2:-0}"
  local total
  total=$(jq 'length' "$INCIDENTS_FILE" 2>/dev/null || printf '0')
  if [ "$total" -eq 0 ]; then
    printf '0|0|0|0|0|0|0|0|0'
    return
  fi

  jq -r --argjson days "$days" --argjson offset "$offset" '
    (now - (($offset + $days) * 86400)) as $from |
    (now - ($offset * 86400))           as $to   |

    [ .[] | select(
        (.start | strptime("%Y-%m-%dT%H:%M:%S") | mktime) >= $from and
        (.start | strptime("%Y-%m-%dT%H:%M:%S") | mktime) <= $to
    )] as $period |

    ($period | length) as $total |
    [ $period[] | select(.resolved == true and .duration_min != null) ] as $resolved |
    ($resolved | length) as $n_resolved |

    (if $n_resolved > 0 then
      ($resolved | map(.duration_min) | add) / $n_resolved | floor
    else 0 end) as $avg_dur |

    (if $n_resolved > 0 then
      ($resolved | map(.duration_min) | max)
    else 0 end) as $max_dur |

    [ $period[] | .actions[] ] as $all_actions |
    ($all_actions | map(select(. == "wan_reconnect"))           | length) as $n_wan    |
    ($all_actions | map(select(. == "fritz_reboot"))            | length) as $n_fritz  |
    ($all_actions | map(select(. == "server_reboot"))           | length) as $n_server |
    ($period | map(select(.resolved and (.actions | length) == 0)) | length) as $n_spont  |
    ($period | map(select(.resolved == false))                  | length) as $n_active |

    [$total, $n_resolved, $avg_dur, $max_dur, $n_wan, $n_fritz, $n_server, $n_spont, $n_active]
    | join("|")
  ' "$INCIDENTS_FILE" 2>/dev/null || printf '0|0|0|0|0|0|0|0|0'
}

# --- Reboot del nodo Proxmox vía API ------------------------
# Si PROXMOX_HOST está definido: llama a la API REST de Proxmox.
# Fallback: /sbin/reboot (instalación nativa sin Proxmox).
# Las credenciales se pasan a curl via fichero temporal (nunca en args).
request_host_reboot() {
  local reason="${1:-server_reboot}"

  if [ -z "${PROXMOX_HOST:-}" ]; then
    log "[REBOOT] PROXMOX_HOST no configurado. Ejecutando reboot nativo..."
    /sbin/reboot
    return
  fi

  log "[REBOOT] Solicitando reboot del nodo '${PROXMOX_NODE}' en ${PROXMOX_HOST} via API Proxmox..."

  local cfg
  cfg=$(_mktemp_secure "proxmox-cfg")
  trap 'rm -f "$cfg"' RETURN

  # Credenciales en fichero temporal 600 dentro de STATE_DIR — nunca en ps ni env
  printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' \
    "$PROXMOX_TOKEN_ID" "$PROXMOX_TOKEN_SECRET" > "$cfg"

  local http_code
  http_code=$(curl --config "$cfg" \
    --silent --output /dev/null --write-out "%{http_code}" \
    --insecure \
    -X POST "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/status" \
    -d "command=reboot" \
    -m 10 2>/dev/null)

  if [ "$http_code" = "200" ]; then
    log "[REBOOT] ✅ Reboot de nodo Proxmox aceptado (HTTP 200). El host se está reiniciando..."
    sleep 60
    exit 0
  else
    log "[REBOOT] ❌ API Proxmox devolvió HTTP ${http_code:-timeout}. Intentando reboot nativo..."
    /sbin/reboot
  fi
}

# --- Carga de configuración ---------------------------------

load_env() {
  local _PROTECTED="PATH IFS LD_PRELOAD LD_LIBRARY_PATH \
    BASH BASHOPTS BASH_COMMAND BASH_SOURCE BASH_VERSINFO \
    FUNCNAME SHELLOPTS SHLVL EUID UID PPID HOME PWD OLDPWD"

  local file="$1" line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]] \
      || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    if   [[ "$value" =~ ^\"([^\"]*)\"([[:space:]]*(#.*)?)?$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\'([^\']*)\'([[:space:]]*(#.*)?)?$ ]]; then
      value="${BASH_REMATCH[1]}"
    else
      value=$(printf '%s' "$value" \
        | sed 's/[[:space:]]\+#.*$//' \
        | sed 's/[[:space:]]*$//')
    fi

    if [[ " $_PROTECTED " == *" $key "* ]]; then
      echo "[WARN] load_env: variable protegida ignorada: ${key}" >&2
      continue
    fi
    printf -v "$key" '%s' "$value"
  done < "$file"
}
