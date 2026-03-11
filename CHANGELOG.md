# Changelog

Todos los cambios notables se documentan en este fichero.
El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.0.0/).

---

## [2.2.0] - 2026-03-11

### Added

**#1 — Verificación de LAN antes de actuar sobre Fritz**
- Nueva función `check_local_network()` en `url-watchdog-common.sh`: obtiene la ruta por defecto con `ip route get` y hace ping al gateway local
- El watchdog comprueba la LAN en FASE 2 antes de intentar reconectar WAN o reiniciar la Fritz. Si la LAN está rota, notifica con diagnóstico diferenciado (`lan_failure`) y no toca la Fritz
- Nuevo fichero de estado `watchdog.lan-fail`: evita reenviar la alerta de LAN rota en cada ciclo; se limpia cuando la LAN se recupera
- Nueva variable de estado: `STATE_LAN_FAIL_FILE`
- El reset manual (`--reset`, `/reset`) también limpia `STATE_LAN_FAIL_FILE`

**#2 — `FAIL_MODE=quorum`**
- Nuevo modo de detección: actúa si al menos `FAIL_QUORUM` de N URLs fallan
- `FAIL_QUORUM` se valida al arrancar (entero ≥ 1, no mayor que el número de URLs)
- `build_status_message()` muestra `quorum 2/4` en lugar de solo el modo
- Nueva variable: `FAIL_QUORUM=2`

**#5 — Latencia por URL en el log**
- `check_urls()` usa `--write-out "%{http_code}|%{time_total}"` para capturar latencia sin petición extra
- Cada línea OK del log incluye el tiempo de respuesta: `OK  https://google.com (HTTP 200, 87ms)`
- `_check_url_detail()` en el bot usa el mismo mecanismo para `/ping` y `/diagnose`

**#6 — Comando `/stats`**
- Nueva función `incident_stats()` en `url-watchdog-common.sh`: calcula sobre `incidents.json` para un período y offset arbitrarios usando `jq`
- Estadísticas: total, resueltos, activos, duración media/máxima, uptime estimado, conteo de cada acción, recuperaciones espontáneas, comparativa con período anterior
- Nuevo comando `/stats [days]` (default: 30, max: 365) con tendencia respecto al período anterior

**#7 — Alerta de inestabilidad parcial**
- Nueva función `check_instability()` en `url-watchdog-common.sh`
- Se activa cuando hay fallos parciales (algunos pero no todos) repetidos, sin llegar al umbral de acción
- Alerta tras `INSTABILITY_THRESHOLD` ciclos consecutivos con fallos parciales; se resetea tras alertar para evitar spam
- Solo aplica en modos `all` y `quorum`; en modo `any` cualquier fallo ya es total
- Nuevo fichero de estado `watchdog.partial-fail`: contador diario de ciclos con fallos parciales
- `build_status_message()` muestra los fallos parciales del día en `/status`
- El informe diario incluye la sección de inestabilidad si hubo ciclos parciales
- Nueva variable: `INSTABILITY_THRESHOLD=3`, `STATE_PARTIAL_FAIL_FILE`

**#8 — Alerta de expiración de certificados TLS**
- Nueva función `check_tls_expiry()` en `url-watchdog-common.sh`
- Usa `openssl s_client` para comprobar la fecha de expiración de cada URL HTTPS
- Se ejecuta una sola vez al día (controlado con `STATE_TLS_CHECK_FILE`)
- Alerta si el certificado expira en menos de `CERT_EXPIRY_WARN_DAYS` días
- Alerta urgente si el certificado ya ha expirado
- `cmd_diagnose()` del bot incluye el estado TLS de cada URL en tiempo real
- Nuevas variables: `CERT_EXPIRY_WARN_DAYS=14`, `STATE_TLS_CHECK_FILE`

**#9 — Comandos del bot extendidos**
- `/ping` sin argumento: comprueba todas las URLs monitorizadas y muestra estado + latencia
- `/silence status`: muestra el tiempo restante sin desactivar el silencio
- `/silence off`: desactiva el silencio activo
- `/history --failed` (también `-f`): muestra solo los incidentes que requirieron alguna acción
- `/log tail`: inicia seguimiento del log; envía las nuevas entradas a +30s y +60s en procesos background

**#10 — Informe semanal automático**
- `url-watchdog-report.sh --weekly`: genera un informe comparativo de 7 días vs 7 días anteriores
- Contenido: uptime estimado, total de incidentes con tendencia, duración media/máxima, acciones tomadas, últimos 3 incidentes con acciones
- Nuevas units: `url-watchdog-weekly.service` y `url-watchdog-weekly.timer` (lunes a la misma hora que el informe diario)
- `install.sh` las instala y configura automáticamente

**#12 — Comando `/diagnose`**
- Nuevo comando que agrupa en un solo mensaje: IP pública, estado LAN/gateway, Fritz (modelo + WAN + uptime), todas las URLs con código HTTP y latencia, estado TLS de cada URL HTTPS, y las últimas 5 líneas del log
- Sustituye el tener que ejecutar `/ip`, `/fritz`, `/ping`, `/traceroute` por separado

### Changed
- `check_urls()` ahora actualiza la variable global `FAILED_URL_COUNT` (usada por `check_instability()`)
- `url-watchdog.sh` llama a `check_instability()` cuando las URLs están dentro del umbral pero con fallos parciales
- `url-watchdog.sh` llama a `check_tls_expiry()` una vez al día tras las comprobaciones de Fritz
- `incident_history()` acepta segundo parámetro `--failed` para filtrar incidentes sin acciones
- `build_status_message()` muestra el modo como `quorum N/M` cuando `FAIL_MODE=quorum`
- `install.sh` versión 2.2.0: instala y configura las nuevas units (`url-watchdog-weekly.*`), aplica hora del informe semanal al timer correspondiente
- `url-watchdog.env` añade variables: `FAIL_QUORUM`, `INSTABILITY_THRESHOLD`, `CERT_EXPIRY_WARN_DAYS`, `STATE_PARTIAL_FAIL_FILE`, `STATE_TLS_CHECK_FILE`, `STATE_LAN_FAIL_FILE`
- Todos los scripts actualizados a `VERSION="2.2.0"`

---

## [2.1.0] - 2026-03-10

### Fixed
- Bug: `_restart_status_report` contabilizaba incorrectamente las URLs correctas cuando `ok_count` empezaba en 0
- Bug: `check_fritz_unexpected_reboot` no notificaba en el primer ciclo elegible exacto por usar `-gt` en lugar de `-ge`
- Bug: `cmd_update` dejaba el fichero temporal `SHA256SUMS` en `STATE_DIR` si algún script fallaba la verificación
- Bug: `load_env` capturaba hasta la última `"` en lugar de la primera cuando el comentario inline contenía comillas
- Bug: `telegram_send` reportaba N+1 intentos en el mensaje de error de log

### Added
- `VERSION="2.1.0"` en todos los scripts; `/version` en el bot
- `require_vars()`: validación centralizada de variables requeridas
- `_read_state_ts()`, `_write_state()`: lecturas y escrituras de estado seguras y atómicas
- `url-watchdog-tmpfiles.conf`: crea `/run/url-watchdog` en cada boot
- `FRITZ_REBOOT_CHECK_INTERVAL`: limita llamadas SOAP a ~288/día en lugar de 1440
- `url-watchdog-boot.service`: notificación `--test` al arrancar el sistema
- `migrate_env()` en `install.sh`: migración automática de variables nuevas del `.env`
- `/silence status` y `/silence off` *(movidos a v2.2.0 como funcionalidad completa)*

### Changed
- `telegram_notify()`: corregida precedencia `&&`/`||`
- `get_fritz_info()`: parámetro `update_uptime_state`
- `rotate_log()`: añadido `flock`
- `parse_updates()`: `gsub("\n"; "↵")` evita rotura por mensajes multi-línea
- `get_public_ip()`: backoff de 1s entre proveedores
- `load_env()`: regex `[^"]*` no greedy; comentarios inline preservados correctamente
- `telegram-bot.service`: `Restart=on-failure`
- `FAIL_MODE` validado con regex al arrancar

---

## [2.0.0] - 2026-02-01

### Added
- `/ping`, `/traceroute`, `/speedtest`, `/history`, `/restart wan|router|server`, `/schedule`, `/update`
- Historial de incidentes en JSON con rotación automática
- Informe diario automático
- Cola de notificaciones offline con `flock`
- Detección de arranque del bot (boot, manual, crash, update)
- Detección de reboot inesperado de Fritz y anomalías de IP
- `BOT_OFFSET_FILE` en `/var/lib` — persiste entre reboots
- Credenciales fuera de `ps` mediante ficheros config temporales `600`
- `set -uo pipefail` en todos los scripts principales

### Changed
- Arquitectura refactorizada en librería compartida (`url-watchdog-common.sh`)
- Eliminadas dependencias de Python y `bc`
- Separador `\x01` en `parse_updates`
- `rotate_log` solo al inicio de cada proceso

---

## [1.0.0] - 2026-01-01

### Added
- Monitorización de URLs con systemd timer (cada minuto)
- Flujo de recuperación en 4 fases
- Bot Telegram con comandos básicos
- Reconexión WAN vía TR-064; Reboot Fritz vía DeviceConfig:1
- Detección de cambio de IP pública
- Log circular con rotación
- Parseo seguro del `.env` sin `source`
