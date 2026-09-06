#!/usr/bin/env bash
# lib/hysteria.sh — установка бинарника Hysteria2 (пин версии + опциональный sha256)
# и systemd-юнит от непривилегированного пользователя hysteria.
#
# Сам /etc/hysteria/config.yaml НЕ пишется здесь: его рендерит `proxy-admin apply`
# из install.env/secrets.env/users.json (единый источник правды, см. tools/proxy_admin.py).

install_hysteria() {
    log_step "Hysteria2 ${HYSTERIA_VERSION}"
    local arch bin="/usr/local/bin/hysteria" current=""
    arch="$(detect_arch)"
    if [[ -x "$bin" ]]; then
        current="$("$bin" version 2>/dev/null | awk '/^Version:/{print $2}')"
    fi
    if [[ "$current" == "$HYSTERIA_VERSION" ]]; then
        log_ok "Hysteria2 ${current} уже установлена"
    else
        local url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/hysteria-linux-${arch}"
        local tmp; tmp="$(mktemp)"
        log_info "Скачиваю ${url}"
        curl -fsSL --retry 3 -o "$tmp" "$url" || die "Не удалось скачать Hysteria2"
        local want_var="HYSTERIA_SHA256_${arch}"
        local want="${!want_var:-}"
        if [[ -n "$want" ]]; then
            local got; got="$(sha256sum "$tmp" | awk '{print $1}')"
            [[ "$got" == "$want" ]] || die "sha256 hysteria не совпал: ожидали $want, получили $got"
            log_ok "sha256 бинарника проверен"
        else
            log_warn "HYSTERIA_SHA256_${arch} не задан в lib/versions.sh — контрольная сумма не проверена"
        fi
        install -m 755 -o root -g root "$tmp" "$bin"; rm -f "$tmp"
        log_ok "Hysteria2 установлена: $("$bin" version | awk '/^Version:/{print $2}') (было: ${current:-нет})"
    fi

    # Пользователь и группа сервиса (как у официального установщика)
    getent group hysteria >/dev/null 2>&1 || groupadd --system hysteria
    id -u hysteria >/dev/null 2>&1 || useradd --system --gid hysteria --home-dir /var/lib/hysteria \
        --create-home --shell /usr/sbin/nologin hysteria
    mkdir -p /etc/hysteria /var/lib/hysteria
    chmod 750 /etc/hysteria; chgrp hysteria /etc/hysteria
    chown hysteria:hysteria /var/lib/hysteria
}

configure_hysteria() {
    log_step "Юнит hysteria-server (User=hysteria, hardening)"
    systemd_unit_from_template "hysteria-server.service" "hysteria-server.service"
    # Старый юнит v2 перезаписывал официальный без User= — drop-in'ов быть не должно
    rm -rf /etc/systemd/system/hysteria-server.service.d
    systemctl daemon-reload
    systemctl enable hysteria-server >> "$LOG_FILE" 2>&1
    log_ok "Юнит установлен; конфиг будет сгенерирован proxy-admin"
}

start_hysteria() {
    systemctl restart hysteria-server
    if wait_active hysteria-server 10; then
        log_ok "Hysteria2 запущена"
    else
        log_err "Hysteria2 не запустилась: journalctl -xeu hysteria-server"
        return 1
    fi
}
