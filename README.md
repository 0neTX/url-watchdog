# url-watchdog

Watchdog de conectividad para Proxmox con recuperación automática vía FritzBox y control remoto por Telegram.

Monitoriza una o varias URLs cada minuto. Si la conectividad falla de forma sostenida, actúa en cuatro fases ordenadas: espera, reconexión WAN forzada, reboot de la FritzBox y, como último recurso, reboot del servidor. Todo con notificaciones Telegram y un bot de control completo.

---

## Características

- **Monitorización continua** — comprueba N URLs cada minuto vía systemd timer, con latencia registrada en el log
- **Alerta de latencia alta** — notificación Telegram cuando una URL responde pero supera el umbral `LATENCY_WARN_MS`; se recupera sola al normalizarse
- **Recuperación en 4 fases** — espera configurable → verificación LAN+DNS → reconexión WAN TR-064 → reboot FritzBox → reboot servidor
- **Verificación de LAN antes de actuar** — distingue entre red local rota (gateway no responde), DNS caído y fallo de WAN; el watchdog solo actúa cuando la LAN está OK
- **Validación de configuración al arranque** — `validate_config()` verifica que todas las URLs tengan esquema `http(s)://` y que los enteros clave sean válidos antes de ejecutar nada
- **Tres modos de detección** — `all`, `any` o `quorum N/M` de URLs fallando
- **Alertas proactivas** — reboot inesperado de Fritz, anomalías de IP, inestabilidad parcial y certificados TLS próximos a expirar
- **Notificaciones Telegram** — con cola offline: mensajes encolados durante el fallo y reenviados al restaurarse
- **Bot de control remoto** — diagnóstico en red, estadísticas e informes
- **Informe diario y semanal** — el semanal incluye tendencia vs semana anterior
- **Sin dependencias externas** — solo `bash`, `curl`, `jq`, `awk`, `openssl` y `getent` (glibc)

---

## Requisitos

| Paquete | Uso |
|---|---|
| `curl` | Peticiones HTTP y API Telegram |
| `jq` | Parseo JSON (historial de incidentes, bot) |
| `openssl` | Comprobación de expiración de certificados TLS |
| `traceroute` | Comando `/traceroute` del bot (opcional) |

```bash
apt install curl jq openssl traceroute
```

La FritzBox debe tener habilitado el acceso UPnP/TR-064 en su configuración de red local.

---

## Estructura del repositorio

```
url-watchdog/
├── .env.example                 # Plantilla de configuración
│
├── ── Watchdog (bash) ───────────────────────────────────────────
├── url-watchdog-common.sh       # Librería compartida
├── url-watchdog.sh              # Watchdog principal (cron dentro del contenedor)
├── telegram-bot.sh              # Bot Telegram (long-polling)
├── url-watchdog-report.sh       # Informe diario (--daily) y semanal (--weekly)
│
├── ── Docker ────────────────────────────────────────────────────
├── Dockerfile                   # Imagen Alpine — watchdog + bot Telegram
├── docker-compose.yml           # Servicio url-watchdog
├── docker-entrypoint.sh         # Entrypoint: genera crontab, arranca crond + bot
├── install-docker.sh            # Script de primer arranque
│
├── ── Instalación nativa (alternativa) ──────────────────────────
├── install.sh                   # Instalación/actualización nativa con systemd
├── uninstall.sh                 # Desinstalación completa
├── url-watchdog.service         # Unit — watchdog (oneshot)
├── url-watchdog.timer           # Unit — timer cada minuto
├── url-watchdog-report.service  # Unit — informe diario (oneshot)
├── url-watchdog-report.timer    # Unit — timer diario
├── url-watchdog-weekly.service  # Unit — informe semanal (oneshot)
├── url-watchdog-weekly.timer    # Unit — timer semanal (lunes)
├── url-watchdog-boot.service    # Unit — notificación de arranque (oneshot)
├── telegram-bot.service         # Unit — bot Telegram (daemon)
├── url-watchdog-tmpfiles.conf   # tmpfiles.d — crea /run/url-watchdog en boot
│
├── SHA256SUMS                   # Checksums de integridad de scripts
├── CHANGELOG.md
├── CONTRIBUTING.md
└── LICENSE
```

---

## Instalación rápida — Docker

```bash
git clone https://github.com/0neTX/url-watchdog.git
cd url-watchdog
./install-docker.sh
```

El script copia `.env.example` a `.env`, abre el editor y arranca los contenedores.

### Configuración obligatoria

```bash
cp .env.example .env
nano .env
```

Variables mínimas a rellenar:

```bash
# Watchdog
URLS="https://google.com,https://1.1.1.1"
FRITZ_IP="192.168.178.1"
FRITZ_USER="admin"
FRITZ_PASSWORD="tu_password"
TELEGRAM_TOKEN="123456:ABC..."
TELEGRAM_CHAT_ID="987654321"
ALLOWED_CHAT_IDS="987654321"
```

Para habilitar el reboot del nodo vía Proxmox (fase 4 de recuperación):

```bash
PROXMOX_HOST="192.168.1.10"
PROXMOX_NODE="pve"
PROXMOX_TOKEN_ID="root@pam!watchdog"
PROXMOX_TOKEN_SECRET="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

El token necesita el permiso `Sys.PowerMgmt` en el nodo. Créalo en Proxmox → Datacenter → API Tokens.

### Arrancar

```bash
docker compose up -d
```

Los datos persisten en subdirectorios del proyecto:

```
./data/watchdog/   → incidents.json, telegram-bot.offset, watchdog.tls-check
./log/             → url-watchdog.log, url-watchdog-cron.log
```

### Mecanismo de reboot

```
Watchdog agota fases → request_host_reboot()
  └─ curl HTTPS → Proxmox API /nodes/{node}/status  command=reboot
       └─ Proxmox reinicia el nodo (y el contenedor con él)
```

El contenedor **no necesita privilegios especiales** (`cap_drop: ALL`, solo `NET_RAW` para ping).

### Comandos útiles

```bash
docker compose ps                            # Estado del contenedor
docker compose logs -f url-watchdog          # Logs watchdog + bot Telegram
tail -f log/url-watchdog.log                 # Log del watchdog en tiempo real
docker compose down && docker compose up -d  # Reiniciar todo
```

### Desinstalación

```bash
docker compose down
rm -rf data log .env
```

---

## Instalación nativa (systemd)

Para instalación directa en el host sin Docker:

```bash
sudo ./install.sh
sudo /usr/local/bin/url-watchdog.sh --test
```

La configuración se instala en `/etc/url-watchdog/.env`.

---

## Flujo de recuperación

```
URLs fallan durante MAX_FAIL_MINUTES
  └─ Verificar LAN (ip route + ping gateway + getent DNS)
      ├─ Gateway no responde → alerta "LAN local rota", NO actuar sobre Fritz
      ├─ DNS no responde   → alerta "DNS caído", NO actuar sobre Fritz
      └─ LAN + DNS OK
          └─ Reconexión WAN forzada (ForceTermination + RequestConnection)
              ├─ Fritz no accesible → reboot Fritz directo
              └─ FRITZ_WAN_WAIT_MINUTES (default: 2 min)
                  ├─ ✅ Restaurado → "🔌 reconexión WAN forzada"
                  └─ Sigue fallando → Reboot Fritz completo
                      └─ FRITZ_WAIT_MINUTES (default: 10 min)
                          ├─ ✅ Restaurado → "🔄 reconexión WAN + reboot Fritz"
                          └─ Sigue fallando → /sbin/reboot
```

---

## Bot Telegram — comandos

### Consulta

| Comando | Descripción |
|---|---|
| `/status` | Estado actual: fase, IP, fallos parciales del día, silencio |
| `/fritz` | Modelo, uptime y estado WAN de la FritzBox |
| `/ip` | IP pública actual |
| `/log [n\|tail]` | Últimas N líneas; `tail` envía actualizaciones en +30s y +60s |
| `/schedule` | Última y próxima ejecución del watchdog |
| `/history [n\|--failed]` | Últimos N incidentes; `--failed` filtra solo los que tuvieron acciones |
| `/stats [days]` | Estadísticas e incidentes del período con tendencia (default: 30 días) |
| `/version` | Versiones instaladas de todos los scripts |

### Diagnóstico

| Comando | Descripción |
|---|---|
| `/ping [url]` | Sin URL: comprueba todas las monitorizadas con latencia. Con URL: una concreta |
| `/traceroute [host]` | Traza la ruta hasta un host (default: `1.1.1.1`) |
| `/speedtest` | Test de velocidad de descarga desde CDNs públicos |
| `/diagnose` | Diagnóstico completo: LAN/GW, DNS, Fritz, URLs con latencia, TLS, log |

### Acciones

| Comando | Descripción |
|---|---|
| `/reset` | Limpia el estado de fallo activo (LAN, watchmode y alertas de latencia) |
| `/silence [min]` | Silencia notificaciones N minutos (default: 30, max: 1440) |
| `/silence status` | Muestra tiempo restante de silencio |
| `/silence off` | Desactiva el silencio activo |
| `/restart wan` | Reconexión WAN forzada + informe en `FRITZ_WAN_WAIT_MINUTES` min |
| `/restart router` | Reboot completo de la FritzBox + informe en `FRITZ_WAIT_MINUTES` min |
| `/restart server` | Reboot del servidor (requiere `/confirm`) |
| `/reboot_fritz` | Reboot Fritz sin informe posterior |
| `/reboot_server` | Reboot del servidor (requiere `/confirm`) |
| `/confirm` | Confirma la operación peligrosa pendiente |

---

## Ficheros en tiempo de ejecución

### Volátiles — `/run/url-watchdog/` (700 root:root, tmpfs)

| Fichero | Contenido |
|---|---|
| `watchdog.fail` | Timestamp del primer fallo detectado |
| `watchdog.wan` | Timestamp de la reconexión WAN forzada |
| `watchdog.fritz` | Timestamp del reboot de la FritzBox |
| `watchdog.lan-fail` | Timestamp de detección de LAN rota (evita alerta repetida) |
| `watchdog.ip` | IP pública actual |
| `watchdog.ip-changes` | Contador diario de cambios de IP (`YYYY-MM-DD\|N`) |
| `watchdog.fritz-uptime` | Último uptime Fritz conocido (`secs\|epoch`) |
| `watchdog.silence` | Timestamp fin del modo silencio |
| `watchdog.confirm` | Operación pendiente de confirmación |
| `watchdog.notify-queue` | Cola de notificaciones (base64, una por línea) |
| `watchdog.partial-fail` | Contador diario de ciclos con fallos parciales |
| `watchdog.tls-check` | Fecha de última comprobación TLS (`YYYY-MM-DD`) |
| `watchdog.watchmode` | Presencia = modo vigilancia activo (comprobación minutely) |
| `watchdog.lastrun` | Timestamp de la última ejecución real del watchdog |
| `watchdog.latency-warn_<hash>` | Un fichero por URL con latencia alta activa (hash SHA256 de la URL) |
| `telegram-bot.pid` | PID del proceso del bot |
| `telegram-bot.start-reason` | Motivo del último arranque del bot |

### Persistentes — `/var/lib/url-watchdog/`

| Fichero | Contenido |
|---|---|
| `incidents.json` | Historial de incidentes con rotación automática |
| `watchdog.tls-check` | Fecha de última comprobación TLS () — persiste entre reboots |
| `telegram-bot.offset` | Offset Telegram — evita reprocesar mensajes tras reboot |

---

## Configuración — todas las variables

| Variable | Default | Descripción |
|---|---|---|
| `URLS` | — | URLs a monitorizar, separadas por comas |
| `WATCHDOG_INTERVAL_MINUTES` | `5` | Minutos entre comprobaciones en modo normal. En modo vigilancia (fallo activo) siempre se comprueba cada minuto |
| `FAIL_MODE` | `all` | `all` / `any` / `quorum` |
| `FAIL_QUORUM` | `2` | URLs que deben fallar para actuar (solo si `FAIL_MODE=quorum`) |
| `MAX_FAIL_MINUTES` | `10` | Minutos de fallo sostenido antes de actuar |
| `HTTP_TIMEOUT` | `10` | Timeout por petición HTTP en segundos |
| `INSTABILITY_THRESHOLD` | `3` | Ciclos parciales antes de alertar (modo `all`/`quorum`) |
| `LATENCY_WARN_MS` | `0` | Latencia (ms) a partir de la cual alertar aunque la URL responda. `0` = deshabilitado |
| `ESCALATE_MINUTES` | `15,60` | Minutos de corte activo tras los que se envía una alerta de escalada (lista separada por comas; cada umbral se notifica una sola vez) |
| `FRITZ_IP` | `192.168.178.1` | IP local de la FritzBox |
| `FRITZ_USER` | — | Usuario TR-064 |
| `FRITZ_PASSWORD` | — | Contraseña TR-064 |
| `FRITZ_WAN_WAIT_MINUTES` | `2` | Espera tras reconexión WAN antes de verificar |
| `FRITZ_WAIT_MINUTES` | `10` | Espera tras reboot Fritz antes de reboot servidor |
| `FRITZ_REBOOT_CHECK_INTERVAL` | `300` | Segundos entre comprobaciones de reboot inesperado Fritz |
| `CERT_EXPIRY_WARN_DAYS` | `14` | Días antes de la expiración TLS para alertar (0 = desactivar) |
| `TELEGRAM_TOKEN` | — | Token del bot (de @BotFather) |
| `TELEGRAM_CHAT_ID` | — | Chat ID principal para alertas del watchdog |
| `ALLOWED_CHAT_IDS` | — | Chat IDs autorizados para el bot, separados por comas |
| `TELEGRAM_MAX_RETRIES` | `3` | Reintentos de envío ante fallo de la API |
| `TELEGRAM_RETRY_DELAY` | `5` | Segundos entre reintentos |
| `BOT_POLL_TIMEOUT` | `30` | Timeout del long-polling en segundos |
| `CONFIRM_TIMEOUT` | `30` | Segundos para confirmar operaciones peligrosas |
| `LOG_FILE` | `/var/log/url-watchdog.log` | Ruta del log |
| `LOG_MAX_BYTES` | `524288` | Tamaño máximo del log antes de rotar (512 KB) |
| `LOG_DEFAULT_LINES` | `20` | Líneas mostradas por defecto con `/log` |
| `DAILY_REPORT_TIME` | `08:00` | Hora del informe diario y semanal (HH:MM) |
| `IP_CHANGE_ALERT_THRESHOLD` | `3` | Cambios de IP diarios antes de alertar |
| `TRACEROUTE_DEFAULT_HOST` | `1.1.1.1` | Host por defecto para `/traceroute` |
| `SPEEDTEST_URLS` | *(3 CDNs)* | URLs para el test de velocidad, separadas por comas |
| `INCIDENTS_FILE` | `/var/lib/url-watchdog/incidents.json` | Ruta del historial JSON |
| `INCIDENTS_MAX_ENTRIES` | `500` | Máximo de incidentes antes de rotar el JSON |
| `HISTORY_DEFAULT_N` | `5` | Incidentes mostrados por defecto con `/history` |
| `PROXMOX_HOST` | *(vacío)* | IP o hostname de la API Proxmox (ej. `192.168.1.10`). Vacío = usa `/sbin/reboot` directo |
| `PROXMOX_NODE` | *(vacío)* | Nombre del nodo Proxmox (ej. `pve`) |
| `PROXMOX_TOKEN_ID` | *(vacío)* | ID del API token (formato `usuario@realm!nombre`, ej. `root@pam!watchdog`) |
| `PROXMOX_TOKEN_SECRET` | *(vacío)* | Secret del API token (UUID generado por Proxmox) |

---

## Seguridad

| Medida | Descripción |
|---|---|
| Credenciales fuera de `ps` | Token y contraseñas pasan a `curl` via ficheros temporales `600` en `STATE_DIR` |
| `.env` con permisos `600` | Solo `root` puede leer la configuración |
| Parseo seguro del `.env` | Sin `source`; lista negra de variables privilegiadas del shell |
| Autenticación del bot | Mensajes de `chat_id` no autorizado se ignoran y se loguean |
| Confirmación de operaciones destructivas | `/restart server` y `/reboot_server` requieren `/confirm` |
| Escrituras atómicas | `tmp + mv` en todos los ficheros de estado |
| `STATE_DIR` protegido | `700 root:root`; `tmpfiles.d` garantiza permisos en cada boot |

---

## Diagnóstico y resolución de problemas

### El bot no responde

```bash
systemctl status telegram-bot.service
journalctl -u telegram-bot.service -n 50
```

### No llegan alertas de Telegram

```bash
sudo /usr/local/bin/url-watchdog.sh --test
tail -50 /var/log/url-watchdog.log
```

### La FritzBox no responde a TR-064

```bash
curl -v "http://192.168.178.1:49000/upnp/control/deviceinfo"
```

### El watchdog no actúa pese a que Internet falla

`check_local_network()` evalúa tres capas antes de actuar sobre la Fritz:

1. **Gateway** — `ip route` + `ping`. Si falla: `[LAN] Gateway X no responde al ping.`
2. **DNS** — `getent hosts example.com`. Si falla: `[LAN] ⚠️  DNS no responde`
3. **WAN** — si LAN+DNS están OK, se ejecutan las fases de recuperación normales

Si el log muestra alguno de los mensajes anteriores, el watchdog NO actuará sobre la Fritz hasta que esa capa se recupere. Usa `/diagnose` para ver el estado de cada capa en tiempo real.

### Ver estado de todos los servicios

```bash
# Docker
docker compose ps
docker compose logs -f url-watchdog

# Instalación nativa
systemctl status url-watchdog.timer url-watchdog-report.timer url-watchdog-weekly.timer telegram-bot.service
```

---

## Licencia

MIT — ver [LICENSE](LICENSE)
