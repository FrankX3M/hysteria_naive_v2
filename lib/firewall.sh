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

    # Проверяем, что порт SSH действительно разрешён в ЖИВОМ наборе правил
    if nft_accepts_tcp_port "$SSH_PORT"; then
        if [[ -n "$job" ]]; then
            atrm "$job" 2>/dev/null && log_ok "Автооткат отменён — правила применены штатно"
        fi
        log_ok "nftables применён: policy drop, разрешены ${SSH_PORT}/tcp (SSH), 80/tcp, ${MAIN_PORT}/tcp+udp"
    else
        log_err "В активных правилах нет accept для SSH-порта ${SSH_PORT} — оставляю автооткат (job #${job:-нет})"
        log_err "Через 3 минуты таблица inet proxy удалится сама. Посмотреть, что применилось: nft list chain inet proxy input"
        return 1
    fi
}

# ── Проверка «порт разрешён» без зависимости от формата вывода nft ──────
# Текстовый вывод nft до 1.0 печатает имена служб из /etc/services
# (`tcp dport ssh accept` вместо `tcp dport 22 accept`), поэтому grep по номеру
# порта там не срабатывает. Разбираем JSON (`nft -j`), а текст оставляем
# как запасной вариант, учитывая оба написания.
json_has_accept_port() {
    # json_has_accept_port <порт> — JSON от `nft -j list chain ...` на stdin.
    # Скрипт передаём через -c, а не heredoc: heredoc занял бы stdin, и JSON бы не дошёл.
    python3 -c '
import json, sys

port = int(sys.argv[1])

def matches(value) -> bool:
    if isinstance(value, dict):
        if "range" in value:
            lo, hi = value["range"]
            return int(lo) <= port <= int(hi)
        if "set" in value:
            return any(matches(v) for v in value["set"])
        return False
    if isinstance(value, list):
        return any(matches(v) for v in value)
    try:
        return int(value) == port
    except (TypeError, ValueError):
        return False

try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(2)

for item in data.get("nftables", []):
    rule = item.get("rule")
    if not rule:
        continue
    exprs = rule.get("expr", [])
    if not any("accept" in e for e in exprs if isinstance(e, dict)):
        continue
    for e in exprs:
        m = e.get("match") if isinstance(e, dict) else None
        if not m:
            continue
        payload = (m.get("left") or {}).get("payload") or {}
        if payload.get("field") == "dport" and payload.get("protocol") == "tcp" and matches(m.get("right")):
            sys.exit(0)
sys.exit(1)
' "$1"
}

nft_accepts_tcp_port() {
    local port="$1" json text svc
    json="$(nft -j list chain inet proxy input 2>/dev/null || true)"
    if [[ -n "$json" ]] && command -v python3 >/dev/null 2>&1; then
        local rc=0
        json_has_accept_port "$port" <<<"$json" || rc=$?
        [[ $rc -eq 0 ]] && return 0   # правило найдено
        [[ $rc -eq 1 ]] && return 1   # правила точно нет
        # rc=2 — JSON не разобрался (старый nft без -j): проверяем текстом
    fi
    text="$(nft --numeric list chain inet proxy input 2>/dev/null || nft list chain inet proxy input 2>/dev/null || true)"
    [[ -n "$text" ]] || return 1
    svc="$(getent services "${port}/tcp" 2>/dev/null | awk '{print $1}')"
    grep -qE "tcp dport (${port}|${svc:-__no_service__})([[:space:],]|$).*accept" <<<"$text"
}

configure_firewall() {
    render_firewall
    apply_firewall_safely
}
