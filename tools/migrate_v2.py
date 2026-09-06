#!/usr/bin/env python3
"""migrate_v2 — конвертирует бэкап v2 (proxybackupYYYYMMDD.tar.gz от proxy-manager.sh)
в бэкап v3, который понимает restore.sh.

Что переносится без изменений (клиенты продолжают работать со старыми ссылками):
  * все пользователи Hysteria2 (auth.type=userpass, включая _disabled_users → enabled=false)
  * все пользователи NaiveProxy (users + _disabled_users)
  * obfs-пароль salamander
  * домен (из пути к сертификату), основной порт, диапазон hopping, SSH-порт (из nftables.conf)
Что НЕ восстановить из бэкапа v2 (там этого не было) — задаётся флагами или дописывается
в /etc/proxy/secrets.env после restore: TG_TOKEN, TG_CHAT_ID, TG_ADMIN_IDS, BACKUP_PASSPHRASE.

Использование:
  python3 tools/migrate_v2.py proxybackup20260905.tar.gz -o proxy-backup-v3.tar.gz \
      [--tg-token ... --tg-chat-id ... --tg-admin-ids 1,2] [--ssh-port 22] [--ip 203.0.113.5]
  sudo ./restore.sh proxy-backup-v3.tar.gz --yes
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import sys
import tarfile
from datetime import datetime, timezone
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from proxy_admin import NAME_RE, SCHEMA_VERSION, gen_password  # noqa: E402


def read_member(tar: tarfile.TarFile, name: str) -> str | None:
    for cand in (name, "./" + name):
        try:
            f = tar.extractfile(cand)
        except KeyError:
            continue
        if f:
            return f.read().decode("utf-8")
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("backup", help="proxybackupYYYYMMDD.tar.gz из v2")
    ap.add_argument("-o", "--output", default="proxy-backup-v3.tar.gz")
    ap.add_argument("--ip", default="", help="SERVER_IP (пусто = определит install.sh)")
    ap.add_argument("--ssh-port", type=int, default=0, help="переопределить SSH-порт (по умолчанию из nftables.conf)")
    ap.add_argument("--tg-token", default="")
    ap.add_argument("--tg-chat-id", default="")
    ap.add_argument("--tg-admin-ids", default="")
    ap.add_argument("--backup-passphrase", default="", help="пусто = сгенерировать")
    ap.add_argument("--first-user", default="admin")
    args = ap.parse_args()

    with tarfile.open(args.backup) as tar:
        hy2_text = read_member(tar, "etc/hysteria/config.yaml")
        naive_text = read_member(tar, "opt/naiveproxy/config/config.json")
        nft_text = read_member(tar, "etc/nftables.conf") or ""
    if not hy2_text or not naive_text:
        sys.exit("В архиве нет etc/hysteria/config.yaml или opt/naiveproxy/config/config.json — это не бэкап v2")

    hy2 = yaml.safe_load(hy2_text)
    naive = json.loads(naive_text)
    inbound = naive["inbounds"][0]

    # ── домен и порты ────────────────────────────────────────────────
    cert = str(hy2.get("tls", {}).get("cert", ""))
    m = re.search(r"/etc/letsencrypt/live/([^/]+)/", cert)
    if m:
        domain, cert_mode, tls_cert, tls_key = m.group(1), "letsencrypt", "", ""
    else:
        domain = re.sub(r"^.*/", "", os.path.dirname(cert)) or "CHANGE_ME.example.com"
        cert_mode, tls_cert, tls_key = "existing", cert, str(hy2.get("tls", {}).get("key", ""))
        print(f"⚠ Сертификат не Let's Encrypt ({cert}); CERT_MODE=existing, домен угадан как {domain} — проверьте", file=sys.stderr)
    main_port = int(str(hy2.get("listen", ":443")).rsplit(":", 1)[-1])
    hop = re.search(r"dport (\d+)-(\d+) redirect", nft_text)
    hop_start, hop_end = (int(hop.group(1)), int(hop.group(2))) if hop else (20000, 50000)
    ssh = re.search(r"tcp dport (\d+) accept", "\n".join(
        l for l in nft_text.splitlines() if "accept" in l and str(main_port) not in l and "-" not in l))
    ssh_port = args.ssh_port or (int(ssh.group(1)) if ssh else 22)

    # ── пользователи ────────────────────────────────────────────────
    auth = hy2.get("auth", {})
    hy2_users: dict[str, tuple[str, bool]] = {}
    if auth.get("type") == "userpass":
        hy2_users.update({n: (str(p), True) for n, p in (auth.get("userpass") or {}).items()})
        hy2_users.update({n: (str(p), False) for n, p in (hy2.get("_disabled_users") or {}).items()})
    elif auth.get("type") == "password":
        # Режим одного пароля без имени: клиентам с такой ссылкой понадобится новая (user:pass)
        hy2_users[args.first_user] = (str(auth.get("password", "")), True)
        print(f"⚠ v2 работала в режиме одного пароля; он назначен пользователю '{args.first_user}'.\n"
              f"  Ссылка Hysteria2 у клиентов изменится (добавится имя) — выдайте новую: proxy-admin links {args.first_user}",
              file=sys.stderr)
    naive_users = {u["username"]: (str(u["password"]), True) for u in inbound.get("users", [])}
    naive_users.update({u["username"]: (str(u["password"]), False) for u in inbound.get("_disabled_users", [])})

    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    users: dict[str, dict] = {}
    warnings: list[str] = []
    for name in sorted(set(hy2_users) | set(naive_users)):
        if not NAME_RE.fullmatch(name):
            warnings.append(f"имя '{name}' не проходит валидацию v3 ([a-z0-9_-]{{1,32}}) — пропущено, создайте заново")
            continue
        h = hy2_users.get(name)
        n = naive_users.get(name)
        users[name] = {
            "hy2_password": h[0] if h else gen_password(),
            "naive_password": n[0] if n else gen_password(),
            "enabled": (h[1] if h else True) and (n[1] if n else True),
            "created_at": now,
            "rotated_at": None,
            "note": "перенесён из v2" + ("" if h and n else " (не было в " + ("Naive" if h else "HY2") + ", пароль сгенерирован)"),
        }
    obfs = (hy2.get("obfs") or {}).get("salamander", {}).get("password") or gen_password()
    if "obfs" not in hy2:
        warnings.append("в v2 obfs не был включён — сгенерирован новый obfs-пароль; поставьте HY2_OBFS=no в install.env, если клиенты без obfs")

    state = {"schema_version": SCHEMA_VERSION, "obfs_password": obfs, "users": users}
    install_env = f"""# Сконвертировано из бэкапа v2 ({os.path.basename(args.backup)}) утилитой tools/migrate_v2.py {now}
SCHEMA_VERSION=1
INSTALLED_AT="{now}"
SERVER_DOMAIN="{domain}"
SERVER_IP="{args.ip}"
MAIN_PORT={main_port}
HOP_START={hop_start}
HOP_END={hop_end}
SSH_PORT={ssh_port}
TLS_CERT="{tls_cert}"
TLS_KEY="{tls_key}"
CERT_MODE="{cert_mode}"
FIRST_USER="{args.first_user if args.first_user in users else next(iter(users), 'admin')}"
HY2_OBFS="yes"
HY2_UP_MBPS={int(str(hy2.get('bandwidth', {}).get('up', '100 mbps')).split()[0])}
HY2_DOWN_MBPS={int(str(hy2.get('bandwidth', {}).get('down', '200 mbps')).split()[0])}
AUTHD_PORT=9911
STATS_PORT=9912
ENABLE_SWAP="auto"
SWAP_SIZE_MB=512
ENABLE_FAIL2BAN="yes"
ENABLE_CLEANUP_TIMER="yes"
BACKUP_KEEP=7
"""
    secrets_env = f"""# Секреты hysteria_naive (сконвертировано из v2; Telegram в бэкапе v2 не хранился)
TG_TOKEN="{args.tg_token}"
TG_CHAT_ID="{args.tg_chat_id}"
TG_ADMIN_IDS="{args.tg_admin_ids or args.tg_chat_id}"
BACKUP_PASSPHRASE="{args.backup_passphrase or gen_password(40)}"
HY2_STATS_SECRET="{gen_password()}"
"""

    def add(tar: tarfile.TarFile, name: str, data: str, mode: int = 0o640) -> None:
        b = data.encode()
        ti = tarfile.TarInfo(name); ti.size = len(b); ti.mode = mode; ti.mtime = int(datetime.now().timestamp())
        tar.addfile(ti, io.BytesIO(b))

    with tarfile.open(args.output, "w:gz") as tar:
        add(tar, "etc/proxy/install.env", install_env)
        add(tar, "etc/proxy/secrets.env", secrets_env)
        add(tar, "etc/proxy/users.json", json.dumps(state, indent=2, ensure_ascii=False) + "\n")
    os.chmod(args.output, 0o600)

    print(f"✓ {args.output}: домен {domain}, порт {main_port}, hopping {hop_start}-{hop_end}, SSH {ssh_port}, "
          f"cert={cert_mode}, пользователей {len(users)} "
          f"(активных {sum(1 for u in users.values() if u['enabled'])})")
    for w in warnings:
        print("⚠ " + w, file=sys.stderr)
    if not args.tg_token:
        print("ℹ Telegram не задан: допишите TG_TOKEN/TG_CHAT_ID/TG_ADMIN_IDS в /etc/proxy/secrets.env после restore "
              "и выполните systemctl enable --now proxy-bot", file=sys.stderr)
    print(f"Дальше: sudo ./restore.sh {args.output} --yes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
