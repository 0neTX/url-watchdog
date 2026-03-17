#!/bin/bash
# ============================================================
#  uninstall.sh — Desinstalación completa del watchdog
# ============================================================
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Este script debe ejecutarse como root." >&2
  echo "[ERROR] Usa: sudo ./uninstall.sh" >&2
  exit 1
fi

BIN="/usr/local/bin"
SYSTEMD="/etc/systemd/system"

SCRIPTS=(
  url-watchdog-common.sh
  url-watchdog.sh
  telegram-bot.sh
  url-watchdog-report.sh
)

UNITS=(
  url-watchdog.timer
  url-watchdog.service
  url-watchdog-report.timer
  url-watchdog-report.service
  url-watchdog-weekly.timer
  url-watchdog-weekly.service
  url-watchdog-boot.service
  telegram-bot.service
)

# Pedir confirmación si el terminal es interactivo
if [ -t 0 ]; then
  echo "⚠️  Este script eliminará:"
  echo "   - Scripts en $BIN"
  echo "   - Unidades systemd en $SYSTEMD"
  echo "   - Ficheros tmpfiles.d"
  echo ""
  echo "   Los siguientes directorios/ficheros se conservan por defecto:"
  echo "   - /etc/url-watchdog/.env  (configuración con credenciales)"
  echo "   - /var/lib/url-watchdog/  (historial de incidentes)"
  echo ""
  echo "   Pasa --purge para eliminarlos también."
  echo ""
  read -rp "¿Continuar? [s/N] " confirm
  [[ "$confirm" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }
fi

PURGE=0
for arg in "$@"; do
  [[ "$arg" == "--purge" ]] && PURGE=1
done

# --- 1. Detener y deshabilitar unidades ----------------------
echo "==> Deteniendo y deshabilitando unidades systemd..."
for unit in "${UNITS[@]}"; do
  if systemctl list-unit-files --quiet "${unit}" 2>/dev/null | grep -q "${unit}"; then
    systemctl disable --now "${unit}" 2>/dev/null || true
    echo "    → Deshabilitado: ${unit}"
  fi
done

# --- 2. Eliminar ficheros de unidades ------------------------
echo "==> Eliminando unidades systemd..."
for unit in "${UNITS[@]}"; do
  if [ -f "$SYSTEMD/$unit" ]; then
    rm -f "$SYSTEMD/$unit"
    echo "    → Eliminado: $SYSTEMD/$unit"
  fi
done

systemctl daemon-reload
echo "    ✅ systemd recargado."

# --- 3. Eliminar scripts -------------------------------------
echo "==> Eliminando scripts..."
for script in "${SCRIPTS[@]}"; do
  if [ -f "$BIN/$script" ]; then
    rm -f "$BIN/$script"
    echo "    → Eliminado: $BIN/$script"
  fi
done

# --- 4. Eliminar tmpfiles.d ----------------------------------
if [ -f /etc/tmpfiles.d/url-watchdog.conf ]; then
  rm -f /etc/tmpfiles.d/url-watchdog.conf
  echo "==> Eliminado: /etc/tmpfiles.d/url-watchdog.conf"
fi

# --- 5. Eliminar estado volátil ------------------------------
if [ -d /run/url-watchdog ]; then
  rm -rf /run/url-watchdog
  echo "==> Eliminado: /run/url-watchdog (estado volátil)"
fi

# --- 6. Purge opcional ---------------------------------------
if [ "$PURGE" -eq 1 ]; then
  echo "==> [PURGE] Eliminando configuración y datos persistentes..."
  if [ -d /etc/url-watchdog ]; then
    rm -rf /etc/url-watchdog
    echo "    → Eliminado: /etc/url-watchdog"
  fi
  if [ -d /var/lib/url-watchdog ]; then
    rm -rf /var/lib/url-watchdog
    echo "    → Eliminado: /var/lib/url-watchdog"
  fi
  if [ -f /var/log/url-watchdog.log ]; then
    rm -f /var/log/url-watchdog.log
    echo "    → Eliminado: /var/log/url-watchdog.log"
  fi
else
  echo ""
  echo "ℹ️  Conservados (usa --purge para eliminarlos):"
  [ -d /etc/url-watchdog ]      && echo "   - /etc/url-watchdog/.env"
  [ -d /var/lib/url-watchdog ]  && echo "   - /var/lib/url-watchdog/ (historial de incidentes)"
  [ -f /var/log/url-watchdog.log ] && echo "   - /var/log/url-watchdog.log"
fi

echo ""
echo "✅ Desinstalación completada."
