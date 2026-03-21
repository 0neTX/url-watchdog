FROM alpine:3.21

# Dependencias exactas que usan los scripts bash
# gcompat: provee getent (los scripts usan `getent hosts` para DNS); musl no lo incluye por defecto
# cronie:  cron con soporte de /etc/cron.d/ (binario: crond)
RUN apk add --no-cache \
      bash \
      curl \
      jq \
      openssl \
      traceroute \
      iproute2 \
      iputils \
      cronie \
      tini \
      ca-certificates \
      gcompat

# Copiar scripts exactamente donde los buscan
COPY url-watchdog-common.sh   /usr/local/bin/url-watchdog-common.sh
COPY url-watchdog.sh          /usr/local/bin/url-watchdog.sh
COPY telegram-bot.sh          /usr/local/bin/telegram-bot.sh
COPY url-watchdog-report.sh   /usr/local/bin/url-watchdog-report.sh
RUN chmod +x \
      /usr/local/bin/url-watchdog-common.sh \
      /usr/local/bin/url-watchdog.sh \
      /usr/local/bin/telegram-bot.sh \
      /usr/local/bin/url-watchdog-report.sh

# Directorios de estado (los scripts los crean con mkdir -p, pero pre-crearlos es más limpio)
RUN mkdir -p \
      /etc/url-watchdog \
      /var/lib/url-watchdog \
      /var/log \
      /run/url-watchdog \
  && chmod 700 /run/url-watchdog

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# tini como PID 1: recoge correctamente los procesos zombie generados por los subshells bash
ENTRYPOINT ["/sbin/tini", "--", "/docker-entrypoint.sh"]
