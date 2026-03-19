#!/bin/bash
# install-docker.sh — Instala la arquitectura Docker de url-watchdog
# Uso: sudo ./install-docker.sh
set -euo pipefail

[ "$EUID" -ne 0 ] && { echo "[ERROR] Este script requiere root (sudo)."; exit 1; }

INSTALL_DIR="/opt/url-watchdog"
CONFIG_DIR="${INSTALL_DIR}/config"
DATA_DIR="${INSTALL_DIR}/data"
LOG_DIR="${INSTALL_DIR}/log"

echo "==> Verificando dependencias del host..."
if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] Docker no encontrado."
  echo "       Instala Docker: https://docs.docker.com/engine/install/"
  exit 1
fi

echo "==> Creando directorios en ${INSTALL_DIR}..."
mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
chmod 700 "$DATA_DIR"
chmod 755 "$CONFIG_DIR" "$LOG_DIR"

echo "==> Configurando .env..."
if [ ! -f "${CONFIG_DIR}/.env" ]; then
  cp url-watchdog.env "${CONFIG_DIR}/.env"
  chmod 600 "${CONFIG_DIR}/.env"
  echo ""
  echo "    IMPORTANTE: Edita ${CONFIG_DIR}/.env antes de continuar."
  echo "    Configura al menos: URLS, FRITZ_IP, FRITZ_USER, FRITZ_PASSWORD,"
  echo "    TELEGRAM_TOKEN, TELEGRAM_CHAT_ID, ALLOWED_CHAT_IDS"
  echo ""
  echo "    Para reboot del nodo Proxmox (fase 4 de recuperación):"
  echo "    Configura también: PROXMOX_HOST, PROXMOX_NODE,"
  echo "    PROXMOX_TOKEN_ID, PROXMOX_TOKEN_SECRET"
  echo ""
  read -r -p "    ¿Abrir el editor ahora? [s/N] " answer
  if [[ "${answer,,}" == "s" ]]; then
    ${EDITOR:-nano} "${CONFIG_DIR}/.env"
  fi
else
  echo "    .env ya existe. Comprobando migración..."
  # Migrar instalaciones antiguas con señal de fichero
  if grep -q "^REBOOT_SIGNAL_FILE" "${CONFIG_DIR}/.env"; then
    sed -i '/^REBOOT_SIGNAL_FILE/d' "${CONFIG_DIR}/.env"
    printf '\n# --- Reboot vía API Proxmox ---\nPROXMOX_HOST=""\nPROXMOX_NODE=""\nPROXMOX_TOKEN_ID=""\nPROXMOX_TOKEN_SECRET=""\n' \
      >> "${CONFIG_DIR}/.env"
    echo "    → Migrado: REBOOT_SIGNAL_FILE eliminado, variables PROXMOX_* añadidas."
  fi
fi

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
