#!/usr/bin/env bash
# lib/output.sh — итоговый вывод: ссылки первого пользователя, файл /root/proxy-config.txt,
# уведомление в Telegram. Ссылки строит proxy-admin (одна реализация для установщика и бота, п.7).

print_summary() {
    log_step "Итог"
    local outfile="/root/proxy-config.txt"
    {
        echo "============================================================"
        echo "  hysteria_naive — конфигурация ($(date))"
        echo "============================================================"
        echo "Сервер:        ${SERVER_DOMAIN} (${SERVER_IP})"
        echo "Основной порт: ${MAIN_PORT}   Port hopping: ${HOP_START}-${HOP_END} (mport в ссылке)"
        echo "Сертификат:    ${CERT_MODE} (${TLS_CERT})"
        echo
        "$ADMIN_BIN" links "$FIRST_USER"
        echo
        echo "Управление:    proxy-admin --help   (add/del/enable/disable/rotate/links/qr/status/backup)"
        echo "Состояние:     ${STATE_DIR}/ (install.env, secrets.env, users.json, certs/)"
        echo "Бэкапы:        ${BACKUP_DIR}/ (gpg, пароль в secrets.env: BACKUP_PASSPHRASE)"
        echo "Восстановление: sudo ./restore.sh <backup.tar.gz.gpg>"
        echo "Telegram:      $([[ -n "$TG_TOKEN" ]] && echo "бот включён, админы: ${TG_ADMIN_IDS}" || echo "не настроен")"
        echo "============================================================"
    } | write_secret_file "$outfile"

    echo
    echo "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo "${CYAN}${BOLD}║                  УСТАНОВКА ЗАВЕРШЕНА                     ║${NC}"
    echo "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    "$ADMIN_BIN" links "$FIRST_USER"
    echo
    echo "${CYAN}Сохранено в ${outfile} (600). Пароль шифрования бэкапов — в ${SECRETS_ENV}.${NC}"
    if [[ "$CERT_MODE" == "selfsigned" ]]; then
        log_warn "Самоподписанный сертификат: в клиентах включите insecure (ссылки уже содержат insecure=1)"
    fi
    "$ADMIN_BIN" notify "✅ <b>${SERVER_DOMAIN}</b> настроен. Пользователь <code>${FIRST_USER}</code>: /links ${FIRST_USER}" >> "$LOG_FILE" 2>&1 || true
}
