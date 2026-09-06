#!/usr/bin/env bash
# lib/certs.sh — TLS: проверка DNS, certbot, самоподписанный сертификат,
# единая копия сертификатов в ${CERT_DIR} и deploy-hook автопродления.
#
# Модель: исходный сертификат (Let's Encrypt / свой / самоподписанный) лежит там,
# где лежит; все сервисы читают КОПИЮ из /etc/proxy/certs (root:hysteria 640).
# Так hysteria работает от непривилегированного пользователя, а sing-box в контейнере
# видит тот же каталог через bind-mount. sync_certs() — единственная функция копирования,
# её же вызывает deploy-hook certbot.

check_dns() {
    # check_dns <domain> <expected_ip>
    local domain="$1" expected="$2" resolved
    resolved="$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' | tail -1 || true)"
    if [[ -z "$resolved" ]]; then
        log_warn "Домен ${domain} не резолвится. Нужна A-запись ${domain} → ${expected}"
        return 1
    fi
    if [[ "$resolved" != "$expected" ]]; then
        log_warn "Домен ${domain} указывает на ${resolved}, а не на ${expected}"
        return 1
    fi
    log_ok "DNS: ${domain} → ${resolved}"
}

install_certbot() {
    command -v certbot >/dev/null 2>&1 && return 0
    log_info "Устанавливаю certbot (apt)"
    if apt-get install -y -qq certbot >> "$LOG_FILE" 2>&1; then return 0; fi
    log_warn "apt не смог поставить certbot, пробую snap"
    if command -v snap >/dev/null 2>&1 && snap install --classic certbot >> "$LOG_FILE" 2>&1; then
        ln -sf /snap/bin/certbot /usr/local/bin/certbot
        return 0
    fi
    return 1
}

issue_letsencrypt() {
    # Выпуск через standalone на tcp/80. Файрвол (lib/firewall.sh) держит 80 открытым
    # именно ради этого и ради автопродления.
    local live="/etc/letsencrypt/live/${SERVER_DOMAIN}"
    if [[ -f "$live/fullchain.pem" && -f "$live/privkey.pem" ]]; then
        log_ok "Сертификат Let's Encrypt для ${SERVER_DOMAIN} уже есть"
    else
        install_certbot || die "certbot недоступен — используйте CERT_MODE=selfsigned или existing"
        check_dns "$SERVER_DOMAIN" "$SERVER_IP" || die "Исправьте DNS и повторите (или CERT_MODE=selfsigned)"
        if ss -tln 2>/dev/null | grep -q ':80 '; then
            log_warn "Порт 80 занят — certbot standalone может не сработать"
        fi
        log_info "certbot certonly --standalone -d ${SERVER_DOMAIN}"
        if certbot certonly --standalone --non-interactive --agree-tos \
            --register-unsafely-without-email -d "$SERVER_DOMAIN" >> "$LOG_FILE" 2>&1; then
            log_ok "Сертификат выпущен"
        elif [[ -f "$CERT_DIR/fullchain.pem" && -f "$CERT_DIR/privkey.pem" ]]; then
            # Сценарий restore: certbot не смог, но в бэкапе была копия сертификата — работаем на ней
            log_warn "certbot не смог выпустить сертификат (см. $LOG_FILE) — использую копию из ${CERT_DIR}"
            log_warn "Повторите позже: certbot certonly --standalone -d ${SERVER_DOMAIN} && systemctl restart hysteria-server"
            TLS_CERT="$CERT_DIR/fullchain.pem"; TLS_KEY="$CERT_DIR/privkey.pem"
            return 0
        else
            die "certbot завершился с ошибкой — см. $LOG_FILE и /var/log/letsencrypt/"
        fi
    fi
    TLS_CERT="$live/fullchain.pem"
    TLS_KEY="$live/privkey.pem"
}

issue_selfsigned() {
    local dir="/etc/proxy-selfsigned"
    mkdir -p "$dir"; chmod 700 "$dir"
    if [[ ! -f "$dir/fullchain.pem" ]]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -days 3650 -nodes \
            -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" \
            -subj "/CN=${SERVER_DOMAIN}" \
            -addext "subjectAltName=DNS:${SERVER_DOMAIN},IP:${SERVER_IP}" >> "$LOG_FILE" 2>&1
        chmod 600 "$dir/privkey.pem"
        log_warn "Самоподписанный сертификат создан. Клиентам потребуется insecure=1"
    fi
    TLS_CERT="$dir/fullchain.pem"
    TLS_KEY="$dir/privkey.pem"
}

resolve_certificates() {
    log_step "TLS-сертификат (режим: ${CERT_MODE})"
    case "$CERT_MODE" in
        letsencrypt) issue_letsencrypt ;;
        selfsigned)  issue_selfsigned ;;
        existing)
            [[ -f "$TLS_CERT" && -f "$TLS_KEY" ]] || die "CERT_MODE=existing, но файлы не найдены: $TLS_CERT / $TLS_KEY"
            log_ok "Использую существующий сертификат: $TLS_CERT" ;;
    esac
    sync_certs || true
    save_install_env   # TLS_CERT/TLS_KEY стали известны только сейчас
}

sync_certs() {
    # Копирует TLS_CERT/TLS_KEY в CERT_DIR, если они изменились. Возвращает 0 если обновил, 1 если нет.
    getent group hysteria >/dev/null 2>&1 || groupadd --system hysteria
    mkdir -p "$CERT_DIR"; chmod 750 "$CERT_DIR"; chgrp hysteria "$CERT_DIR"
    local changed=1
    for pair in "$TLS_CERT:fullchain.pem" "$TLS_KEY:privkey.pem"; do
        local src="${pair%%:*}" name="${pair##*:}"
        if ! cmp -s "$src" "$CERT_DIR/$name"; then
            install -m 640 -o root -g hysteria "$src" "$CERT_DIR/$name"
            changed=0
        fi
    done
    [[ $changed -eq 0 ]] && log_ok "Сертификаты синхронизированы в $CERT_DIR" || log "сертификаты в $CERT_DIR актуальны"
    return $changed
}

install_cert_hook() {
    [[ "$CERT_MODE" == "letsencrypt" ]] || { log_info "Хук автопродления нужен только для Let's Encrypt — пропущен"; return 0; }
    log_step "Хук автопродления сертификата"
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    render_template "certbot-deploy-hook.sh" | write_file /etc/letsencrypt/renewal-hooks/deploy/proxy-sync-certs.sh 755
    # Убираем старый хук из v2, если он остался
    rm -f /etc/letsencrypt/renewal-hooks/deploy/restart-proxy.sh
    log_ok "Хук: /etc/letsencrypt/renewal-hooks/deploy/proxy-sync-certs.sh"
}
