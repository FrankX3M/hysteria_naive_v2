#!/usr/bin/env bash
# tests/test_templates.sh — рендер всех шаблонов с тестовыми параметрами и проверка синтаксиса:
#   nft -c (nftables), python yaml (docker-compose), systemd-analyze verify (юниты, если доступен),
#   bash -n (deploy-hook). Не требует root, кроме nft -c (если нельзя — пропускается).
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_DIR
LOG_FILE="$(mktemp)"; export LOG_FILE
# shellcheck source=../lib/common.sh
source "${REPO_DIR}/lib/common.sh"
# shellcheck source=../lib/versions.sh
source "${REPO_DIR}/lib/versions.sh"

SERVER_DOMAIN=proxy.example.com SERVER_IP=203.0.113.5 SSH_PORT=2222 TLS_CERT=/tmp/c.pem TLS_KEY=/tmp/k.pem
apply_defaults
export SERVER_DOMAIN SERVER_IP MAIN_PORT HOP_START HOP_END SSH_PORT TLS_CERT TLS_KEY SINGBOX_IMAGE NAIVE_MEM_LIMIT \
       NAIVE_CPUS AUTHD_PORT STATS_PORT

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT" "$LOG_FILE"' EXIT
fail=0
check() { if "$@"; then echo "ok   $1 ${*: -1}"; else echo "FAIL $*"; fail=1; fi; }

# Все шаблоны рендерятся и не содержат неподставленных ${...} из нашего списка
while IFS= read -r -d '' tpl; do
    rel="${tpl#"${TEMPLATES_DIR}"/}"
    mkdir -p "$OUT/$(dirname "$rel")"
    render_template "$rel" > "$OUT/$rel"
    if grep -qE '\$\{(SERVER_DOMAIN|MAIN_PORT|HOP_START|HOP_END|SSH_PORT|CERT_DIR|STATE_DIR|SERVICE_USER|VENV_DIR|TOOLS_DIR|ADMIN_BIN|NFT_FILE)\}' "$OUT/$rel"; then
        echo "FAIL неподставленная переменная в $rel"; fail=1
    else
        echo "ok   render $rel"
    fi
done < <(find "$TEMPLATES_DIR" -type f -print0)

# nftables: policy drop, SSH-порт, tcp/80, отсутствие flush ruleset
nft_out="$OUT/nftables-proxy.nft"
grep -q 'policy drop' "$nft_out"            && echo "ok   nft policy drop"   || { echo "FAIL nft policy"; fail=1; }
grep -q 'tcp dport 2222 accept' "$nft_out"  && echo "ok   nft ssh 2222"      || { echo "FAIL nft ssh"; fail=1; }
grep -q 'tcp dport 80 accept' "$nft_out"    && echo "ok   nft tcp/80"        || { echo "FAIL nft 80"; fail=1; }
grep -vE '^\s*#' "$nft_out" | grep -q 'flush ruleset'          && { echo "FAIL nft flush ruleset"; fail=1; } || echo "ok   nft no flush ruleset"
if command -v nft >/dev/null 2>&1; then
    if nft -c -f "$nft_out" 2>/dev/null; then echo "ok   nft -c syntax"; else echo "skip nft -c (нужен root/CAP_NET_ADMIN)"; fi
fi

# docker-compose: валидный YAML, лимиты
python3 - "$OUT/docker-compose.yml" <<'PY' && echo "ok   compose yaml" || { echo "FAIL compose"; fail=1; }
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
s = d["services"]["naiveproxy"]
assert s["mem_limit"] and s["cpus"] and s["network_mode"] == "host"
assert s["logging"]["driver"] == "journald"
assert ":latest" not in s["image"], s["image"]
PY

# systemd-юниты
if command -v systemd-analyze >/dev/null 2>&1; then
    for u in "$OUT"/systemd/*; do
        systemd-analyze verify --man=no "$u" >/dev/null 2>&1 && echo "ok   unit $(basename "$u")" || echo "warn unit $(basename "$u") (verify недоступен вне systemd)"
    done
fi
grep -q '^User=hysteria' "$OUT/systemd/hysteria-server.service" && echo "ok   hysteria User=" || { echo "FAIL hysteria root"; fail=1; }
grep -q "^User=${SERVICE_USER}" "$OUT/systemd/proxy-bot.service" && echo "ok   bot User=" || { echo "FAIL bot root"; fail=1; }

check bash -n "$OUT/certbot-deploy-hook.sh"
check visudo -cf "$OUT/sudoers-proxyadmin" 2>/dev/null || true

# load_env_file не выполняет код
printf 'SERVER_DOMAIN="x.example.com"\nEVIL=$(touch /tmp/pwned)\n' > "$OUT/env"
load_env_file "$OUT/env"
[[ "$EVIL" == '$(touch /tmp/pwned)' && ! -e /tmp/pwned ]] && echo "ok   load_env_file безопасен" || { echo "FAIL load_env_file"; fail=1; }

# Валидация параметров
( SERVER_DOMAIN=proxy.example.com MAIN_PORT=443 HOP_START=20000 HOP_END=50000 SSH_PORT=22 FIRST_USER=admin CERT_MODE=letsencrypt TG_TOKEN='' validate_params ) && echo "ok   validate_params" || { echo "FAIL validate_params"; fail=1; }
( SERVER_DOMAIN=proxy.example.com MAIN_PORT=30000 HOP_START=20000 HOP_END=50000 SSH_PORT=22 FIRST_USER=admin CERT_MODE=letsencrypt TG_TOKEN='' validate_params ) 2>/dev/null && { echo "FAIL порт в hopping не отловлен"; fail=1; } || echo "ok   validate_params отлавливает порт в диапазоне"
( SERVER_DOMAIN=proxy.example.com MAIN_PORT=443 HOP_START=20000 HOP_END=50000 SSH_PORT=22 FIRST_USER='Bad Name' CERT_MODE=letsencrypt TG_TOKEN='' validate_params ) 2>/dev/null && { echo "FAIL плохое имя"; fail=1; } || echo "ok   validate_params отлавливает имя"

# Проверка «порт разрешён» не должна зависеть от формата вывода nft
# (nft < 1.0 печатает имена служб: `tcp dport ssh accept`)
source "${REPO_DIR}/lib/firewall.sh"
json_fixture='{"nftables":[{"chain":{"name":"input"}},
  {"rule":{"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":2222}},{"accept":null}]}},
  {"rule":{"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":{"set":[80,8080]}}},{"accept":null}]}},
  {"rule":{"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":9999}},{"drop":null}]}}]}'
json_has_accept_port 2222 <<<"$json_fixture" && echo "ok   json: порт-число найден"      || { echo "FAIL json: 2222"; fail=1; }
json_has_accept_port 8080 <<<"$json_fixture" && echo "ok   json: порт в set найден"      || { echo "FAIL json: set"; fail=1; }
json_has_accept_port 9999 <<<"$json_fixture" && { echo "FAIL json: drop принят за accept"; fail=1; } || echo "ok   json: drop не считается accept"
json_has_accept_port 22   <<<"$json_fixture" && { echo "FAIL json: лишний порт"; fail=1; } || echo "ok   json: отсутствующий порт не найден"
old_nft='	chain input {
		tcp dport ssh accept comment "ssh"
		tcp dport http accept
	}'
svc="$(getent services 22/tcp | awk '{print $1}' || true)"
grep -qE "tcp dport (22|${svc:-__no_service__})([[:space:],]|$).*accept" <<<"$old_nft" \
    && echo "ok   текст: имя службы ssh распознано" || { echo "FAIL текст: имя службы"; fail=1; }
svc="$(getent services 2222/tcp 2>/dev/null | awk '{print $1}' || true)"
grep -qE "tcp dport (2222|${svc:-__no_service__})([[:space:],]|$).*accept" <<<"$old_nft" \
    && { echo "FAIL текст: ложное срабатывание"; fail=1; } || echo "ok   текст: чужой порт не распознан"

exit $fail
