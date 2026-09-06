#!/usr/bin/env bash
# lib/fail2ban.sh — Fail2ban для sshd и для неудачных аутентификаций Hysteria2.
#
# Источник событий для jail [hysteria2] — НЕ логи самого hysteria (их формат мы не
# контролируем), а журнал proxy-authd: с auth.type=http каждая неудачная попытка
# проходит через наш сервис, который пишет строку `auth failed ip=<ip> ...` (п.21).
# Бан — banaction nftables[type=allports]: правило по IP на всех портах, поэтому
# NAT-редирект hopping-диапазона ему не мешает.

configure_fail2ban() {
    [[ "$ENABLE_FAIL2BAN" == "yes" ]] || { log_info "Fail2ban отключён (ENABLE_FAIL2BAN=no)"; return 0; }
    log_step "Fail2ban"
    render_template "fail2ban/jail.local" | write_file /etc/fail2ban/jail.local 644
    render_template "fail2ban/filter-hysteria2.conf" | write_file /etc/fail2ban/filter.d/hysteria2.conf 644
    systemctl enable fail2ban >> "$LOG_FILE" 2>&1
    systemctl restart fail2ban
    if wait_active fail2ban 5; then
        log_ok "Fail2ban запущен: $(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | xargs)"
    else
        log_warn "Fail2ban не запустился: journalctl -xeu fail2ban"
    fi
}

verify_fail2ban_filter() {
    # Приёмочный тест регулярки на живом журнале (можно вызывать после первой неудачной попытки входа)
    command -v fail2ban-regex >/dev/null 2>&1 || return 0
    fail2ban-regex systemd-journal /etc/fail2ban/filter.d/hysteria2.conf 2>/dev/null | grep -E '^Lines: ' || true
}
