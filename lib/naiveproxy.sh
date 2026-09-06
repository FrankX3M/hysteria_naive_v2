#!/usr/bin/env bash
# lib/naiveproxy.sh — Docker + NaiveProxy (sing-box) как docker compose с лимитами ресурсов.
#
# config.json сюда НЕ пишется: его рендерит и валидирует (`sing-box check`) proxy-admin apply.

install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log_ok "Docker уже установлен: $(docker --version)"
        return 0
    fi
    log_step "Установка Docker (get.docker.com)"
    check_memory
    local tmp; tmp="$(mktemp)"
    curl -fsSL --retry 3 -o "$tmp" https://get.docker.com || die "Не удалось скачать установщик Docker"
    sh "$tmp" >> "$LOG_FILE" 2>&1 || die "Установка Docker не удалась — см. $LOG_FILE"
    rm -f "$tmp"
    systemctl enable --now docker >> "$LOG_FILE" 2>&1
    docker compose version >/dev/null 2>&1 || die "Плагин docker compose не установлен"
    # Фиксируем версию, чтобы apt-upgrade не обновил Docker незаметно
    apt-mark hold docker-ce docker-ce-cli containerd.io >> "$LOG_FILE" 2>&1 || true
    log_ok "Docker установлен: $(docker --version)"
}

configure_naiveproxy() {
    log_step "NaiveProxy: docker-compose (${SINGBOX_IMAGE}, mem=${NAIVE_MEM_LIMIT}, cpus=${NAIVE_CPUS})"
    mkdir -p "${NAIVE_DIR}/config"; chmod 750 "${NAIVE_DIR}/config"
    render_template "docker-compose.yml" | write_file "${NAIVE_DIR}/docker-compose.yml" 644
    # Старый контейнер v2 (docker run) — убрать, compose создаст свой с тем же именем
    if docker ps -a --format '{{.Names}}' | grep -qx naiveproxy \
       && ! docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' naiveproxy 2>/dev/null | grep -q .; then
        docker rm -f naiveproxy >> "$LOG_FILE" 2>&1 || true
        log_warn "Старый контейнер naiveproxy (docker run) удалён — теперь им управляет compose"
    fi
    if ! docker image inspect "$SINGBOX_IMAGE" >/dev/null 2>&1; then
        check_memory
        log_info "docker pull ${SINGBOX_IMAGE}"
        docker pull "$SINGBOX_IMAGE" >> "$LOG_FILE" 2>&1 || die "Не удалось скачать образ ${SINGBOX_IMAGE}"
    fi
    log_ok "compose-файл: ${NAIVE_DIR}/docker-compose.yml"
}

start_naiveproxy() {
    (cd "$NAIVE_DIR" && docker compose up -d --remove-orphans) >> "$LOG_FILE" 2>&1
    local i status
    for ((i = 0; i < 10; i++)); do
        status="$(docker inspect -f '{{.State.Status}}' naiveproxy 2>/dev/null || echo none)"
        [[ "$status" == "running" ]] && { log_ok "NaiveProxy запущен"; return 0; }
        sleep 1
    done
    log_err "NaiveProxy не запустился (status=${status}): docker logs naiveproxy"
    return 1
}
