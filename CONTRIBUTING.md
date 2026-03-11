# Contribuciones

## Antes de abrir un issue

- Revisa los issues abiertos para evitar duplicados
- Incluye la versión instalada (comando `/version` en el bot, o `grep VERSION /usr/local/bin/url-watchdog.sh`)
- Incluye la versión del sistema (`cat /etc/os-release`)
- Para bugs, adjunta las líneas relevantes del log (`tail -100 /var/log/url-watchdog.log`)
- Para bugs del bot, adjunta las líneas con `[BOT]`

## Pull Requests

1. Haz fork del repositorio y crea una rama descriptiva (`fix/fritz-auth`, `feat/vm-monitor`)
2. Mantén la compatibilidad con bash 4.4+ y Debian/Proxmox sin dependencias más allá de `curl`, `jq` y `awk`
3. No uses `python3`, `bc`, `perl` ni otras herramientas no estándar en Proxmox/Debian
4. Verifica la sintaxis con `bash -n script.sh` y `shellcheck script.sh` antes de enviar
5. Actualiza `CHANGELOG.md` en la sección `[Unreleased]`
6. Si añades variables nuevas al `.env`, añádelas también a `url-watchdog.env` (plantilla) y a la tabla del README
7. Regenera `SHA256SUMS` si modificas algún script: `sha256sum url-watchdog-*.sh telegram-bot.sh > SHA256SUMS`
8. Un PR por funcionalidad o fix

## Estilo de código

- Indentación con 2 espacios, sin tabs
- Variables locales siempre declaradas con `local`
- Funciones con nombre en `snake_case`; funciones internas con prefijo `_`
- Prefijo de log entre corchetes: `[FRITZ]`, `[BOT]`, `[IP]`, `[QUEUE]`, etc.
- Los mensajes de Telegram usan Markdown (no HTML)
- Escrituras de ficheros de estado siempre con `_write_state()` (atómica)
- Lecturas de timestamps siempre con `_read_state_ts()` (validada)
- Nuevas variables de entorno requeridas deben añadirse a la lista de `require_vars` del script correspondiente

## Estructura de funciones

Las funciones de la librería compartida (`url-watchdog-common.sh`) deben:

- Ser agnósticas al script que las llama (watchdog, bot o report)
- Documentar si leen o escriben ficheros de estado
- No asumir que `STATE_DIR` existe — usar `mkdir -p` o `_mktemp_secure()`

## Tests manuales

Antes de enviar un PR que modifique el flujo de recuperación o el bot:

```bash
# Verificar sintaxis de todos los scripts
for f in url-watchdog-*.sh telegram-bot.sh install.sh; do
  bash -n "$f" && echo "OK: $f" || echo "ERROR: $f"
done

# Regenerar checksums
sha256sum url-watchdog-*.sh telegram-bot.sh > SHA256SUMS

# Prueba de notificación y Fritz
sudo /usr/local/bin/url-watchdog.sh --test
```
