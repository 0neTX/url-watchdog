#!/bin/bash
# install-docker.sh — Configura y arranca url-watchdog con Docker
# Uso: ./install-docker.sh  (no requiere root)
set -euo pipefail

echo "==> Verificando dependencias..."
if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] Docker no encontrado."
  echo "       Instala Docker: https://docs.docker.com/engine/install/"
  exit 1
fi

# --- Crear directorios de datos/logs en el directorio del proyecto ----
echo "==> Creando directorios de datos y logs..."
mkdir -p data/watchdog log

# --- Configurar .env --------------------------------------------------
echo "==> Configurando .env..."
if [ ! -f ".env" ]; then
  cp .env.example .env
  chmod 600 .env
  echo ""
  echo "    IMPORTANTE: Edita .env antes de continuar."
  echo "    Configura al menos:"
  echo "      URLS, FRITZ_IP, FRITZ_USER, FRITZ_PASSWORD"
  echo "      TELEGRAM_TOKEN, TELEGRAM_CHAT_ID, ALLOWED_CHAT_IDS"
  echo ""
  echo "    Para reboot del nodo Proxmox (fase 4 de recuperación):"
  echo "      PROXMOX_HOST, PROXMOX_NODE, PROXMOX_TOKEN_ID, PROXMOX_TOKEN_SECRET"
  echo ""
  read -r -p "    ¿Abrir el editor ahora? [s/N] " answer
  if [[ "${answer,,}" == "s" ]]; then
    ${EDITOR:-nano} .env
  fi
else
  echo "    .env ya existe. Omitiendo copia de la plantilla."
fi

# --- Construir y arrancar ---------------------------------------------
echo "==> Construyendo imágenes Docker..."
docker compose build

echo "==> Arrancando contenedores..."
docker compose up -d

echo ""
echo "=========================================="
echo " Instalación completada"
echo "=========================================="
echo "  Logs watchdog:  tail -f log/url-watchdog.log"
echo "  Logs:           docker compose logs -f url-watchdog"
echo "  Estado:         docker compose ps"
echo "  Parar:          docker compose down"
echo "=========================================="
