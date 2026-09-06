#!/usr/bin/env bash
# lib/system.sh — системные зависимости, sysctl/BBR, swap.

install_deps() {
    log_step "Установка системных зависимостей"
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt-get install -y -qq \
        nftables curl wget ca-certificates openssl unzip gnupg jq \
        python3 python3-venv python3-pip dnsutils qrencode at \
        >> "$LOG_FILE" 2>&1
    [[ "$ENABLE_FAIL2BAN" == "yes" ]] && apt-get install -y -qq fail2ban >> "$LOG_FILE" 2>&1
    systemctl enable --now atd >> "$LOG_FILE" 2>&1 || true
    log_ok "Зависимости установлены"
}

configure_sysctl() {
    log_step "sysctl: BBR и сетевые буферы"
    render_template "sysctl-99-proxy.conf" | write_file /etc/sysctl.d/99-proxy-optimize.conf 644
    if sysctl -p /etc/sysctl.d/99-proxy-optimize.conf >> "$LOG_FILE" 2>&1; then
        log_ok "BBR включён: $(sysctl -n net.ipv4.tcp_congestion_control)"
    else
        log_warn "Часть sysctl-параметров не применилась (ядро без BBR?) — см. $LOG_FILE"
    fi
}

configure_swap() {
    local have_swap
    have_swap="$(swapon --show --noheadings 2>/dev/null | head -1)"
    case "$ENABLE_SWAP" in
        no)   log_info "Swap: пропущен по конфигурации"; return 0 ;;
        auto) [[ -n "$have_swap" ]] && { log_info "Swap уже есть (${have_swap%% *}) — не трогаю"; return 0; } ;;
        yes)  ;;
    esac
    log_step "Создание swap (${SWAP_SIZE_MB} МБ)"
    if swapon --show --noheadings 2>/dev/null | grep -q '^/swapfile'; then
        swapoff /swapfile && rm -f /swapfile
        sed -i '\#^/swapfile#d' /etc/fstab
        log_warn "Старый /swapfile пересоздан"
    fi
    fallocate -l "${SWAP_SIZE_MB}M" /swapfile 2>/dev/null \
        || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=none
    chmod 600 /swapfile
    mkswap /swapfile >> "$LOG_FILE"
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' | write_file /etc/sysctl.d/99-swappiness.conf 644
    sysctl -p /etc/sysctl.d/99-swappiness.conf >> "$LOG_FILE" 2>&1 || true
    log_ok "Swap создан: $(free -h | awk '/^Swap/{print $2}')"
}

check_memory() {
    # На VPS с 1 ГБ apt + docker pull запросто вызывают OOM и обрыв SSH.
    local free_mb
    free_mb="$(free -m | awk '/^Mem:/{print $7}')"
    if [[ -n "$free_mb" && "$free_mb" -lt 250 ]]; then
        log_warn "Свободной памяти ${free_mb} МБ. Рекомендуется запускать установку в tmux/screen"
        log_warn "и/или включить swap (ENABLE_SWAP=yes)."
    fi
}
