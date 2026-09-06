#!/usr/bin/env bash
# lib/firewall.sh — nftables: своя таблица inet proxy, policy drop, безопасное применение.
#
# Почему не `systemctl restart nftables`: у Debian'овского nftables.service
# ExecStop = `nft flush ruleset`, то есть рестарт сервиса сносит таблицы Fail2ban и Docker.
# Мы применяем только свой файл через `nft -f` (внутри него `flush table inet proxy`),
# а nftables.service оставляем включённым лишь для загрузки правил при boot.

render_firewall() {
    log_step "nftables: таблица inet proxy (policy drop, hopping ${HOP_START}-${HOP_END} → ${MAIN_PORT})"
    mkdir -p "$NFT_DIR"
    render_template "nftables-proxy.nft" | write_file "$NFT_FILE" 644

    # /etc/nftables.conf: подключаем каталог с нашими файлами, не трогая чужие таблицы.
    if [[ ! -f /etc/nftables.conf ]] || ! grep -q "nftables.d/\*.nft" /etc/nftables.conf; then
        write_file /etc/nftables.conf 755 <<'EOF'
#!/usr/sbin/nft -f
# Управляется hysteria_naive. Собственные таблицы лежат в /etc/nftables.d/*.nft
# Здесь намеренно НЕТ `flush ruleset` — иначе при загрузке/рестарте сносятся
# таблицы Fail2ban и Docker.
include "/etc/nftables.d/*.nft"
EOF
        log_ok "/etc/nftables.conf переписан (include /etc/nftables.d/*.nft)"
    fi
    nft -c -f "$NFT_FILE" || die "Синтаксическая ошибка в ${NFT_FILE}"
    log_ok "Правила проверены (nft -c)"
}

apply_firewall_safely() {
    # Страховка от самоблокировки: через 3 минуты таблица удалится сама, если мы
    # не подтвердим, что SSH жив (скрипт дошёл до atrm). При обрыве SSH — просто ждите.
    log_step "Применение nftables со страховкой"
    local job=""
    if command -v at >/dev/null 2>&1; then
        systemctl enable --now atd >> "$LOG_FILE" 2>&1 || true
        if echo "nft delete table inet proxy" | at now + 3 minutes > /tmp/proxy-at.log 2>&1; then
            job="$(atq | sort -n | tail -1 | awk '{print $1}')"
            log_info "Автооткат: job #${job} удалит таблицу через 3 минуты, если применение сорвётся"
        fi
    else
        log_warn "Пакет 'at' недоступен — автооткат nftables отключён"
    fi

    nft -f "$NFT_FILE" || { log_err "nft -f не применился"; return 1; }
    systemctl enable nftables >> "$LOG_FILE" 2>&1 || true

    # Проверяем, что порт SSH действительно разрешён в живом наборе правил
    if nft list chain inet proxy input 2>/dev/null | grep -q "tcp dport ${SSH_PORT} accept"; then
        [[ -n "$job" ]] && atrm "$job" 2>/dev/null && log_ok "Автооткат отменён — правила применены штатно"
        log_ok "nftables применён: $(nft list chain inet proxy input | grep -c accept) accept-правил, policy drop"
    else
        log_err "В активных правилах нет accept для SSH-порта ${SSH_PORT} — оставляю автооткат (job #${job})"
        return 1
    fi
}

configure_firewall() {
    render_firewall
    apply_firewall_safely
}
