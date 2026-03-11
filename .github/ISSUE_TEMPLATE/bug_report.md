---
name: Bug report
about: Algo no funciona como se describe
title: '[BUG] '
labels: bug
assignees: ''
---

## Descripción

Descripción clara y concisa del problema.

## Pasos para reproducir

1. ...
2. ...

## Comportamiento esperado

Qué debería ocurrir.

## Comportamiento real

Qué ocurre en cambio.

## Entorno

- OS: `cat /etc/os-release`
- Proxmox: `pveversion`
- Bash: `bash --version`
- jq: `jq --version`

## Log relevante

```
# tail -50 /var/log/url-watchdog.log
```

## Configuración (sin credenciales)

```bash
# cat /etc/url-watchdog/.env | grep -v PASSWORD | grep -v TOKEN
```
