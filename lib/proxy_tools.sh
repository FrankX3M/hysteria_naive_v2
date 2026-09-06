#!/usr/bin/env bash
# lib/proxy_tools.sh — установка Python-инструментов (/opt/proxy):
#   proxy_admin.py  — единая логика управления пользователями и конфигами (CLI)
#   proxy_authd.py  — HTTP-аутентификация для Hysteria2 (без рестартов)
#   proxy_bot.py    — Telegram-обвязка над proxy-admin
# плюс systemd-юниты и таймеры (watchdog, backup, cleanup), sudoers для бота.

install_python_tools() {
    log_step "Инструменты управления (${TOOLS_DIR}, venv, requirements.txt)"
    ensure_service_user
    mkdir -p "${TOOLS_DIR}/tools"
    install -m 644 -o root -g root "${REPO_DIR}/tools/proxy_admin.py" "${REPO_DIR}/tools/proxy_authd.py" \
        "${REPO_DIR}/tools/proxy_bot.py" "${REPO_DIR}/tools/requirements.txt" "${TOOLS_DIR}/tools/"
    if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
        python3 -m venv "$VENV_DIR" >> "$LOG_FILE" 2>&1 || die "python3 -m venv не удался (нет python3-venv?)"
    fi
    "${VENV_DIR}/bin/pip" install --quiet --upgrade pip >> "$LOG_FILE" 2>&1 || true
    "${VENV_DIR}/bin/pip" install --quiet -r "${TOOLS_DIR}/tools/requirements.txt" >> "$LOG_FILE" 2>&1 \
        || die "pip install не удался — см. $LOG_FILE"
    # Обёртка: root-owned, не редактируется сервисным пользователем → безопасна для sudoers
    write_file "$ADMIN_BIN" 755 <<EOF
#!/bin/sh
exec "${VENV_DIR}/bin/python" "${TOOLS_DIR}/tools/proxy_admin.py" "\$@"
EOF
    render_template "sudoers-proxyadmin" | write_file /etc/sudoers.d/proxyadmin 440
    visudo -cf /etc/sudoers.d/proxyadmin >> "$LOG_FILE" 2>&1 || die "sudoers невалиден"
    chown -R root:root "$TOOLS_DIR"; chmod 755 "$TOOLS_DIR"
    log_ok "proxy-admin: $("$ADMIN_BIN" --version)"
}

init_state() {
    # users.json создаётся один раз; при --upgrade не трогается (п.27)
    log_step "Файл состояния пользователей (${USERS_JSON})"
    if [[ -f "$USERS_JSON" ]]; then
        "$ADMIN_BIN" migrate >> "$LOG_FILE" 2>&1 && log_ok "users.json уже существует — сохранён ($("$ADMIN_BIN" --json list | jq -r '.users|length') польз.)"
    else
        "$ADMIN_BIN" init --first-user "$FIRST_USER" >> "$LOG_FILE" 2>&1 || die "proxy-admin init не удался"
        log_ok "Создан users.json с пользователем ${FIRST_USER}"
    fi
}

install_services() {
    log_step "Сервисы: proxy-authd, proxy-bot, таймеры watchdog/backup"
    systemd_unit_from_template "proxy-authd.service"    "proxy-authd.service"
    systemd_unit_from_template "proxy-watchdog.service" "proxy-watchdog.service"
    systemd_unit_from_template "proxy-watchdog.timer"   "proxy-watchdog.timer"
    systemd_unit_from_template "proxy-backup.service"   "proxy-backup.service"
    systemd_unit_from_template "proxy-backup.timer"     "proxy-backup.timer"
    # Старый cron из v2 больше не нужен
    rm -f /etc/cron.d/proxy-manager /usr/local/bin/proxy-manager.sh /usr/local/bin/proxy_bot.py
    systemctl daemon-reload
    systemctl enable --now proxy-authd >> "$LOG_FILE" 2>&1
    wait_active proxy-authd 5 && log_ok "proxy-authd запущен (127.0.0.1:${AUTHD_PORT})" \
        || die "proxy-authd не запустился: journalctl -xeu proxy-authd"
    systemctl enable --now proxy-watchdog.timer proxy-backup.timer >> "$LOG_FILE" 2>&1
    log_ok "Таймеры: watchdog каждые 5 мин, backup ежедневно 03:00"

    if [[ -n "$TG_TOKEN" ]]; then
        systemd_unit_from_template "proxy-bot.service" "proxy-bot.service"
        systemctl daemon-reload
        systemctl enable --now proxy-bot >> "$LOG_FILE" 2>&1
        systemctl restart proxy-bot
        if wait_active proxy-bot 8; then
            log_ok "Telegram-бот запущен"
        else
            log_warn "Telegram-бот не запустился: journalctl -xeu proxy-bot"
        fi
    else
        systemctl disable --now proxy-bot >> "$LOG_FILE" 2>&1 || true
        log_info "Telegram не настроен — бот не установлен"
    fi
}

install_maintenance() {
    [[ "$ENABLE_CLEANUP_TIMER" == "yes" ]] || return 0
    log_step "Ежедневная очистка (maintenance/servercleanup.sh)"
    install -m 755 -o root -g root "${REPO_DIR}/maintenance/servercleanup.sh" /usr/local/sbin/servercleanup.sh
    install -m 755 -o root -g root "${REPO_DIR}/maintenance/serveraudit.sh"   /usr/local/sbin/serveraudit.sh
    install -m 644 "${REPO_DIR}/maintenance/servercleanup.service" /etc/systemd/system/servercleanup.service
    install -m 644 "${REPO_DIR}/maintenance/servercleanup.timer"   /etc/systemd/system/servercleanup.timer
    systemctl daemon-reload
    systemctl enable --now servercleanup.timer >> "$LOG_FILE" 2>&1
    log_ok "servercleanup.timer включён (03:30), аудит: serveraudit.sh"
}

apply_proxy_configs() {
    # Рендер + валидация + (пере)запуск hysteria и naiveproxy — всё внутри proxy-admin
    log_step "Генерация конфигов Hysteria2 / sing-box из /etc/proxy"
    "$ADMIN_BIN" apply --restart >> "$LOG_FILE" 2>&1 || die "proxy-admin apply не удался — см. $LOG_FILE"
    log_ok "Конфиги применены, сервисы запущены"
}
