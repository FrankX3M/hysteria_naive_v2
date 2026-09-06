#!/usr/bin/env bash
# restore.sh — восстановление из зашифрованного бэкапа и «жёсткая» перезагрузка.
#
#   sudo ./restore.sh /path/proxy-backup-20260905-030000.tar.gz.gpg [--yes]
#       Расшифровывает архив (пароль: BACKUP_PASSPHRASE из окружения, --passphrase-file
#       или запрос с клавиатуры), раскладывает /etc/proxy (install.env, secrets.env,
#       users.json, certs/) и запускает install.sh --from-step deps: ставятся недостающие
#       пакеты, генерируются конфиги из восстановленного состояния, поднимаются сервисы.
#       Никаких «угадываний» домена/портов по косвенным признакам — всё в install.env (п.20).
#
#   sudo ./restore.sh --hard-reload [--pull]
#       Без архива: пересинхронизировать сертификаты, убить осиротевшие процессы hysteria,
#       переприменить nftables (со страховкой), перегенерировать конфиги и пересоздать
#       контейнер naiveproxy. --pull — принудительно обновить образ sing-box.
#
# Совет: на VPS с 1 ГБ RAM запускайте в tmux/screen — apt/docker pull могут вызвать OOM и обрыв SSH.
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR
for f in common versions system certs hysteria naiveproxy firewall fail2ban proxy_tools; do
    # shellcheck source=/dev/null
    source "${REPO_DIR}/lib/${f}.sh"
done
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

BACKUP_FILE=""; ASSUME_YES=0; HARD_RELOAD=0; FORCE_PULL=0; PASSPHRASE_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hard-reload) HARD_RELOAD=1; shift ;;
        --pull)        FORCE_PULL=1; shift ;;
        --yes|-y)      ASSUME_YES=1; shift ;;
        --passphrase-file) PASSPHRASE_FILE="$2"; shift 2 ;;
        -h|--help)     sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)            die "Неизвестный флаг: $1" ;;
        *)             [[ -z "$BACKUP_FILE" ]] && BACKUP_FILE="$1" || die "Лишний аргумент: $1"; shift ;;
    esac
done
require_root
[[ -n "$BACKUP_FILE" || $HARD_RELOAD -eq 1 ]] || die "Укажите архив бэкапа или --hard-reload (см. --help)"

confirm() { [[ $ASSUME_YES -eq 1 ]] && return 0; read -r -p "$1 [y/N]: " r; [[ "$r" =~ ^[Yy]$ ]]; }

kill_orphan_processes() {
    # hysteria, запущенная руками мимо systemd, держит порт и старый конфиг
    local main_pid; main_pid="$(systemctl show hysteria-server -p MainPID --value 2>/dev/null || echo 0)"
    local pid
    for pid in $(pgrep -x hysteria 2>/dev/null || true); do
        [[ "$pid" == "$main_pid" ]] && continue
        log_warn "Осиротевший процесс hysteria PID $pid — завершаю"
        kill "$pid" 2>/dev/null || true
    done
}

restore_from_backup() {
    [[ -f "$BACKUP_FILE" ]] || die "Файл не найден: $BACKUP_FILE"
    log_step "Восстановление из ${BACKUP_FILE}"
    local work; work="$(mktemp -d /tmp/proxy-restore.XXXXXX)"; chmod 700 "$work"
    trap 'rm -rf "$work"' EXIT
    local tarball="$work/backup.tar.gz"
    if [[ "$BACKUP_FILE" == *.gpg ]]; then
        command -v gpg >/dev/null 2>&1 || apt-get install -y -qq gnupg >> "$LOG_FILE" 2>&1
        if [[ -n "$PASSPHRASE_FILE" ]]; then
            gpg --batch --quiet --passphrase-file "$PASSPHRASE_FILE" --decrypt "$BACKUP_FILE" > "$tarball"
        elif [[ -n "${BACKUP_PASSPHRASE:-}" ]]; then
            gpg --batch --quiet --passphrase-fd 3 --decrypt "$BACKUP_FILE" > "$tarball" 3<<<"$BACKUP_PASSPHRASE"
        else
            gpg --quiet --decrypt "$BACKUP_FILE" > "$tarball"
        fi
    else
        cp "$BACKUP_FILE" "$tarball"
    fi
    tar -xzf "$tarball" -C "$work"
    local f
    if [[ ! -f "$work/etc/proxy/install.env" && -f "$work/etc/hysteria/config.yaml" ]]; then
        die "Это бэкап v2 (proxy-manager.sh). Сначала сконвертируйте: python3 tools/migrate_v2.py ${BACKUP_FILE} -o proxy-backup-v3.tar.gz"
    fi
    for f in etc/proxy/install.env etc/proxy/secrets.env etc/proxy/users.json; do
        [[ -f "$work/$f" ]] || die "В бэкапе нет обязательного файла: $f"
    done
    load_env_file "$work/etc/proxy/install.env"
    log_ok "Бэкап: домен ${SERVER_DOMAIN}, порт ${MAIN_PORT}, hopping ${HOP_START}-${HOP_END}, SSH ${SSH_PORT}"
    log_warn "Убедитесь, что DNS ${SERVER_DOMAIN} → IP этого сервера и в облачном файрволе открыты"
    log_warn "tcp/${SSH_PORT}, tcp/80, tcp+udp/${MAIN_PORT}, tcp+udp/${HOP_START}-${HOP_END}."
    confirm "Продолжить восстановление?" || die "Отменено"

    ensure_service_user
    mkdir -p "$STATE_DIR" "$CERT_DIR"
    for f in install.env secrets.env users.json; do
        backup_existing "${STATE_DIR}/$f"
        install -m 640 -o root -g "$SERVICE_USER" "$work/etc/proxy/$f" "${STATE_DIR}/$f"
    done
    if [[ -d "$work/etc/proxy/certs" ]]; then
        getent group hysteria >/dev/null 2>&1 || groupadd --system hysteria
        for f in fullchain.pem privkey.pem; do
            [[ -f "$work/etc/proxy/certs/$f" ]] && install -m 640 -o root -g hysteria "$work/etc/proxy/certs/$f" "$CERT_DIR/$f"
        done
        chgrp hysteria "$CERT_DIR"; chmod 750 "$CERT_DIR"
    fi
    # SSH-порт на новом сервере может отличаться от сохранённого — берём реальный
    local real_ssh; real_ssh="$(detect_ssh_port)"
    if [[ "$real_ssh" != "$SSH_PORT" ]]; then
        log_warn "SSH-порт на этом сервере ${real_ssh}, в бэкапе ${SSH_PORT} — использую ${real_ssh}"
        sed -i "s/^SSH_PORT=.*/SSH_PORT=${real_ssh}/" "$INSTALL_ENV"
    fi
    log_ok "Состояние восстановлено в ${STATE_DIR}"
    rm -rf "$work"; trap - EXIT
    log_step "Запуск установщика с восстановленным состоянием"
    exec "${REPO_DIR}/install.sh" --config "$INSTALL_ENV" --from-step deps
}

hard_reload() {
    load_env_file "$INSTALL_ENV" || die "Нет ${INSTALL_ENV} — сервер не установлен этой версией. Для старой установки см. docs/MIGRATION.md"
    load_env_file "$SECRETS_ENV" || true
    apply_defaults
    log_step "Жёсткая перезагрузка (${SERVER_DOMAIN})"
    [[ "$CERT_MODE" == "letsencrypt" && -f "/etc/letsencrypt/live/${SERVER_DOMAIN}/fullchain.pem" ]] && sync_certs || true
    kill_orphan_processes
    render_firewall
    apply_firewall_safely
    if [[ $FORCE_PULL -eq 1 ]]; then
        check_memory
        docker pull "$SINGBOX_IMAGE" >> "$LOG_FILE" 2>&1 && log_ok "Образ обновлён: ${SINGBOX_IMAGE}"
    fi
    configure_naiveproxy
    (cd "$NAIVE_DIR" && docker compose down --remove-orphans) >> "$LOG_FILE" 2>&1 || true
    "$ADMIN_BIN" apply --restart || die "proxy-admin apply не удался"
    systemctl restart proxy-authd
    [[ -n "$TG_TOKEN" ]] && systemctl restart proxy-bot || true
    echo
    "$ADMIN_BIN" status
}

if [[ -n "$BACKUP_FILE" ]]; then restore_from_backup; else hard_reload; fi
