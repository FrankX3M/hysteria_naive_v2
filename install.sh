#!/usr/bin/env bash
# install.sh — установщик Hysteria2 + NaiveProxy (sing-box) + port hopping + Telegram-бот.
# Точка входа: только разбор аргументов, сбор параметров и оркестрация шагов из lib/.
#
# Режимы:
#   sudo ./install.sh                         интерактивно (ответы сохраняются в /etc/proxy/install.env)
#   sudo ./install.sh --config my.env         неинтерактивно из файла (см. install.env.example)
#   sudo ./install.sh --upgrade               обновить бинарники/скрипты/юниты, НЕ трогая пользователей и секреты
#   sudo ./install.sh --config /etc/proxy/install.env --from-step firewall   продолжить с шага
#   sudo ./install.sh --list-steps
#
# Идемпотентность: повторный запуск на настроенном сервере без --upgrade/--reinstall
# останавливается, чтобы не перегенерировать пароли и не потерять пользователей (п.27).

set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR
for f in common versions system certs hysteria naiveproxy firewall fail2ban proxy_tools output; do
    # shellcheck source=/dev/null
    source "${REPO_DIR}/lib/${f}.sh"
done

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

VERSION="3.0.0"
CONFIG_FILE=""
MODE="install"          # install | upgrade | reinstall
FROM_STEP=""
NONINTERACTIVE=0

STEPS=(
    deps        install_deps
    sysctl      configure_sysctl
    swap        configure_swap
    certs       resolve_certificates
    hysteria    "install_hysteria; configure_hysteria"
    docker      "install_docker; configure_naiveproxy"
    tools       "install_python_tools; init_state"
    firewall    configure_firewall
    fail2ban    configure_fail2ban
    certhook    install_cert_hook
    services    install_services
    apply       apply_proxy_configs
    maintenance install_maintenance
    output      print_summary
)

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

list_steps() { for ((i = 0; i < ${#STEPS[@]}; i += 2)); do echo "${STEPS[i]}"; done; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)     CONFIG_FILE="$2"; NONINTERACTIVE=1; shift 2 ;;
        --upgrade)    MODE="upgrade"; NONINTERACTIVE=1; shift ;;
        --reinstall)  MODE="reinstall"; shift ;;
        --from-step)  FROM_STEP="$2"; NONINTERACTIVE=1; shift 2 ;;
        --list-steps) list_steps ;;
        --version)    echo "hysteria_naive installer ${VERSION}"; exit 0 ;;
        -h|--help)    usage ;;
        *) die "Неизвестный аргумент: $1 (см. --help)" ;;
    esac
done

# ── Интерактивный сбор параметров: только заполняет те же переменные, что и --config ──
ask() { # ask <переменная> <вопрос> [default]
    local var="$1" q="$2" def="${3:-}" ans
    if [[ -n "$def" ]]; then read -r -p "${q} [${def}]: " ans; else read -r -p "${q}: " ans; fi
    printf -v "$var" '%s' "${ans:-$def}"
}

collect_interactive() {
    echo "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║        hysteria_naive v${VERSION} — Hysteria2 + NaiveProxy       ║"
    echo "╚══════════════════════════════════════════════════════════╝${NC}"
    echo "${YELLOW}${BOLD}Шаг 1/4 — Сервер${NC}"
    ask SERVER_DOMAIN "Домен сервера (например proxy.example.com)"
    ask SERVER_IP     "IPv4 адрес сервера (Enter = определить)" "$(detect_public_ip)"
    echo "Сертификат: 1) Let's Encrypt (нужен открытый tcp/80 и DNS → этот IP)  2) самоподписанный  3) существующий"
    local cert_choice
    ask cert_choice "Выбор" 1
    case "$cert_choice" in 2) CERT_MODE=selfsigned ;; 3) CERT_MODE=existing; ask TLS_CERT "Путь к fullchain.pem"; ask TLS_KEY "Путь к privkey.pem" ;; *) CERT_MODE=letsencrypt ;; esac
    ask MAIN_PORT "Основной порт" 443
    ask HOP_START "Начало диапазона port hopping" 20000
    ask HOP_END   "Конец диапазона port hopping" 50000
    ask SSH_PORT  "SSH-порт (определён автоматически)" "$(detect_ssh_port)"
    echo; echo "${YELLOW}${BOLD}Шаг 2/4 — Первый пользователь${NC}"
    ask FIRST_USER "Имя (a-z, 0-9, _, -)" admin
    echo; echo "${YELLOW}${BOLD}Шаг 3/4 — Telegram (опционально)${NC}"
    ask TG_TOKEN "Bot Token (Enter = пропустить)"
    if [[ -n "$TG_TOKEN" ]]; then
        ask TG_CHAT_ID  "Chat ID для уведомлений (личный или группа)"
        ask TG_ADMIN_IDS "User ID администраторов через запятую" "$TG_CHAT_ID"
    fi
    echo; echo "${YELLOW}${BOLD}Шаг 4/4 — Система${NC}"
    ask ENABLE_SWAP "Swap: auto (создать, если нет) / yes / no" auto
    ask SWAP_SIZE_MB "Размер swap, МБ" 512
    ask ENABLE_FAIL2BAN "Fail2ban (yes/no)" yes
    ask ENABLE_CLEANUP_TIMER "Ежедневная очистка диска (yes/no)" yes
    ask BACKUP_PASSPHRASE "Пароль шифрования бэкапов (Enter = сгенерировать)" ""
}

confirm_params() {
    echo
    echo "${GREEN}${BOLD}Параметры установки:${NC}"
    printf '  %-18s %s\n' "Домен:" "$SERVER_DOMAIN" "IP:" "$SERVER_IP" "Сертификат:" "$CERT_MODE" \
        "Порт:" "$MAIN_PORT" "Hopping:" "${HOP_START}-${HOP_END}" "SSH:" "$SSH_PORT" \
        "Пользователь:" "$FIRST_USER" "Hysteria:" "$HYSTERIA_VERSION" "sing-box:" "$SINGBOX_IMAGE" \
        "Telegram:" "$([[ -n "$TG_TOKEN" ]] && echo "да (админы: $TG_ADMIN_IDS)" || echo нет)" \
        "Obfs:" "$HY2_OBFS" "Swap:" "$ENABLE_SWAP" "Fail2ban:" "$ENABLE_FAIL2BAN"
    echo "  Секреты и состояние → ${STATE_DIR}/ ; лог → ${LOG_FILE}"
    if [[ $NONINTERACTIVE -eq 0 ]]; then
        read -r -p "Продолжить? [Y/n]: " c; [[ "$c" =~ ^[Nn]$ ]] && exit 0
    fi
    return 0
}

main() {
    require_root
    mkdir -p "$LOG_DIR"; chmod 750 "$LOG_DIR"
    log "===== install.sh ${VERSION} mode=${MODE} $(date -Is) ====="
    check_memory

    if [[ -f "$INSTALL_ENV" ]]; then
        load_env_file "$INSTALL_ENV"
        load_env_file "$SECRETS_ENV" || true
        if [[ "$MODE" == "install" && -z "$FROM_STEP" ]]; then
            log_warn "Сервер уже настроен ($INSTALL_ENV, $(date -d "${INSTALLED_AT:-@0}" +%F 2>/dev/null))."
            log_warn "Повторная установка перегенерирует пароли и удалит пользователей."
            die "Используйте --upgrade (сохранить данные) или --reinstall (начать заново)."
        fi
    fi

    if [[ -n "$CONFIG_FILE" ]]; then
        load_env_file "$CONFIG_FILE" || die "Файл конфигурации не найден: $CONFIG_FILE"
    elif [[ "$MODE" != "upgrade" && -z "$FROM_STEP" ]]; then
        collect_interactive
    fi
    apply_defaults
    # При --upgrade версии берём из lib/versions.sh, а не из старого install.env
    [[ "$MODE" == "upgrade" ]] && SINGBOX_IMAGE="ghcr.io/sagernet/sing-box:${SINGBOX_VERSION}"
    [[ -z "$SERVER_IP" ]] && SERVER_IP="$(detect_public_ip)"
    [[ -z "$SERVER_IP" ]] && die "Не удалось определить публичный IP — задайте SERVER_IP"
    [[ -z "$BACKUP_PASSPHRASE" ]] && BACKUP_PASSPHRASE="$(gen_pass 40)"
    [[ -z "$HY2_STATS_SECRET" ]] && HY2_STATS_SECRET="$(gen_pass 32)"
    [[ -n "$TG_TOKEN" && -z "$TG_ADMIN_IDS" ]] && TG_ADMIN_IDS="$TG_CHAT_ID"
    validate_params
    [[ "$MODE" == "upgrade" ]] || confirm_params

    ensure_service_user
    if [[ "$MODE" == "reinstall" && -f "$USERS_JSON" ]]; then
        backup_existing "$USERS_JSON"; rm -f "$USERS_JSON"
        log_warn "--reinstall: старый users.json перенесён в ${SAFETY_DIR}"
    fi
    # Файл состояния пишем ДО шагов: при падении --from-step сможет продолжить с теми же параметрами
    save_install_env
    save_secrets_env
    log_ok "Параметры сохранены: ${INSTALL_ENV}, секреты: ${SECRETS_ENV}"

    local started=0
    [[ -z "$FROM_STEP" ]] && started=1
    for ((i = 0; i < ${#STEPS[@]}; i += 2)); do
        local name="${STEPS[i]}" cmd="${STEPS[i+1]}"
        [[ "$name" == "$FROM_STEP" ]] && started=1
        [[ $started -eq 1 ]] || { log "пропуск шага ${name} (--from-step ${FROM_STEP})"; continue; }
        run_step "$name" eval "$cmd"
    done
    echo "${GREEN}${BOLD}Готово. Копии заменённых файлов: ${SAFETY_DIR}${NC}"
}

main "$@"
