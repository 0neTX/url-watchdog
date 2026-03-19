#!/bin/bash
# install-docker.sh — Instala la arquitectura Docker de url-watchdog
# Uso: sudo ./install-docker.sh
set -euo pipefail

[ "$EUID" -ne 0 ] && { echo "[ERROR] Este script requiere root (sudo)."; exit 1; }

INSTALL_DIR="/opt/url-watchdog"
CONFIG_DIR="${INSTALL_DIR}/config"
DATA_DIR="${INSTALL_DIR}/data"
LOG_DIR="${INSTALL_DIR}/log"
SIGNAL_DIR="${INSTALL_DIR}/signals"
SYSTEMD="/etc/systemd/system"

echo "==> Verificando dependencias del host..."
for cmd in docker inotifywait; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Comando no encontrado: ${cmd}"
    [ "$cmd" = "docker" ] && echo "       Instala Docker: https://docs.docker.com/engine/install/"
    [ "$cmd" = "inotifywait" ] && echo "       Instala inotify-tools: apt install inotify-tools"
    exit 1
  fi
done

echo "==> Creando directorios en ${INSTALL_DIR}..."
mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$SIGNAL_DIR"
chmod 700 "$DATA_DIR" "$SIGNAL_DIR"
chmod 755 "$CONFIG_DIR" "$LOG_DIR"

echo "==> Configurando .env..."
if [ ! -f "${CONFIG_DIR}/.env" ]; then
  cp url-watchdog.env "${CONFIG_DIR}/.env"
  chmod 600 "${CONFIG_DIR}/.env"
  # Activar la señal de reboot Docker automáticamente
  sed -i 's|^REBOOT_SIGNAL_FILE=.*|REBOOT_SIGNAL_FILE=/run/signals/reboot.request|' \
    "${CONFIG_DIR}/.env"
  echo ""
  echo "    IMPORTANTE: Edita ${CONFIG_DIR}/.env antes de continuar."
  echo "    Configura al menos: URLS, FRITZ_IP, FRITZ_USER, FRITZ_PASSWORD,"
  echo "    TELEGRAM_TOKEN, TELEGRAM_CHAT_ID, ALLOWED_CHAT_IDS"
  echo ""
  read -r -p "    ¿Abrir el editor ahora? [s/N] " answer
  if [[ "${answer,,}" == "s" ]]; then
    ${EDITOR:-nano} "${CONFIG_DIR}/.env"
  fi
else
  echo "    .env ya existe. Comprobando migración..."
  if ! grep -q "^REBOOT_SIGNAL_FILE" "${CONFIG_DIR}/.env"; then
    printf '\n# --- Modo Docker (señal de reboot) ---\nREBOOT_SIGNAL_FILE=/run/signals/reboot.request\n' \
      >> "${CONFIG_DIR}/.env"
    echo "    → Variable REBOOT_SIGNAL_FILE añadida."
  fi
fi

echo "==> Instalando servicio de reboot del host..."
cp url-watchdog-reboot.service "$SYSTEMD/"
systemctl daemon-reload
systemctl enable --now url-watchdog-reboot.service
echo "    url-watchdog-reboot.service habilitado y arrancado."

echo "==> Construyendo imagen Docker..."
docker compose build

echo "==> Arrancando contenedor..."
docker compose up -d

echo ""
echo "=========================================="
echo " Instalación completada"
echo "=========================================="
echo "  Config: ${CONFIG_DIR}/.env"
echo "  Logs:   tail -f ${LOG_DIR}/url-watchdog.log"
echo "  Estado: docker compose ps"
echo "  Bot:    docker compose logs -f url-watchdog"
echo "  Parar:  docker compose down"
echo "=========================================="
