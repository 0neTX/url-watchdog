#!/bin/bash
# docker-entrypoint.sh — Punto de entrada del contenedor url-watchdog
# Gestiona: generación dinámica del crontab, crond, telegram-bot y boot notification.
set -euo pipefail

ENV_FILE="/etc/url-watchdog/.env"

# --- Validar que el .env está montado -----------------------
if [ ! -f "$ENV_FILE" ]; then
  echo "[ENTRYPOINT] ERROR: ${ENV_FILE} no encontrado." >&2
  echo "[ENTRYPOINT] Monta tu .env en docker-compose.yml:" >&2
  echo "[ENTRYPOINT]   - /opt/url-watchdog/config/.env:${ENV_FILE}:ro" >&2
  exit 1
fi

# --- Leer variable del .env sin ejecutarlo ------------------
# Replica el comportamiento seguro de load_env() para este contexto pre-arranque.
_read_env_var() {
  local key="$1"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE" 2>/dev/null \
    | tail -1 \
    | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" \
    | sed -E 's/[[:space:]]*(#.*)?$//' \
    | sed -E 's/^"(.*)"$/\1/' \
    | sed -E "s/^'(.*)'$/\\1/"
}

# --- Leer DAILY_REPORT_TIME ---------------------------------
DAILY_REPORT_TIME=$(_read_env_var "DAILY_REPORT_TIME")
DAILY_REPORT_TIME="${DAILY_REPORT_TIME:-08:00}"

if ! [[ "$DAILY_REPORT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  echo "[ENTRYPOINT] WARN: DAILY_REPORT_TIME='${DAILY_REPORT_TIME}' inválido. Usando 08:00." >&2
  DAILY_REPORT_TIME="08:00"
fi

DAILY_HOUR="${DAILY_REPORT_TIME%%:*}"
DAILY_MIN="${DAILY_REPORT_TIME##*:}"

# --- Generar crontab dinámico --------------------------------
cat > /etc/cron.d/url-watchdog << CRONEOF
# url-watchdog — generado por docker-entrypoint.sh al arrancar el contenedor
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Watchdog principal: cada minuto
* * * * * root /usr/local/bin/url-watchdog.sh >> /var/log/url-watchdog-cron.log 2>&1

# Informe diario
${DAILY_MIN} ${DAILY_HOUR} * * * root /usr/local/bin/url-watchdog-report.sh --daily >> /var/log/url-watchdog-cron.log 2>&1

# Informe semanal (lunes a la misma hora)
${DAILY_MIN} ${DAILY_HOUR} * * 1 root /usr/local/bin/url-watchdog-report.sh --weekly >> /var/log/url-watchdog-cron.log 2>&1
CRONEOF

chmod 644 /etc/cron.d/url-watchdog

echo "[ENTRYPOINT] Crontab generado:"
echo "[ENTRYPOINT]   Watchdog: cada minuto"
echo "[ENTRYPOINT]   Informe diario:   ${DAILY_HOUR}:${DAILY_MIN}"
echo "[ENTRYPOINT]   Informe semanal:  lunes ${DAILY_HOUR}:${DAILY_MIN}"

# --- Asegurar directorios de estado -------------------------
mkdir -p /run/url-watchdog     && chmod 700 /run/url-watchdog
mkdir -p /var/lib/url-watchdog && chmod 700 /var/lib/url-watchdog

# --- Arrancar crond -----------------------------------------
crond
CRON_PID=$(pgrep -x crond || true)
echo "[ENTRYPOINT] crond arrancado (PID: ${CRON_PID:-?})"

# --- Notificación de boot: --test antes de arrancar el bot --
# Equivalente a url-watchdog-boot.service: estado inicial + info Fritz
echo "[ENTRYPOINT] Ejecutando --test inicial (boot notification)..."
/usr/local/bin/url-watchdog.sh --test || true

# --- Función de shutdown limpio -----------------------------
_shutdown() {
  echo "[ENTRYPOINT] Señal de parada recibida. Deteniendo procesos..."
  [ -n "${BOT_PID:-}" ] && kill "$BOT_PID" 2>/dev/null || true
  pkill -x crond 2>/dev/null || true
  wait "${BOT_PID:-}" 2>/dev/null || true
  echo "[ENTRYPOINT] Shutdown limpio."
  exit 0
}
trap _shutdown SIGTERM SIGINT SIGQUIT

# --- Arrancar telegram-bot.sh y supervisarlo ----------------
# Replica el comportamiento de Restart=on-failure del .service:
#   - exit 0 (p.ej. tras /update): reinicia en 2s
#   - exit != 0 (crash):           reinicia en 10s
while true; do
  /usr/local/bin/telegram-bot.sh &
  BOT_PID=$!
  echo "[ENTRYPOINT] telegram-bot.sh arrancado (PID: ${BOT_PID})"

  wait "$BOT_PID" || true
  BOT_EXIT=$?

  # Si crond murió el contenedor está roto: salir para que Docker lo reinicie
  if ! pgrep -x crond >/dev/null 2>&1; then
    echo "[ENTRYPOINT] FATAL: crond ha muerto. Saliendo para que Docker reinicie el contenedor." >&2
    exit 1
  fi

  if [ "$BOT_EXIT" -eq 0 ]; then
    echo "[ENTRYPOINT] Bot terminó limpiamente (exit 0). Reiniciando en 2s..."
    sleep 2
  else
    echo "[ENTRYPOINT] Bot terminó con error (exit ${BOT_EXIT}). Reiniciando en 10s..."
    sleep 10
  fi
done
