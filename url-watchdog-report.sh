#!/bin/bash
# ============================================================
#  url-watchdog-report.sh — Informe diario y semanal
#  Versión: 2.2.0
# ============================================================
# Uso:
#   url-watchdog-report.sh           → informe diario (default)
#   url-watchdog-report.sh --weekly  → informe semanal comparativo
# ============================================================
VERSION="2.3.0"

set -uo pipefail

ENV_FILE="/etc/url-watchdog/.env"
COMMON_LIB="/usr/local/bin/url-watchdog-common.sh"
MODE="daily"

for arg in "$@"; do
  case "$arg" in
    --weekly) MODE="weekly" ;;
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
# shellcheck source=url-watchdog-common.sh
source "$COMMON_LIB"
load_env "$ENV_FILE"

require_vars "url-watchdog-report.sh" \
  TELEGRAM_TOKEN TELEGRAM_CHAT_ID LOG_FILE \
  STATE_DIR STATE_IP_FILE STATE_IP_CHANGES_FILE \
  FRITZ_IP FRITZ_USER FRITZ_PASSWORD \
  TELEGRAM_MAX_RETRIES TELEGRAM_RETRY_DELAY \
  STATE_SILENCE_FILE NOTIFY_QUEUE_FILE \
  INCIDENTS_FILE

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

rotate_log
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"

# --- Uptime del servidor ------------------------------------

get_server_uptime() {
  local uptime_secs
  uptime_secs=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
  format_uptime "$uptime_secs"
}

# --- Incidentes del día (desde log) -------------------------

get_today_incidents() {
  local today
  today=$(date '+%Y-%m-%d')
  [ ! -f "$LOG_FILE" ] && printf '0|0|0|0' && return

  local count_fail count_wan count_fritz_reboot count_server_reboot
  count_fail=$(grep        "^\[${today}" "$LOG_FILE" 2>/dev/null | grep -c "Primer fallo"        || echo 0)
  count_wan=$(grep         "^\[${today}" "$LOG_FILE" 2>/dev/null | grep -c "RequestConnection OK" || echo 0)
  count_fritz_reboot=$(grep "^\[${today}" "$LOG_FILE" 2>/dev/null | grep -c "Reboot enviado"      || echo 0)
  count_server_reboot=$(grep "^\[${today}" "$LOG_FILE" 2>/dev/null | grep -c "LÍMITE ALCANZADO"  || echo 0)

  printf '%s|%s|%s|%s' \
    "$count_fail" "$count_wan" "$count_fritz_reboot" "$count_server_reboot"
}

# --- Cambios de IP del día ----------------------------------

get_ip_changes_today() {
  local today
  today=$(date '+%Y-%m-%d')
  if [ -f "$STATE_IP_CHANGES_FILE" ]; then
    local stored_date stored_count
    IFS='|' read -r stored_date stored_count < "$STATE_IP_CHANGES_FILE"
    [ "$stored_date" = "$today" ] && printf '%s' "${stored_count:-0}" && return
  fi
  printf '0'
}

# ============================================================
# INFORME DIARIO
# ============================================================

send_daily_report() {
  log "[REPORT] Generando informe diario (v${VERSION})..."

  local current_ip server_uptime
  current_ip=$(get_public_ip || echo "no disponible")
  server_uptime=$(get_server_uptime)

  local fritz_result fritz_ok fritz_section
  fritz_result=$(get_fritz_info false) || true
  fritz_ok=$?
  if [ "$fritz_ok" -eq 0 ]; then
    IFS='|' read -r _ fritz_model fritz_router_uptime fritz_wan_status fritz_wan_uptime _ \
      <<< "$fritz_result"
    fritz_section="*FritzBox:*
  • Modelo: ${fritz_model}
  • Uptime router: ${fritz_router_uptime}
  • Estado WAN: ${fritz_wan_status}
  • Uptime conexión: ${fritz_wan_uptime}"
  else
    fritz_section="*FritzBox:* ❌ No disponible"
  fi

  local incident_data
  incident_data=$(get_today_incidents)
  local inc_fail inc_wan inc_fritz inc_server
  IFS='|' read -r inc_fail inc_wan inc_fritz inc_server <<< "$incident_data"

  local incident_section
  if [ "${inc_fail:-0}" -eq 0 ]; then
    incident_section="✅ Sin incidentes registrados hoy"
  else
    incident_section="⚠️ *Incidentes hoy:*
  • Fallos detectados: ${inc_fail}
  • Reconexiones WAN forzadas: ${inc_wan}
  • Reboots FritzBox: ${inc_fritz}
  • Reboots servidor: ${inc_server}"
  fi

  local ip_changes ip_section
  ip_changes=$(get_ip_changes_today)
  ip_section="*Cambios de IP hoy:* ${ip_changes}"
  [ "${ip_changes:-0}" -gt 0 ] && ip_section="⚠️ ${ip_section}"

  # Fallos parciales del día (#7)
  local instability_section=""
  if [ -f "${STATE_PARTIAL_FAIL_FILE:-}" ]; then
    local today stored_date stored_count
    today=$(date '+%Y-%m-%d')
    IFS='|' read -r stored_date stored_count < "$STATE_PARTIAL_FAIL_FILE" 2>/dev/null || true
    if [ "${stored_date:-}" = "$today" ] && [ "${stored_count:-0}" -gt 0 ]; then
      instability_section="
⚡ *Ciclos con fallos parciales hoy:* ${stored_count}"
    fi
  fi

  # Certificados TLS próximos a expirar — sección solo si hay avisos
  local tls_section=""
  if command -v openssl > /dev/null 2>&1; then
    local warn_days="${CERT_EXPIRY_WARN_DAYS:-14}"
    local now_ts tls_lines=""
    now_ts=$(date +%s)
    local _tls_url_list
    IFS=',' read -ra _tls_url_list <<< "$URLS"
    for _tls_u in "${_tls_url_list[@]}"; do
      _tls_u=$(echo "$_tls_u" | tr -d '[:space:]')
      [[ "$_tls_u" =~ ^https:// ]] || continue
      local _tls_host _tls_expiry_date _tls_expiry_ts _tls_days_left
      _tls_host=$(printf '%s' "$_tls_u" | sed 's|https://||' | cut -d'/' -f1 | cut -d':' -f1)
      _tls_expiry_date=$(echo | timeout 4 openssl s_client -connect "${_tls_host}:443" \
        -servername "$_tls_host" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      [ -z "$_tls_expiry_date" ] && continue
      _tls_expiry_ts=$(date -d "$_tls_expiry_date" +%s 2>/dev/null) || continue
      _tls_days_left=$(( (_tls_expiry_ts - now_ts) / 86400 ))
      if [ "$_tls_days_left" -le 0 ]; then
        tls_lines+="  ❌ \`${_tls_host}\` — EXPIRADO\n"
      elif [ "$_tls_days_left" -le "$warn_days" ]; then
        tls_lines+="  ⚠️ \`${_tls_host}\` — ${_tls_days_left} días\n"
      fi
    done
    [ -n "$tls_lines" ] && tls_section="
⚠️ *Certificados próximos a expirar:*
$(printf '%b' "$tls_lines")"
  fi

  telegram_notify "📅 *Informe Diario — Proxmox Watchdog*
🖥 $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')

*Servidor:*
  • Uptime: ${server_uptime}
  • IP pública: \`${current_ip}\`

${fritz_section}

${incident_section}${instability_section}

${ip_section}${tls_section}"

  log "[REPORT] Informe diario enviado."
}

# ============================================================
# INFORME SEMANAL (#10)
# ============================================================

send_weekly_report() {
  log "[REPORT] Generando informe semanal (v${VERSION})..."

  local current_ip server_uptime
  current_ip=$(get_public_ip || echo "no disponible")
  server_uptime=$(get_server_uptime)

  # Estadísticas esta semana vs semana anterior
  local this_raw prev_raw
  this_raw=$(incident_stats 7 0)
  prev_raw=$(incident_stats 7 7)

  local this_total this_resolved this_avg this_max this_wan this_fritz this_server this_spont
  local prev_total prev_avg _ __ ___ ____ _____ ______
  IFS='|' read -r this_total this_resolved this_avg this_max this_wan this_fritz this_server this_spont _ <<< "$this_raw"
  IFS='|' read -r prev_total _ prev_avg _ __ ___ ____ _____ <<< "$prev_raw"

  # Uptime estimado
  local uptime_pct="100.00"
  if [ "${this_resolved:-0}" -gt 0 ] && [ "${this_avg:-0}" -gt 0 ]; then
    uptime_pct=$(awk "BEGIN {
      total_down = ${this_avg} * ${this_resolved}
      pct = 100 - (total_down / (7 * 1440) * 100)
      if (pct < 0) pct = 0
      printf \"%.2f\", pct
    }")
  fi

  # Tendencia comparativa
  local trend_inc trend_dur
  if [ "${prev_total:-0}" -gt 0 ]; then
    if [ "${this_total:-0}" -lt "$prev_total" ]; then
      trend_inc="↘️ menos que la sem. anterior (${prev_total})"
    elif [ "${this_total:-0}" -gt "$prev_total" ]; then
      trend_inc="↗️ más que la sem. anterior (${prev_total})"
    else
      trend_inc="→ igual que la sem. anterior (${prev_total})"
    fi
  else
    trend_inc="(sin datos semana anterior)"
  fi

  if [ "${prev_avg:-0}" -gt 0 ]; then
    if [ "${this_avg:-0}" -lt "$prev_avg" ]; then
      trend_dur="↘️ menor (anterior: ${prev_avg} min)"
    elif [ "${this_avg:-0}" -gt "$prev_avg" ]; then
      trend_dur="↗️ mayor (anterior: ${prev_avg} min)"
    else
      trend_dur="→ igual (anterior: ${prev_avg} min)"
    fi
  else
    trend_dur="(sin datos semana anterior)"
  fi

  # Fritz
  local fritz_result fritz_ok fritz_section
  fritz_result=$(get_fritz_info false) || true
  fritz_ok=$?
  if [ "$fritz_ok" -eq 0 ]; then
    IFS='|' read -r _ fritz_model fritz_router_uptime fritz_wan_status fritz_wan_uptime _ \
      <<< "$fritz_result"
    fritz_section="*FritzBox:* ${fritz_wan_status} — Uptime: ${fritz_router_uptime}"
  else
    fritz_section="*FritzBox:* ❌ No disponible"
  fi

  # Incidentes con acciones de la semana (máx 3 para no saturar)
  local recent_incidents=""
  if [ "${this_total:-0}" -gt 0 ] && [ -f "$INCIDENTS_FILE" ]; then
    recent_incidents="
*Últimos incidentes:*
$(incident_history 3 "--failed")"
  fi

  telegram_notify "📆 *Informe Semanal — Proxmox Watchdog*
🖥 $(hostname) — semana hasta $(date '+%Y-%m-%d %H:%M:%S')

*Servidor:*
  • Uptime sistema: ${server_uptime}
  • IP pública: \`${current_ip}\`
  • ${fritz_section}

*Resumen de la semana:*
  • Incidentes: ${this_total:-0} — ${trend_inc}
  • Uptime estimado: \`${uptime_pct}%\`
  • Duración media: ${this_avg:-0} min — ${trend_dur}
  • Duración máxima: ${this_max:-0} min

*Acciones tomadas:*
  • Reconexiones WAN: ${this_wan:-0}
  • Reboots Fritz: ${this_fritz:-0}
  • Reboots servidor: ${this_server:-0}
  • Recuperaciones espontáneas: ${this_spont:-0}
${recent_incidents}"

  log "[REPORT] Informe semanal enviado."
}

# ============================================================
# EJECUCIÓN
# ============================================================

case "$MODE" in
  daily)  send_daily_report ;;
  weekly) send_weekly_report ;;
esac
