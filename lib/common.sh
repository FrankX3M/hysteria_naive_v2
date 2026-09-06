#!/usr/bin/env bash
# lib/common.sh — общие функции для install.sh / restore.sh.
# Подключается через `source`, сам по себе не запускается.
#
# Здесь: логирование, работа с файлом состояния (/etc/proxy/install.env),
# атомарная запись файлов с правами, безопасный бэкап перед перезаписью,
# рендер шаблонов и мелкие утилиты (gen_pass, detect_ssh_port, ...).

# shellcheck disable=SC2034  # переменные используются в других lib/*.sh
[[ -n "${__PROXY_COMMON_LOADED:-}" ]] && return 0
__PROXY_COMMON_LOADED=1

export LANG=en_US.UTF-8 LC_ALL=C.UTF-8 PYTHONIOENCODING=utf-8
export DEBIAN_FRONTEND=noninteractive

# ── Пути (единая точка правды для всех скриптов) ─────────────────────
STATE_DIR="/etc/proxy"
INSTALL_ENV="${STATE_DIR}/install.env"
SECRETS_ENV="${STATE_DIR}/secrets.env"
USERS_JSON="${STATE_DIR}/users.json"
CERT_DIR="${STATE_DIR}/certs"
HY2_CONFIG="/etc/hysteria/config.yaml"
NAIVE_DIR="/opt/naiveproxy"
NAIVE_CONFIG="${NAIVE_DIR}/config/config.json"
NFT_DIR="/etc/nftables.d"
NFT_FILE="${NFT_DIR}/proxy.nft"
TOOLS_DIR="/opt/proxy"
VENV_DIR="${TOOLS_DIR}/venv"
ADMIN_BIN="/usr/local/bin/proxy-admin"
SERVICE_USER="proxyadmin"
LOG_DIR="/var/log/proxy"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/setup.log}"
BACKUP_DIR="/var/backups/proxy"

# Корень репозитория (каталог, где лежит install.sh)
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TEMPLATES_DIR="${REPO_DIR}/templates"

# ── Оформление ───────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

_log_raw() { mkdir -p "$(dirname "$LOG_FILE")"; echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }
log()      { _log_raw "$*"; }
log_step() { _log_raw "▶ $*"; echo -e "\n${BLUE}${BOLD}▶ $*${NC}"; }
log_ok()   { _log_raw "✓ $*"; echo "${GREEN}✓ $*${NC}"; }
log_warn() { _log_raw "⚠ $*"; echo "${YELLOW}⚠ $*${NC}"; }
log_info() { _log_raw "ℹ $*"; echo "${CYAN}ℹ $*${NC}"; }
log_err()  { _log_raw "✗ $*"; echo "${RED}✗ $*${NC}" >&2; }
die()      { log_err "$*"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Запустите от root: sudo $0"; }

# ── Учёт выполненных шагов (для trap ERR: «с какого шага продолжить») ─
STEPS_DONE=()
run_step() {
    # run_step <имя> <функция> [аргументы]
    local name="$1"; shift
    CURRENT_STEP="$name"
    "$@"
    STEPS_DONE+=("$name")
}

on_error() {
    local line="$1" cmd="$2"
    log_err "Ошибка на строке ${line}: ${cmd}"
    if [[ ${#STEPS_DONE[@]} -gt 0 ]]; then
        echo "${YELLOW}Выполненные шаги: ${STEPS_DONE[*]}${NC}" >&2
    fi
    [[ -n "${CURRENT_STEP:-}" ]] && echo "${YELLOW}Упавший шаг: ${CURRENT_STEP}. После исправления: $0 --config ${INSTALL_ENV} --from-step ${CURRENT_STEP}${NC}" >&2
    echo "Полный лог: ${LOG_FILE}" >&2
}

# ── Утилиты ─────────────────────────────────────────────────────────
gen_pass() {
    # 32 символа [a-zA-Z0-9] из /dev/urandom. head закрывает pipe → SIGPIPE у tr, глушим.
    { tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "${1:-32}"; } 2>/dev/null || true
    echo
}

detect_arch() {
    case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
        amd64|x86_64) echo amd64 ;;
        arm64|aarch64) echo arm64 ;;
        armhf|armv7l) echo arm ;;
        *) die "Неподдерживаемая архитектура: $(uname -m)" ;;
    esac
}

detect_ssh_port() {
    # Реальный порт sshd, а не константа 22 (п.20 рекомендаций)
    local p=""
    if command -v sshd >/dev/null 2>&1; then
        p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
    fi
    if [[ -z "$p" ]] && command -v ss >/dev/null 2>&1; then
        p="$(ss -tlnp 2>/dev/null | awk '/sshd/{split($4,a,":"); print a[length(a)]; exit}' || true)"
    fi
    echo "${p:-22}"
}

detect_public_ip() {
    curl -4 -fsS --max-time 10 https://ifconfig.me 2>/dev/null \
        || curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
        || true
}

is_valid_port()  { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
is_valid_name()  { [[ "$1" =~ ^[a-z0-9_-]{1,32}$ ]]; }
is_valid_domain(){ [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }

# ── Безопасная запись файлов ────────────────────────────────────────
# Каталог для копий файлов, которые мы перезаписываем в этом прогоне.
SAFETY_DIR="${SAFETY_DIR:-/root/proxy-pre-change-$(date +%Y%m%d-%H%M%S)}"

backup_existing() {
    # backup_existing <path> — если файл существует, копируем его в SAFETY_DIR
    local dst="$1"
    [[ -e "$dst" ]] || return 0
    mkdir -p "${SAFETY_DIR}$(dirname "$dst")"
    cp -a "$dst" "${SAFETY_DIR}${dst}"
    log "сохранена копия ${dst} → ${SAFETY_DIR}${dst}"
}

write_file() {
    # write_file <path> <mode> [owner[:group]]  — содержимое из stdin.
    # Атомарно (tmp + mv), с бэкапом старой версии и нужными правами.
    local dst="$1" mode="$2" owner="${3:-root:root}" tmp
    mkdir -p "$(dirname "$dst")"
    tmp="$(mktemp "$(dirname "$dst")/.tmp.XXXXXX")"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    chown "$owner" "$tmp"
    backup_existing "$dst"
    mv -f "$tmp" "$dst"
}

write_secret_file() { write_file "$1" 600 "${2:-root:root}"; }

render_template() {
    # render_template <template> — подставляет ТОЛЬКО перечисленные ${VAR} (envsubst с явным списком),
    # чтобы случайный $ в шаблоне (например, в nft) не интерпретировался.
    local tpl="${TEMPLATES_DIR}/$1"
    [[ -f "$tpl" ]] || die "Шаблон не найден: $tpl"
    local vars='$SERVER_DOMAIN $SERVER_IP $MAIN_PORT $HOP_START $HOP_END $SSH_PORT $TLS_CERT $TLS_KEY
                $SINGBOX_IMAGE $NAIVE_MEM_LIMIT $NAIVE_CPUS $SERVICE_USER $TOOLS_DIR $VENV_DIR
                $STATE_DIR $CERT_DIR $NAIVE_DIR $HY2_CONFIG $NAIVE_CONFIG $USERS_JSON $SECRETS_ENV
                $INSTALL_ENV $AUTHD_PORT $STATS_PORT $ADMIN_BIN $LOG_DIR $HOSTNAME_SHORT $NFT_FILE $BACKUP_DIR'
    # envsubst — отдельный процесс: видит только ЭКСПОРТИРОВАННЫЕ переменные.
    # При загрузке из install.env (load_env_file) экспорт уже сделан, но при свежей
    # интерактивной установке (ask()/apply_defaults()) это обычные переменные шелла —
    # без export ниже envsubst молча подставил бы их пустой строкой (было: пустые
    # порты/домен в nftables и других шаблонах при первом запуске без install.env).
    export SERVER_DOMAIN SERVER_IP MAIN_PORT HOP_START HOP_END SSH_PORT TLS_CERT TLS_KEY \
           SINGBOX_IMAGE NAIVE_MEM_LIMIT NAIVE_CPUS AUTHD_PORT STATS_PORT \
           SERVICE_USER TOOLS_DIR VENV_DIR STATE_DIR CERT_DIR NAIVE_DIR HY2_CONFIG NAIVE_CONFIG \
           USERS_JSON SECRETS_ENV INSTALL_ENV ADMIN_BIN LOG_DIR NFT_FILE BACKUP_DIR
    HOSTNAME_SHORT="$(hostname -s)"; export HOSTNAME_SHORT
    envsubst "$vars" < "$tpl"
}

# ── Файл состояния установки ────────────────────────────────────────
load_env_file() {
    # load_env_file <file> — безопасная загрузка KEY=VALUE (без выполнения кода)
    local f="$1" line key val
    [[ -f "$f" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" != *=* ]] && continue
        key="${line%%=*}"; val="${line#*=}"
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        # снимаем одинарные/двойные кавычки по краям
        val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
        printf -v "$key" '%s' "$val"
        export "${key?}"
    done < "$f"
}

save_install_env() {
    # Все НЕсекретные параметры установки → /etc/proxy/install.env (640: бот/authd читают порты и домен)
    getent group "$SERVICE_USER" >/dev/null 2>&1 || groupadd --system "$SERVICE_USER"
    write_file "$INSTALL_ENV" 640 "root:${SERVICE_USER}" <<EOF
# Параметры установки hysteria_naive. Генерируется install.sh, читается всеми инструментами.
# Секреты здесь не хранятся — см. secrets.env
SCHEMA_VERSION=1
INSTALLED_AT="$(date -Is)"
SERVER_DOMAIN="${SERVER_DOMAIN}"
SERVER_IP="${SERVER_IP}"
MAIN_PORT=${MAIN_PORT}
HOP_START=${HOP_START}
HOP_END=${HOP_END}
SSH_PORT=${SSH_PORT}
TLS_CERT="${TLS_CERT}"
TLS_KEY="${TLS_KEY}"
CERT_MODE="${CERT_MODE}"
FIRST_USER="${FIRST_USER}"
HY2_OBFS="${HY2_OBFS}"
HY2_UP_MBPS=${HY2_UP_MBPS}
HY2_DOWN_MBPS=${HY2_DOWN_MBPS}
AUTHD_PORT=${AUTHD_PORT}
STATS_PORT=${STATS_PORT}
SINGBOX_IMAGE="${SINGBOX_IMAGE}"
NAIVE_MEM_LIMIT="${NAIVE_MEM_LIMIT}"
NAIVE_CPUS="${NAIVE_CPUS}"
ENABLE_SWAP="${ENABLE_SWAP}"
SWAP_SIZE_MB=${SWAP_SIZE_MB}
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN}"
ENABLE_CLEANUP_TIMER="${ENABLE_CLEANUP_TIMER}"
BACKUP_KEEP=${BACKUP_KEEP}
EOF
}

save_secrets_env() {
    # Секреты → /etc/proxy/secrets.env (640 root:proxyadmin — бот и authd читают, остальные нет)
    getent group "$SERVICE_USER" >/dev/null 2>&1 || groupadd --system "$SERVICE_USER"
    write_file "$SECRETS_ENV" 640 "root:${SERVICE_USER}" <<EOF
# Секреты hysteria_naive. Права 640 root:${SERVICE_USER}. Никогда не коммитить.
TG_TOKEN="${TG_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
TG_ADMIN_IDS="${TG_ADMIN_IDS}"
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE}"
HY2_STATS_SECRET="${HY2_STATS_SECRET}"
EOF
}

apply_defaults() {
    # Значения по умолчанию для всего, что может отсутствовать в install.env
    : "${SERVER_IP:=}"
    : "${MAIN_PORT:=443}"
    : "${HOP_START:=20000}"
    : "${HOP_END:=50000}"
    : "${SSH_PORT:=$(detect_ssh_port)}"
    : "${CERT_MODE:=letsencrypt}"      # letsencrypt | selfsigned | existing
    : "${TLS_CERT:=}"
    : "${TLS_KEY:=}"
    : "${FIRST_USER:=admin}"
    : "${HY2_OBFS:=yes}"
    : "${HY2_UP_MBPS:=100}"
    : "${HY2_DOWN_MBPS:=200}"
    : "${AUTHD_PORT:=9911}"
    : "${STATS_PORT:=9912}"
    : "${SINGBOX_IMAGE:=ghcr.io/sagernet/sing-box:${SINGBOX_VERSION}}"
    : "${NAIVE_MEM_LIMIT:=256m}"
    : "${NAIVE_CPUS:=1.0}"
    : "${ENABLE_SWAP:=auto}"           # yes | no | auto (создать, если swap нет)
    : "${SWAP_SIZE_MB:=512}"
    : "${ENABLE_FAIL2BAN:=yes}"
    : "${ENABLE_CLEANUP_TIMER:=yes}"
    : "${BACKUP_KEEP:=7}"
    : "${TG_TOKEN:=}"
    : "${TG_CHAT_ID:=}"
    : "${TG_ADMIN_IDS:=}"
    : "${BACKUP_PASSPHRASE:=}"
    : "${HY2_STATS_SECRET:=}"
}

validate_params() {
    is_valid_domain "$SERVER_DOMAIN" || die "Некорректный домен: '${SERVER_DOMAIN}'"
    is_valid_port "$MAIN_PORT"  || die "Некорректный MAIN_PORT: $MAIN_PORT"
    is_valid_port "$HOP_START"  || die "Некорректный HOP_START: $HOP_START"
    is_valid_port "$HOP_END"    || die "Некорректный HOP_END: $HOP_END"
    is_valid_port "$SSH_PORT"   || die "Некорректный SSH_PORT: $SSH_PORT"
    (( HOP_START < HOP_END )) || die "HOP_START должен быть меньше HOP_END"
    (( MAIN_PORT < HOP_START || MAIN_PORT > HOP_END )) || die "MAIN_PORT не должен попадать в диапазон hopping"
    (( SSH_PORT < HOP_START || SSH_PORT > HOP_END )) || die "SSH_PORT не должен попадать в диапазон hopping"
    is_valid_name "$FIRST_USER" || die "Имя пользователя: только [a-z0-9_-], 1–32 символа"
    case "$CERT_MODE" in letsencrypt|selfsigned|existing) ;; *) die "CERT_MODE: letsencrypt|selfsigned|existing" ;; esac
    if [[ -n "$TG_TOKEN" ]]; then
        [[ "$TG_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || die "TG_TOKEN не похож на токен бота"
        [[ "$TG_CHAT_ID" =~ ^-?[0-9]+$ ]] || die "TG_CHAT_ID должен быть числом"
        [[ -z "$TG_ADMIN_IDS" ]] && TG_ADMIN_IDS="$TG_CHAT_ID"
        [[ "$TG_ADMIN_IDS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "TG_ADMIN_IDS: список user id через запятую"
    fi
}

ensure_service_user() {
    getent group "$SERVICE_USER" >/dev/null 2>&1 || groupadd --system "$SERVICE_USER"
    if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --gid "$SERVICE_USER" --home-dir "$TOOLS_DIR" --no-create-home \
                --shell /usr/sbin/nologin "$SERVICE_USER"
    fi
    mkdir -p "$STATE_DIR" "$LOG_DIR" "$BACKUP_DIR"
    # 751: пользователь hysteria должен пройти в certs/, при этом файлы внутри — 640 root:proxyadmin
    chmod 751 "$STATE_DIR"; chgrp "$SERVICE_USER" "$STATE_DIR"
    chmod 750 "$LOG_DIR";   chgrp "$SERVICE_USER" "$LOG_DIR"
    chmod 700 "$BACKUP_DIR"
}

systemd_unit_from_template() {
    # systemd_unit_from_template <template-name> <unit-name>
    render_template "systemd/$1" | write_file "/etc/systemd/system/$2" 644
}

wait_active() {
    # wait_active <unit> [секунд]
    # ВАЖНО: `i` обязан быть local — эта функция вызывается изнутри цикла STEPS в
    # install.sh (main()), который использует свою переменную `i` для индекса шага.
    # Без `local` они делят одну и ту же глобальную `i`: после возврата отсюда
    # `i` в main() оказывается перезаписана (0..n вместо индекса текущего шага),
    # и `for ((i += 2))` в главном цикле откатывается назад — install.sh начинает
    # шаги заново, минуя deps и никогда не доходя до certhook и далее.
    local unit="$1" n="${2:-10}" i
    for ((i = 0; i < n; i++)); do
        systemctl is-active --quiet "$unit" && return 0
        sleep 1
    done
    return 1
}
