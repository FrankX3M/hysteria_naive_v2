#!/usr/bin/env bash
# chain-route-setup.sh — для проекта hysteria_naive_v2
# (https://github.com/FrankX3M/hysteria_naive_v2)
#
# Собирает мост "этот сервер → второй сервер" с гео-маршрутизацией в одно действие:
#
#   0) настраивает локальный Hysteria2-клиент по ссылке (hysteria2://...) —
#      он подключается ко второму серверу и поднимает локальный SOCKS5;
#   1) патчит render_singbox() в tools/proxy_admin.py так, чтобы NaiveProxy-вход
#      (sing-box) заворачивал исходящий трафик в этот SOCKS5, КРОМЕ:
#        — реального гео-трафика указанных стран (по GeoIP базе sing-geoip);
#        — доменов из списка исключений (.ru/.su/.рф/YouTube и т.п. — редактируется);
#      который идёт напрямую с этого сервера;
#      резолвинг доменов на обоих outbound'ах принудительно IPv4-only
#      (domain_resolver), чтобы клиент не улетал на IPv6 по своей DNS-логике;
#   1a) опционально: список доменов, которые ПРИНУДИТЕЛЬНО идут через цепочку,
#      даже если попадают под .ru/geoip:ru (например gosuslugi.ru) — правило
#      ставится раньше direct-правил в обоих движках;
#   1b) патчит render_hysteria() в том же файле так, чтобы нативный Hysteria2-вход
#      (hysteria-server, профили admin-HY2/test-HY2) применял ТУ ЖЕ самую политику
#      (те же домены/страны — direct, остальное — в тот же SOCKS5-туннель) через
#      нативные outbounds/acl.inline самого Hysteria2, той же geoip-базой (единый
#      geoip.dat, скачивается один раз, отдельно от sing-geoip *.srs для sing-box);
#      включает серверный sniff Hysteria2 (нужна версия >= 2.6.0) — без него ACL
#      по доменам не работает для клиентов, которые резолвят DNS сами и шлют IP;
#   1c) опционально: reject BitTorrent на NaiveProxy-входе (sing-box определяет
#      протокол через sniff), чтобы торренты не улетали через второй сервер;
#   2) сам находит установленную копию proxy_admin.py и папку конфига NaiveProxy;
#   3) качает актуальные GeoIP-базы: rule-set *.srs для sing-box (sing-geoip,
#      ветка rule-set) и geoip.dat для нативного Hysteria2 (Loyalsoldier/geoip);
#   4) идемпотентно патчит render_singbox() и render_hysteria() (маркеры в коде —
#      повторный запуск просто пересобирает оба блока с новыми параметрами,
#      не плодит дублей);
#   5) синхронизирует патч в установленную копию и вызывает `proxy-admin apply`
#      (он сам валидирует оба конфига перед применением — если что-то невалидно,
#      ничего не сломается, старый рабочий вариант останется активным).
#
# Использование:
#   sudo bash chain-route-setup.sh                  # полная настройка (клиент + маршрутизация)
#   sudo bash chain-route-setup.sh --skip-client     # не трогать Hysteria-клиента (он уже настроен)
#   sudo bash chain-route-setup.sh --only-geoip      # только обновить GeoIP-базы
#   sudo bash chain-route-setup.sh --undo            # откатить маршрутизацию к чистому direct-only
#
set -euo pipefail

GEOIP_BASE_URL="https://github.com/SagerNet/sing-geoip/raw/rule-set"
GEOIP_DAT_URL="https://github.com/Loyalsoldier/geoip/releases/latest/download/geoip.dat"
MARK_BEGIN="        # ==== HYSTERIA_NAIVE_CHAIN_ROUTE (сгенерировано chain-route-setup.sh, руками не редактировать) ===="
MARK_END="        # ==== END HYSTERIA_NAIVE_CHAIN_ROUTE ===="
MARK_BEGIN_HY="    # ==== HYSTERIA_NAIVE_CHAIN_ROUTE_HY2 (сгенерировано chain-route-setup.sh, руками не редактировать) ===="
MARK_END_HY="    # ==== END HYSTERIA_NAIVE_CHAIN_ROUTE_HY2 ===="
HY_CLIENT_CONFIG="/etc/hysteria/client.yaml"
HY_CLIENT_UNIT="/etc/systemd/system/hysteria-client.service"
HY_SERVER_GEOIP="/etc/hysteria/geoip.dat"
# Дефолтный список доменов «напрямую». youtube.com обязателен — без него сам
# youtube.com (в т.ч. redirector.c.youtube.com) уходит через цепочку.
DOM_DEFAULT=".ru,.su,.рф,youtube.com,youtu.be,googlevideo.com,ytimg.com,youtube-nocookie.com,ggpht.com,youtubei.googleapis.com,youtube.googleapis.com,youtubekids.com,youtubeeducation.com,gvt1.com,gvt2.com,gvt3.com,video.google.com"

log()  { echo -e "\033[1;36m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }
die()  { err "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запусти от root: sudo bash $0"
command -v docker  >/dev/null 2>&1 || die "docker не найден"
command -v python3 >/dev/null 2>&1 || die "python3 не найден"
command -v proxy-admin >/dev/null 2>&1 || die "proxy-admin не найден в PATH — это точно проект hysteria_naive_v2?"

MODE="setup"
SKIP_CLIENT=0
for a in "$@"; do
    case "$a" in
        --only-geoip)  MODE="geoip" ;;
        --undo)        MODE="undo" ;;
        --skip-client) SKIP_CLIENT=1 ;;
        *) die "Неизвестный аргумент: $a (допустимо: --only-geoip, --undo, --skip-client)" ;;
    esac
done

# ── находим установленную копию proxy_admin.py и репозиторий ──────────────
INSTALLED_PY="$(sed -n 's/.*"\(\/[^"]*proxy_admin\.py\)".*/\1/p' "$(command -v proxy-admin)" | head -1)"
[ -n "$INSTALLED_PY" ] && [ -f "$INSTALLED_PY" ] || die "Не смог найти установленный proxy_admin.py через $(command -v proxy-admin)"
log "Установленный файл: $INSTALLED_PY"

REPO_DIR="${REPO_DIR:-}"
if [ -z "$REPO_DIR" ]; then
    for c in "$HOME/hysteria_naive_v2" "$(pwd)"; do
        [ -f "$c/tools/proxy_admin.py" ] && REPO_DIR="$c" && break
    done
fi
[ -n "$REPO_DIR" ] && [ -f "$REPO_DIR/tools/proxy_admin.py" ] \
    || read -rp "Путь к git-клону hysteria_naive_v2 (где tools/proxy_admin.py): " REPO_DIR
REPO_PY="$REPO_DIR/tools/proxy_admin.py"
[ -f "$REPO_PY" ] || die "Не найден $REPO_PY"
log "Репозиторий: $REPO_PY"

# ── находим папку конфига NaiveProxy (куда класть geoip-*.srs) ────────────
NAIVE_CFG_DIR="$(docker inspect naiveproxy --format '{{range .Mounts}}{{if eq .Destination "/etc/sing-box"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
[ -n "$NAIVE_CFG_DIR" ] || die "Не смог определить папку конфига контейнера naiveproxy (docker inspect). Контейнер запущен?"
log "Папка конфига NaiveProxy (на хосте): $NAIVE_CFG_DIR"

# ── UNDO ────────────────────────────────────────────────────────────────
if [ "$MODE" = "undo" ]; then
    log "Откатываю маршрутизацию к чистому direct-only outbound (Hysteria-клиент не трогаю)..."
    python3 - "$REPO_PY" "$MARK_BEGIN" "$MARK_END" <<'PYEOF'
import sys, re
path, mb, me = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding="utf-8").read()
pattern = re.escape(mb) + r".*?" + re.escape(me) + r"\n?"
new_src, n = re.subn(pattern, '        "outbounds": [{"type": "direct", "tag": "direct"}],\n', src, flags=re.S)
if n == 0:
    print("Патч render_singbox() не найден — нечего откатывать (или уже чистый файл).")
else:
    open(path, "w", encoding="utf-8").write(new_src)
    print(f"render_singbox(): откачено ({n} блок(ов)).")
PYEOF
    python3 - "$REPO_PY" "$MARK_BEGIN_HY" "$MARK_END_HY" <<'PYEOF'
import sys, re
path, mb, me = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding="utf-8").read()
pattern = re.escape(mb) + r".*?" + re.escape(me) + r"\n?"
new_src, n = re.subn(pattern, '', src, flags=re.S)
if n == 0:
    print("Патч render_hysteria() не найден — нечего откатывать (или уже чистый файл).")
else:
    open(path, "w", encoding="utf-8").write(new_src)
    print(f"render_hysteria(): откачено ({n} блок(ов)).")
PYEOF
    cp "$REPO_PY" "$INSTALLED_PY"
    proxy-admin apply
    ok "Готово: сервер снова работает напрямую (direct), без цепочки — на обоих входах (NaiveProxy и Hysteria2)."
    exit 0
fi

# ── 0) Hysteria2-клиент по ссылке ──────────────────────────────────────
CHAIN_HOST="127.0.0.1"
CHAIN_PORT="1080"
CHAIN_TYPE="socks"

setup_hysteria_client() {
    local link http_port=8080 socks_port=1080

    if [ -f "$HY_CLIENT_UNIT" ] && systemctl is-active --quiet hysteria-client 2>/dev/null; then
        read -rp "Hysteria-клиент уже настроен и работает. Перенастроить новой ссылкой? [y/N]: " ans
        [[ "${ans,,}" == "y" ]] || { log "Оставляю текущего клиента как есть."; return 0; }
    fi

    read -rp "Вставь ссылку hysteria2://... (или hy2://...) второго сервера: " link
    [[ "$link" =~ ^(hysteria2|hy2):// ]] || die "Ссылка должна начинаться с hysteria2:// или hy2://"

    log "Устанавливаю Hysteria2 (если ещё не установлена)..."
    apt-get update -qq && apt-get install -y -qq curl ca-certificates python3 >/dev/null
    if ! command -v hysteria >/dev/null 2>&1; then
        bash <(curl -fsSL https://get.hy2.sh/) >/dev/null
    fi

    mkdir -p /etc/hysteria
    LINK="$link" HTTP_PORT="$http_port" SOCKS_PORT="$socks_port" python3 - > "$HY_CLIENT_CONFIG" <<'PYEOF'
import os, sys, json
from urllib.parse import urlsplit, parse_qs, unquote

u = urlsplit(os.environ["LINK"].strip())
if u.scheme not in ("hysteria2", "hy2"):
    sys.exit("bad scheme")
host, port = u.hostname, u.port or 443
if not host:
    sys.exit("no host in link")

auth = ""
if u.username is not None:
    auth = unquote(u.username)
    if u.password is not None:
        auth += ":" + unquote(u.password)

q = {k: v[0] for k, v in parse_qs(u.query).items()}
sni      = q.get("sni") or host
insecure = q.get("insecure", "0") in ("1", "true")
pin      = q.get("pinSHA256", "")
obfs     = q.get("obfs", "")
obfs_pw  = q.get("obfs-password", "")
mport    = q.get("mport", "")

Q = json.dumps
server = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
if mport:
    server = f"{host}:{port},{mport}"

out = [f"server: {Q(server)}", f"auth: {Q(auth)}", "", "tls:",
       f"  sni: {Q(sni)}", f"  insecure: {'true' if insecure else 'false'}"]
if pin:
    out.append(f"  pinSHA256: {Q(pin)}")
if obfs:
    out += ["", "obfs:", f"  type: {Q(obfs)}", f"  {obfs}:", f"    password: {Q(obfs_pw)}"]
out += ["",
        "http:", f"  listen: 127.0.0.1:{os.environ['HTTP_PORT']}", "",
        "socks5:", f"  listen: 127.0.0.1:{os.environ['SOCKS_PORT']}", "",
        "bandwidth:", "  up: 50 mbps", "  down: 200 mbps", "",
        "fastOpen: true", "lazy: true"]
print("\n".join(out))
print(f"  server={server} sni={sni} insecure={insecure} obfs={obfs or '-'}", file=sys.stderr)
PYEOF
    chmod 600 "$HY_CLIENT_CONFIG"

    cat > "$HY_CLIENT_UNIT" <<'EOF'
[Unit]
Description=Hysteria 2 Client (chain to upstream server)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria client -c /etc/hysteria/client.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now hysteria-client >/dev/null
    systemctl restart hysteria-client
    sleep 2
    systemctl is-active --quiet hysteria-client \
        || { journalctl -u hysteria-client -n 20 --no-pager; die "hysteria-client не поднялся"; }

    log "Проверяю туннель..."
    if curl -s -m 8 -x "http://127.0.0.1:${http_port}" https://ifconfig.me >/dev/null; then
        ok "Hysteria-клиент работает, туннель поднят (SOCKS5 127.0.0.1:${socks_port})."
    else
        journalctl -u hysteria-client -n 20 --no-pager
        die "Клиент запущен, но тест через прокси не прошёл — проверь данные ссылки/сеть."
    fi

    CHAIN_HOST="127.0.0.1"; CHAIN_PORT="$socks_port"; CHAIN_TYPE="socks"
}

if [ "$MODE" = "setup" ] && [ "$SKIP_CLIENT" -eq 0 ]; then
    setup_hysteria_client
elif [ "$MODE" = "setup" ] && [ "$SKIP_CLIENT" -eq 1 ]; then
    log "Пропускаю настройку клиента (--skip-client)."
fi

# ── параметры маршрутизации (интерактивно, с дефолтами) ────────────────
if [ "$MODE" = "setup" ]; then
    echo
    log "Параметры цепочки на sing-box (NaiveProxy-сервер) для завёртывания трафика:"
    read -rp "Тип прокси второго сервера — socks/http [${CHAIN_TYPE}]: " t; CHAIN_TYPE="${t:-$CHAIN_TYPE}"
    [[ "$CHAIN_TYPE" =~ ^(socks|http)$ ]] || die "Тип должен быть socks или http"
    read -rp "Адрес (обычно локальный Hysteria-клиент) [${CHAIN_HOST}]: " h; CHAIN_HOST="${h:-$CHAIN_HOST}"
    read -rp "Порт [${CHAIN_PORT}]: " po; CHAIN_PORT="${po:-$CHAIN_PORT}"
    read -rp "Код(ы) стран для GeoIP-direct через запятую [ru]: " GEO_IN; GEO_IN="${GEO_IN:-ru}"
    echo
    log "Домены напрямую. Дефолт: ${DOM_DEFAULT}"
    log "Если хочешь ДОБАВИТЬ к дефолту — начни ввод с '+' (например: +vk.com,mail.ru);"
    log "без '+' введённый список ПОЛНОСТЬЮ заменяет дефолт (следи, чтобы youtube.com не потерялся)."
    read -rp "Домены напрямую [Enter = дефолт]: " DOM_IN
    if [ -z "$DOM_IN" ]; then
        DOM_IN="$DOM_DEFAULT"
    elif [[ "$DOM_IN" == +* ]]; then
        DOM_IN="${DOM_DEFAULT},${DOM_IN#+}"
    fi
    echo
    log "Домены ПРИНУДИТЕЛЬНО через цепочку (второй сервер), даже если они .ru / в GeoIP-стране."
    log "Например, gosuslugi.ru,gu-st.ru. Пусто — не нужно."
    read -rp "Домены через цепочку [пусто]: " CHAIN_DOM_IN; CHAIN_DOM_IN="${CHAIN_DOM_IN:-}"
    echo
    read -rp "Блокировать BitTorrent на NaiveProxy-входе (reject, чтобы торренты не шли через второй сервер)? [y/N]: " bt
    BLOCK_BT=0; [[ "${bt,,}" == "y" ]] && BLOCK_BT=1
else
    # --only-geoip: параметры маршрутизации не нужны, страны возьмём из уже применённого патча
    GEO_IN="$(grep -oP '"tag":\s*"geoip-\K[a-z]+' "$REPO_PY" | paste -sd, -)"
    [ -n "$GEO_IN" ] || die "Патч ещё не применён — сначала запусти без --only-geoip"
    DOM_IN=""; CHAIN_DOM_IN=""; BLOCK_BT=0
fi

# ── версия hysteria: серверный sniff появился в 2.6.0 ─────────────────
HY_SNIFF=0
HY_VER="$(hysteria version 2>/dev/null | grep -oP 'v?\K[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [ -n "$HY_VER" ]; then
    if [ "$(printf '%s\n' "2.6.0" "$HY_VER" | sort -V | head -1)" = "2.6.0" ]; then
        HY_SNIFF=1
        log "hysteria $HY_VER — серверный sniff поддерживается, включаю его для hysteria-server."
    else
        err "hysteria $HY_VER < 2.6.0 — серверный sniff недоступен. Клиенты HY2-профилей, которые"
        err "резолвят DNS сами (шлют IP вместо домена), НЕ попадут под доменные правила — только под GeoIP."
        err "Обнови hysteria: bash <(curl -fsSL https://get.hy2.sh/)"
    fi
else
    err "Не смог определить версию hysteria (команда 'hysteria version') — sniff для hysteria-server не включаю."
fi

IFS=',' read -ra GEO_CODES <<< "$GEO_IN"

# ── скачиваем GeoIP rule-set файлы ─────────────────────────────────────
for cc in "${GEO_CODES[@]}"; do
    cc="$(echo "$cc" | xargs)"
    [ -n "$cc" ] || continue
    dest="$NAIVE_CFG_DIR/geoip-${cc}.srs"
    log "Качаю geoip-${cc}.srs ..."
    tmp="$(mktemp)"
    if curl -fsSL "${GEOIP_BASE_URL}/geoip-${cc}.srs" -o "$tmp"; then
        if file "$tmp" | grep -qiE 'ASCII text|HTML'; then
            rm -f "$tmp"
            die "geoip-${cc}.srs скачался как текст/HTML — неверный код страны или файла нет: $cc"
        fi
        mv "$tmp" "$dest"; chmod 640 "$dest"
        ok "geoip-${cc}.srs → $dest ($(stat -c%s "$dest") байт)"
    else
        rm -f "$tmp"
        die "Не удалось скачать geoip-${cc}.srs (проверь код страны / доступ к github.com)"
    fi
done

# ── качаем единую geoip.dat для нативного Hysteria2-сервера ────────────
log "Качаю geoip.dat для Hysteria2-сервера (одна общая база, страны внутри неё)..."
tmp="$(mktemp)"
if curl -fsSL -L "$GEOIP_DAT_URL" -o "$tmp"; then
    if file "$tmp" | grep -qiE 'ASCII text|HTML'; then
        rm -f "$tmp"
        die "geoip.dat скачался как текст/HTML — проверь доступ к github.com (URL: $GEOIP_DAT_URL)"
    fi
    mv "$tmp" "$HY_SERVER_GEOIP"; chmod 644 "$HY_SERVER_GEOIP"
    # 644, а не 640: hysteria-server может работать под отдельным непривилегированным
    # пользователем (не root/не в группе root), и с 640 он не сможет открыть файл
    # ("permission denied") — geoip.dat не секретен, так что читаемость всем не вредит.
    ok "geoip.dat → $HY_SERVER_GEOIP ($(stat -c%s "$HY_SERVER_GEOIP") байт)"
else
    rm -f "$tmp"
    die "Не удалось скачать geoip.dat (проверь доступ к github.com)"
fi

[ "$MODE" = "geoip" ] && {
    ok "GeoIP-базы обновлены. Перезапускаю naiveproxy и hysteria-server, чтобы подхватить..."
    docker restart naiveproxy >/dev/null
    systemctl restart hysteria-server 2>/dev/null || true
    ok "Готово."
    exit 0
}

# ── собираем JSON-параметры для python-патчера ─────────────────────────
PARAMS_JSON="$(python3 - "$CHAIN_TYPE" "$CHAIN_HOST" "$CHAIN_PORT" "$GEO_IN" "$DOM_IN" "$CHAIN_DOM_IN" "$BLOCK_BT" "$HY_SNIFF" <<'PYEOF'
import json, sys
chain_type, chain_host, chain_port, geo_in, dom_in, chain_dom_in, block_bt, hy_sniff = sys.argv[1:9]
def split(s):
    out = []
    for x in s.split(","):
        x = x.strip()
        if x and x not in out:   # без дублей, порядок сохраняем
            out.append(x)
    return out
countries     = split(geo_in)
domains       = split(dom_in)
chain_domains = split(chain_dom_in)
print(json.dumps({
    "chain_type": chain_type,
    "chain_host": chain_host,
    "chain_port": int(chain_port),
    "countries": countries,
    "domains": domains,
    "chain_domains": chain_domains,
    "block_bt": block_bt == "1",
    "hy_sniff": hy_sniff == "1",
}))
PYEOF
)"
log "Итоговые параметры: $PARAMS_JSON"

cp "$REPO_PY" "${REPO_PY}.bak-$(date +%Y%m%d-%H%M%S)"

# ── патчим render_singbox() (идемпотентно, через маркеры) ─────────────
python3 - "$REPO_PY" "$MARK_BEGIN" "$MARK_END" "$PARAMS_JSON" <<'PYEOF'
import sys, re, json

path, mb, me, params_json = sys.argv[1:5]
p = json.loads(params_json)

def build_block():
    rule_set = []
    rule_tags = []
    for cc in p["countries"]:
        tag = f"geoip-{cc}"
        rule_tags.append(tag)
        rule_set.append(
            '                {"tag": %s, "type": "local", "format": "binary", '
            '"path": "/etc/sing-box/%s.srs"},' % (json.dumps(tag), tag)
        )
    domains_fmt = ",\n".join(
        "                        " + json.dumps(d) for d in p["domains"]
    )
    rule_set_fmt = "\n".join(rule_set)
    tags_fmt = ", ".join(json.dumps(t) for t in rule_tags)

    # Правила, идущие СРАЗУ после sniff, до direct-правил (первое совпадение выигрывает):
    #   — reject BitTorrent (если включено);
    #   — принудительно через цепочку (gosuslugi.ru и т.п.), даже если .ru / geoip:ru.
    pre_rules = []
    if p["block_bt"]:
        pre_rules.append('                {"protocol": "bittorrent", "action": "reject"},')
    if p["chain_domains"]:
        pre_rules.append(
            '                {"domain_suffix": [%s], "outbound": "chain-fin"},'
            % ", ".join(json.dumps(d) for d in p["chain_domains"])
        )
    pre_rules_fmt = ("\n".join(pre_rules) + "\n") if pre_rules else ""

    block = f'''{mb}
        "dns": {{"servers": [{{"type": "local", "tag": "local"}}]}},
        "outbounds": [
            {{"type": "direct", "tag": "direct", "domain_resolver": {{"server": "local", "strategy": "ipv4_only"}}}},
            {{
                "type": {json.dumps(p["chain_type"])},
                "tag": "chain-fin",
                "server": {json.dumps(p["chain_host"])},
                "server_port": {p["chain_port"]},
                "domain_resolver": {{"server": "local", "strategy": "ipv4_only"}},
            }},
        ],
        "route": {{
            "rule_set": [
{rule_set_fmt}
            ],
            "rules": [
                {{"action": "sniff"}},
{pre_rules_fmt}                {{
                    "domain_suffix": [
{domains_fmt},
                    ],
                    "outbound": "direct",
                }},
                {{
                    "rule_set": [{tags_fmt}],
                    "outbound": "direct",
                }},
            ],
            "final": "chain-fin",
        }},
{me}
'''
    return block

src = open(path, encoding="utf-8").read()
block = build_block()

pattern = re.escape(mb) + r".*?" + re.escape(me) + r"\n?"
if re.search(pattern, src, flags=re.S):
    src, n = re.subn(pattern, lambda _m: block, src, flags=re.S)
    print(f"Обновлён существующий патч ({n} блок).")
else:
    old = '        "outbounds": [{"type": "direct", "tag": "direct"}],\n'
    n = src.count(old)
    if n != 1:
        sys.exit(f"Не нашёл ни маркеры патча, ни исходную строку outbounds "
                  f"(найдено совпадений: {n}). Структура render_singbox() в этой версии "
                  f"репозитория отличается — патчить нужно вручную.")
    src = src.replace(old, block)
    print("Патч применён впервые.")

open(path, "w", encoding="utf-8").write(src)
PYEOF

ok "render_singbox() в репозитории обновлён."

# ── патчим render_hysteria() (тот же чек, но нативный ACL Hysteria2) ──
python3 - "$REPO_PY" "$MARK_BEGIN_HY" "$MARK_END_HY" "$PARAMS_JSON" "$HY_SERVER_GEOIP" <<'PYEOF'
import sys, re, json

path, mb, me, params_json, geoip_path = sys.argv[1:6]
p = json.loads(params_json)

def build_block_hy():
    # ВАЖНО: у Hysteria2 свой ACL-парсер (не JSON), и он не понимает дефис
    # в имени outbound'а — "chain-fin(all)" падает с "invalid syntax".
    # Все примеры в официальной документации используют только подчёркивания
    # (v4_only, some_proxy), поэтому здесь — отдельное от sing-box имя.
    ct = p["chain_type"]
    if ct == "http":
        outbound_fmt = (
            '        {"name": "chain_fin", "type": "http", "http": {"url": %s}},'
            % json.dumps(f'http://{p["chain_host"]}:{p["chain_port"]}')
        )
    else:
        outbound_fmt = (
            '        {"name": "chain_fin", "type": "socks5", "socks5": {"addr": %s}},'
            % json.dumps(f'{p["chain_host"]}:{p["chain_port"]}')
        )

    inline = []
    # Сначала — принудительно через цепочку (правила проверяются по порядку,
    # срабатывает первое совпадение, поэтому они должны стоять ДО direct(...)).
    for d in p["chain_domains"]:
        d = d.lstrip(".")
        if d:
            inline.append('            %s,' % json.dumps(f"chain_fin(suffix:{d})"))
    for d in p["domains"]:
        d = d.lstrip(".")
        if d:
            inline.append('            %s,' % json.dumps(f"direct(suffix:{d})"))
    for cc in p["countries"]:
        inline.append('            %s,' % json.dumps(f"direct(geoip:{cc})"))
    inline.append('            "chain_fin(all)",')
    inline_fmt = "\n".join(inline)

    # Серверный sniff (Hysteria2 >= 2.6.0): ACL видит реальный домен из TLS SNI /
    # HTTP Host / QUIC даже если клиент прислал голый IP (резолвил DNS сам).
    # rewriteDomain: false — домен только для матчинга, соединение идёт на тот
    # адрес, который прислал клиент (как sniff в sing-box без override).
    sniff_fmt = ""
    if p["hy_sniff"]:
        sniff_fmt = ('    doc["sniff"] = {"enable": True, "timeout": "2s", "rewriteDomain": False,\n'
                     '                    "tcpPorts": "all", "udpPorts": "all"}\n')

    block = f'''{mb}
{sniff_fmt}    doc["outbounds"] = [
{outbound_fmt}
    ]
    doc["acl"] = {{
        "geoip": {json.dumps(geoip_path)},
        "geoUpdateInterval": "168h",
        "inline": [
{inline_fmt}
        ],
    }}
{me}
'''
    return block

src = open(path, encoding="utf-8").read()
block = build_block_hy()

pattern = re.escape(mb) + r".*?" + re.escape(me) + r"\n?"
if re.search(pattern, src, flags=re.S):
    src, n = re.subn(pattern, lambda _m: block, src, flags=re.S)
    print(f"render_hysteria(): обновлён существующий патч ({n} блок).")
else:
    # Ищем границы именно тела render_hysteria() и патчим якорь только внутри
    # неё — та же строка "if cfg.obfs:" почти наверняка встречается ещё и в
    # hy2_link() (для параметра obfs в шареной ссылке), поэтому патчить по
    # всему файлу нельзя — задев не ту функцию.
    fn_match = re.search(r"\ndef render_hysteria\([^\n]*\n", src)
    if not fn_match:
        sys.exit("Не нашёл функцию render_hysteria() в файле — структура проекта отличается, "
                  "патчить Hysteria2-сторону нужно вручную (см. README).")
    fn_start = fn_match.end()
    next_def = re.search(r"\ndef \w+\(", src[fn_start:])
    fn_end = fn_start + next_def.start() if next_def else len(src)
    body = src[fn_start:fn_end]

    anchor = "    if cfg.obfs:\n"
    n = body.count(anchor)
    if n != 1:
        sys.exit(f"Не нашёл якорь 'if cfg.obfs:' внутри тела render_hysteria() ровно один раз "
                  f"(найдено: {n}). Структура render_hysteria() в этой версии репозитория "
                  f"отличается — патчить нужно вручную (см. README).")
    new_body = body.replace(anchor, block + anchor, 1)
    src = src[:fn_start] + new_body + src[fn_end:]
    print("render_hysteria(): патч применён впервые.")

open(path, "w", encoding="utf-8").write(src)
PYEOF

ok "render_hysteria() в репозитории обновлён."

# ── синхронизируем и применяем ─────────────────────────────────────────
cp "$INSTALLED_PY" "${INSTALLED_PY}.bak-$(date +%Y%m%d-%H%M%S)"
diff -u "$INSTALLED_PY" "$REPO_PY" || true
cp "$REPO_PY" "$INSTALLED_PY"

log "Применяю (proxy-admin apply)..."
if proxy-admin apply; then
    ok "Готово! Оба входа (NaiveProxy и Hysteria2) заворачивают трафик в ${CHAIN_TYPE}://${CHAIN_HOST}:${CHAIN_PORT}, страны [${GEO_IN}] и домены [${DOM_IN}] идут напрямую."
    [ -n "$CHAIN_DOM_IN" ] && ok "Принудительно через цепочку: [${CHAIN_DOM_IN}]"
    [ "$BLOCK_BT" -eq 1 ] && ok "BitTorrent на NaiveProxy-входе: reject"
    [ "$HY_SNIFF" -eq 1 ] && ok "Hysteria2 sniff: включён" || err "Hysteria2 sniff: НЕ включён (см. предупреждение выше)"
    echo
    echo "Проверка:"
    echo "  systemctl status hysteria-client hysteria-server"
    echo "  docker logs naiveproxy --tail 20"
    echo "  cat $NAIVE_CFG_DIR/config.json"
    echo "  cat /etc/hysteria/config.yaml"
    echo
    echo "Обновить только GeoIP-базы позже:      sudo bash $0 --only-geoip"
    echo "Перенастроить/сменить второй сервер:   sudo bash $0"
    echo "Откатить маршрутизацию (оба входа):    sudo bash $0 --undo"
else
    err "proxy-admin apply завершился с ошибкой — конфиг НЕ применён, старый рабочий вариант остался активен."
    err "Смотри вывод выше (обычно там точная причина от sing-box check)."
    exit 1
fi
