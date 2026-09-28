# Sicherung für die DTAdmin-Vorlage „Passwort-Tresor (Vaultwarden)“.
# Läuft als zweiter Container im Pod und sieht dasselbe Volume /data.
FROM alpine:3.22
RUN apk add --no-cache sqlite age tzdata \
 && mkdir -p /etc/crontabs
COPY bin/ /usr/local/bin/
RUN chmod 0755 /usr/local/bin/tresor-*
ENV TZ=Europe/Berlin DATA_DIR=/data
ENTRYPOINT ["/usr/local/bin/tresor-start"]
