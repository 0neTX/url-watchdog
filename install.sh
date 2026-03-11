#!/bin/bash
# ============================================================
#  install.sh — Instalación/actualización del watchdog
# ============================================================
set -euo pipefail

# --- Verificar root (#11) -----------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Este script debe ejecutarse como root." >&2
  echo "[ERROR] Usa: sudo ./install.sh" >&2
  exit 1
fi

ENV_FILE="/etc/url-watchdog/.env"
ENV_TEMPLATE="./url-watchdog.env"
BIN="/usr/local/bin"
SYSTEMD="/etc/systemd/system"
STATE_DIR="/run/url-watchdog"
PERSIST_DIR="/var/lib/url-watchdog"

# Lee una variable del .env sin ejecutar el fichero
read_env_var() {
  local file="$1" key="$2"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
    | tail -1 \
    | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" \
    | sed -E 's/[[:space:]]*(#.*)?$//' \
    | sed -E "s/^\"(.*)\"\$/\\1/" \
    | sed -E "s/^'(.*)'\$/\\1/"
}

# Añade al .env existente las variables nuevas del template
migrate_env() {
  local env_file="$1" template_file="$2"
  local added=0
  echo "==> Comprobando migración del .env..."
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]] || continue
    local key="${BASH_REMATCH[1]}"
    if ! grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$env_file" 2>/dev/null; then
      if [ "$added" -eq 0 ]; then
        printf '\n# ---- Migración %s ----\n' "$(date '+%Y-%m-%d')" >> "$env_file"
      fi
      printf '%s\n' "$line" >> "$env_file"
      echo "    → Añadida variable nueva: ${key}"
      (( added++ )) || true
    fi
  done < "$template_file"
  if [ "$added" -gt 0 ]; then
    echo "    ✅ Migración completada: ${added} variable(s) añadida(s)."
    echo "    Revisa $env_file y rellena los nuevos valores si es necesario."
  else
    echo "    ✅ El .env ya está actualizado."
  fi
}

# --- Verificar ficheros fuente antes de copiar (#17) --------
echo "==> Verificando ficheros fuente..."
REQUIRED_FILES=(
  url-watchdog-common.sh
  url-watchdog.sh
  telegram-bot.sh
  url-watchdog-report.sh
  url-watchdog.service
  url-watchdog.timer
  url-watchdog-report.service
  url-watchdog-report.timer
  telegram-bot.service
  "$ENV_TEMPLATE"
)
MISSING=0
for f in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "    [ERROR] Fichero no encontrado: $f" >&2
    MISSING=$(( MISSING + 1 ))
  fi
done
if [ "$MISSING" -gt 0 ]; then
  echo "[ERROR] Faltan ${MISSING} fichero(s). Verifica que ejecutas install.sh" >&2
  echo "[ERROR] desde el directorio raíz del repositorio clonado." >&2
  exit 1
fi
echo "    ✅ Todos los ficheros presentes."

# --- Instalación --------------------------------------------

echo "==> Copiando scripts..."
cp url-watchdog-common.sh  "$BIN/url-watchdog-common.sh"
cp url-watchdog.sh         "$BIN/url-watchdog.sh"
cp telegram-bot.sh         "$BIN/telegram-bot.sh"
cp url-watchdog-report.sh  "$BIN/url-watchdog-report.sh"
chmod +x \
  "$BIN/url-watchdog-common.sh" \
  "$BIN/url-watchdog.sh" \
  "$BIN/telegram-bot.sh" \
  "$BIN/url-watchdog-report.sh"

echo "==> Instalando configuración..."
mkdir -p /etc/url-watchdog
if [ ! -f "$ENV_FILE" ]; then
  cp "$ENV_TEMPLATE" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "    → .env creado. Edita $ENV_FILE antes de continuar."
else
  echo "    → $ENV_FILE ya existe, no se sobreescribe."
  migrate_env "$ENV_FILE" "$ENV_TEMPLATE"
fi

echo "==> Creando directorios de estado..."
mkdir -p "$STATE_DIR"   && chmod 700 "$STATE_DIR"
mkdir -p "$PERSIST_DIR" && chmod 700 "$PERSIST_DIR"

echo "==> Instalando unidades systemd..."
cp url-watchdog.service         "$SYSTEMD/"
cp url-watchdog.timer           "$SYSTEMD/"
cp url-watchdog-report.service  "$SYSTEMD/"
cp url-watchdog-report.timer    "$SYSTEMD/"
[ -f url-watchdog-weekly.service ] && cp url-watchdog-weekly.service "$SYSTEMD/" || true
[ -f url-watchdog-weekly.timer   ] && cp url-watchdog-weekly.timer   "$SYSTEMD/" || true
cp telegram-bot.service         "$SYSTEMD/"
[ -f url-watchdog-boot.service ] && cp url-watchdog-boot.service "$SYSTEMD/" || true

echo "==> Instalando tmpfiles.d..."
if [ -f url-watchdog-tmpfiles.conf ]; then
  cp url-watchdog-tmpfiles.conf /etc/tmpfiles.d/url-watchdog.conf
  systemd-tmpfiles --create /etc/tmpfiles.d/url-watchdog.conf
fi

# Ajustar hora del informe diario y semanal
DAILY_TIME=$(read_env_var "$ENV_FILE" "DAILY_REPORT_TIME")
if [ -n "$DAILY_TIME" ]; then
  if [[ "$DAILY_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "==> Configurando informe diario a las ${DAILY_TIME}..."
    sed -i "s|OnCalendar=.*|OnCalendar=*-*-* ${DAILY_TIME}:00|" \
      "$SYSTEMD/url-watchdog-report.timer"
    [ -f "$SYSTEMD/url-watchdog-weekly.timer" ] && \
      sed -i "s|OnCalendar=Mon .*|OnCalendar=Mon *-*-* ${DAILY_TIME}:00|" \
      "$SYSTEMD/url-watchdog-weekly.timer" || true
  else
    echo "    ⚠️  DAILY_REPORT_TIME='${DAILY_TIME}' no tiene formato HH:MM. Timer no modificado."
  fi
fi

echo "==> Recargando systemd..."
systemctl daemon-reload

echo "==> Habilitando y arrancando servicios..."
systemctl enable --now url-watchdog.timer
systemctl enable --now url-watchdog-report.timer
[ -f "$SYSTEMD/url-watchdog-weekly.timer" ] && systemctl enable --now url-watchdog-weekly.timer || true
systemctl enable --now telegram-bot.service
[ -f "$SYSTEMD/url-watchdog-boot.service" ] && \
  systemctl enable url-watchdog-boot.service || true

echo ""
echo "✅ Instalación completada."
echo ""
echo "Próximos pasos:"
echo "  1. Edita $ENV_FILE con tus credenciales"
echo "     (TELEGRAM_TOKEN, TELEGRAM_CHAT_ID, FRITZ_PASSWORD, ...)"
echo "  2. Genera SHA256SUMS en tu repo para /update seguro:"
echo "     sha256sum url-watchdog-*.sh telegram-bot.sh > SHA256SUMS"
echo "  3. Prueba: /usr/local/bin/url-watchdog.sh --test"
echo "  4. Reinicia el bot: systemctl restart telegram-bot.service"
