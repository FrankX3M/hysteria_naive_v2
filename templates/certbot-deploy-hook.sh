#!/usr/bin/env bash
# /etc/letsencrypt/renewal-hooks/deploy/proxy-sync-certs.sh
# Генерируется hysteria_naive (templates/certbot-deploy-hook.sh). Вызывается certbot после продления.
set -euo pipefail

LINEAGE="${RENEWED_LINEAGE:-/etc/letsencrypt/live/${SERVER_DOMAIN}}"
CERT_DIR="${CERT_DIR}"

install -m 640 -o root -g hysteria "${LINEAGE}/fullchain.pem" "${CERT_DIR}/fullchain.pem"
install -m 640 -o root -g hysteria "${LINEAGE}/privkey.pem"  "${CERT_DIR}/privkey.pem"

# Оба сервиса читают сертификат при старте → перезапуск неизбежен, но он происходит
# раз в ~60 дней, ночью, и это единственный рестарт, который не связан с администрированием.
systemctl restart hysteria-server
docker restart naiveproxy >/dev/null 2>&1 || true
logger -t proxy-sync-certs "certificates for ${SERVER_DOMAIN} renewed and deployed"
