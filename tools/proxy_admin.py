#!/usr/bin/env python3
"""proxy-admin — единая логика управления Hysteria2 + NaiveProxy (sing-box).

Источник правды — /etc/proxy/:
  install.env   параметры установки (домен, порты, пути к сертификатам, версии)
  secrets.env   токены и пароли (Telegram, бэкапы, stats API)
  users.json    пользователи, их пароли, статус, obfs-пароль (schema_version)

Конфиги Hysteria2 (/etc/hysteria/config.yaml) и sing-box (/opt/naiveproxy/config/config.json)
— ПРОИЗВОДНЫЕ артефакты: `proxy-admin apply` рендерит их из состояния, валидирует
(sing-box check) и перезапускает только то, что изменилось. Аутентификация Hysteria2
идёт через proxy_authd (auth.type=http), поэтому операции с HY2-пользователями
не требуют рестарта; sing-box перезапускается только при изменении списка naive-пользователей.

Этим модулем пользуются: install.sh (init/apply/links), restore.sh, systemd-таймеры
(watchdog/backup), Telegram-бот (все команды). Никакого дублирования логики.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import secrets
import shutil
import socket
import string
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

__version__ = "3.0.0"
SCHEMA_VERSION = 1

NAME_RE = re.compile(r"^[a-z0-9_-]{1,32}$")
PASS_ALPHABET = string.ascii_letters + string.digits


# ──────────────────────────────────────────────────────────────────────
# Пути и параметры (переопределяются переменными окружения — для тестов)
# ──────────────────────────────────────────────────────────────────────
@dataclass
class Paths:
    state_dir: Path = field(default_factory=lambda: Path(os.environ.get("PROXY_STATE_DIR", "/etc/proxy")))
    hy2_config: Path = field(default_factory=lambda: Path(os.environ.get("PROXY_HY2_CONFIG", "/etc/hysteria/config.yaml")))
    naive_dir: Path = field(default_factory=lambda: Path(os.environ.get("PROXY_NAIVE_DIR", "/opt/naiveproxy")))
    backup_dir: Path = field(default_factory=lambda: Path(os.environ.get("PROXY_BACKUP_DIR", "/var/backups/proxy")))
    log_dir: Path = field(default_factory=lambda: Path(os.environ.get("PROXY_LOG_DIR", "/var/log/proxy")))
    run_dir: Path = field(default_factory=lambda: Path(os.environ.get("PROXY_RUN_DIR", "/var/lib/proxy")))
    nft_file: Path = field(default_factory=lambda: Path(os.environ.get("PROXY_NFT_FILE", "/etc/nftables.d/proxy.nft")))

    @property
    def install_env(self) -> Path: return self.state_dir / "install.env"
    @property
    def secrets_env(self) -> Path: return self.state_dir / "secrets.env"
    @property
    def users_json(self) -> Path: return self.state_dir / "users.json"
    @property
    def cert_dir(self) -> Path: return self.state_dir / "certs"
    @property
    def naive_config(self) -> Path: return self.naive_dir / "config" / "config.json"


def parse_env_file(path: Path) -> dict[str, str]:
    """KEY=VALUE без выполнения кода; кавычки по краям снимаются; # — комментарий."""
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip() if not raw.strip().startswith("#") else ""
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        if re.fullmatch(r"[A-Z_][A-Z0-9_]*", k):
            out[k] = v
    return out


class Config:
    """install.env + secrets.env с значениями по умолчанию."""

    def __init__(self, paths: Paths):
        self.paths = paths
        env = parse_env_file(paths.install_env)
        env.update(parse_env_file(paths.secrets_env))
        self.env = env
        self.domain = env.get("SERVER_DOMAIN", "")
        self.server_ip = env.get("SERVER_IP", "")
        self.main_port = int(env.get("MAIN_PORT", 443))
        self.hop_start = int(env.get("HOP_START", 20000))
        self.hop_end = int(env.get("HOP_END", 50000))
        self.cert_mode = env.get("CERT_MODE", "letsencrypt")
        self.obfs = env.get("HY2_OBFS", "yes") == "yes"
        self.up_mbps = int(env.get("HY2_UP_MBPS", 100))
        self.down_mbps = int(env.get("HY2_DOWN_MBPS", 200))
        self.authd_port = int(env.get("AUTHD_PORT", 9911))
        self.stats_port = int(env.get("STATS_PORT", 9912))
        self.stats_secret = env.get("HY2_STATS_SECRET", "")
        self.singbox_image = env.get("SINGBOX_IMAGE", "ghcr.io/sagernet/sing-box:latest")
        self.tg_token = env.get("TG_TOKEN", "")
        self.tg_chat_id = env.get("TG_CHAT_ID", "")
        self.tg_admin_ids = [int(x) for x in env.get("TG_ADMIN_IDS", "").split(",") if x.strip().isdigit()]
        self.backup_passphrase = env.get("BACKUP_PASSPHRASE", "")
        self.backup_keep = int(env.get("BACKUP_KEEP", 7))

    @property
    def insecure(self) -> bool:
        return self.cert_mode == "selfsigned"


# ──────────────────────────────────────────────────────────────────────
# Состояние пользователей (users.json) с файловой блокировкой
# ──────────────────────────────────────────────────────────────────────
def gen_password(length: int = 32) -> str:
    return "".join(secrets.choice(PASS_ALPHABET) for _ in range(length))


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def validate_name(name: str) -> str:
    if not NAME_RE.fullmatch(name):
        raise SystemExit(f"Недопустимое имя '{name}': разрешены [a-z0-9_-], 1–32 символа")
    return name


def empty_state() -> dict[str, Any]:
    return {"schema_version": SCHEMA_VERSION, "obfs_password": gen_password(), "users": {}}


def new_user(note: str = "") -> dict[str, Any]:
    return {
        "hy2_password": gen_password(),
        "naive_password": gen_password(),
        "enabled": True,
        "created_at": now_iso(),
        "rotated_at": None,
        "note": note,
    }


class State:
    """Контекстный менеджер: with State(paths) as st: ... st.save()."""

    def __init__(self, paths: Paths, write: bool = False):
        self.paths = paths
        self.write = write
        self.data: dict[str, Any] = {}
        self._lock = None

    def __enter__(self) -> State:
        p = self.paths.users_json
        if self.write:
            p.parent.mkdir(parents=True, exist_ok=True)
            self._lock = open(p.parent / ".users.lock", "a+")
            fcntl.flock(self._lock, fcntl.LOCK_EX)
        if p.exists():
            self.data = json.loads(p.read_text(encoding="utf-8"))
            self._migrate()
        else:
            self.data = empty_state()
        return self

    def __exit__(self, *exc) -> None:
        if self._lock:
            fcntl.flock(self._lock, fcntl.LOCK_UN)
            self._lock.close()

    def _migrate(self) -> None:
        v = int(self.data.get("schema_version", 0))
        if v > SCHEMA_VERSION:
            raise SystemExit(f"users.json schema_version={v} новее поддерживаемой {SCHEMA_VERSION}")
        # Здесь будут явные шаги миграции v→v+1 (п.5 рекомендаций); пока схема одна.
        self.data["schema_version"] = SCHEMA_VERSION
        self.data.setdefault("obfs_password", gen_password())
        self.data.setdefault("users", {})

    @property
    def users(self) -> dict[str, dict[str, Any]]:
        return self.data["users"]

    def save(self) -> None:
        assert self.write, "State открыт только для чтения"
        p = self.paths.users_json
        tmp = p.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(self.data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        os.chmod(tmp, 0o640)
        try:
            import grp
            gid = grp.getgrnam("proxyadmin").gr_gid
            os.chown(tmp, 0, gid)
        except (KeyError, PermissionError):
            pass
        os.replace(tmp, p)


# ──────────────────────────────────────────────────────────────────────
# Рендер конфигов
# ──────────────────────────────────────────────────────────────────────
def render_hysteria(cfg: Config, state: dict[str, Any], paths: Paths) -> str:
    doc: dict[str, Any] = {
        "listen": f":{cfg.main_port}",
        "tls": {
            "cert": str(paths.cert_dir / "fullchain.pem"),
            "key": str(paths.cert_dir / "privkey.pem"),
        },
        "auth": {
            "type": "http",
            "http": {"url": f"http://127.0.0.1:{cfg.authd_port}/auth", "insecure": False},
        },
        "bandwidth": {"up": f"{cfg.up_mbps} mbps", "down": f"{cfg.down_mbps} mbps"},
        "trafficStats": {"listen": f"127.0.0.1:{cfg.stats_port}", "secret": cfg.stats_secret},
    }
    if cfg.obfs:
        # Модель угроз: стойкость к сигнатурному DPI. Masquerade при obfs бесполезен (п.22).
        doc["obfs"] = {"type": "salamander", "salamander": {"password": state["obfs_password"]}}
    else:
        # Чистый QUIC: отвечаем на пробинг как обычный HTTP/3-сервер
        doc["masquerade"] = {"type": "string", "string": {"content": "404 page not found", "statusCode": 404}}
    header = "# /etc/hysteria/config.yaml — генерируется `proxy-admin apply`, не редактировать вручную.\n"
    return header + yaml.safe_dump(doc, sort_keys=False, allow_unicode=True)


def render_singbox(cfg: Config, state: dict[str, Any]) -> str:
    users = [
        {"username": name, "password": u["naive_password"]}
        for name, u in sorted(state["users"].items())
        if u.get("enabled", True)
    ]
    doc = {
        "log": {"level": "info", "timestamp": True},
        "inbounds": [
            {
                "type": "naive",
                "tag": "naive-in",
                "listen": "::",
                "listen_port": cfg.main_port,
                "users": users,
                "tls": {
                    "enabled": True,
                    "server_name": cfg.domain,
                    "certificate_path": "/etc/proxy/certs/fullchain.pem",
                    "key_path": "/etc/proxy/certs/privkey.pem",
                },
            }
        ],
        "outbounds": [{"type": "direct", "tag": "direct"}],
    }
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


def validate_hysteria_yaml(text: str) -> None:
    doc = yaml.safe_load(text)
    for key in ("listen", "tls", "auth"):
        if key not in doc:
            raise ValueError(f"hysteria config: нет обязательного ключа '{key}'")
    for f in (doc["tls"]["cert"], doc["tls"]["key"]):
        if not Path(f).exists():
            raise ValueError(f"hysteria config: файл сертификата не найден: {f}")


def validate_singbox(cfg: Config, config_path: Path) -> None:
    """`sing-box check` в том же образе, что и продакшен. Сертификаты в проверке не нужны."""
    if not shutil.which("docker"):
        json.loads(config_path.read_text())  # без docker — хотя бы синтаксис
        return
    r = subprocess.run(
        ["docker", "run", "--rm", "--network", "none",
         "-v", f"{config_path.parent}:/etc/sing-box:ro",
         "-v", f"{cfg.paths.cert_dir}:/etc/proxy/certs:ro",
         cfg.singbox_image, "check", "-c", f"/etc/sing-box/{config_path.name}"],
        capture_output=True, text=True, timeout=120,
    )
    if r.returncode != 0:
        raise ValueError(f"sing-box check не прошёл:\n{r.stderr.strip() or r.stdout.strip()}")


def atomic_write(path: Path, text: str, mode: int, group: str | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, mode)
    if group:
        try:
            import grp
            os.chown(tmp, 0, grp.getgrnam(group).gr_gid)
        except (KeyError, PermissionError):
            pass
    if path.exists():
        shutil.copy2(path, path.with_name(path.name + ".prev"))
    os.replace(tmp, path)


# ──────────────────────────────────────────────────────────────────────
# Управление сервисами
# ──────────────────────────────────────────────────────────────────────
def sh(cmd: list[str], check: bool = False, timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=check)


def unit_active(unit: str) -> bool:
    return sh(["systemctl", "is-active", "--quiet", unit]).returncode == 0


def container_state(name: str = "naiveproxy") -> dict[str, Any]:
    r = sh(["docker", "inspect", "-f", "{{.State.Status}} {{.RestartCount}} {{.State.StartedAt}}", name])
    if r.returncode != 0:
        return {"status": "absent", "restarts": 0, "started_at": ""}
    status, restarts, started = r.stdout.split()
    return {"status": status, "restarts": int(restarts), "started_at": started}


def tcp_open(host: str, port: int, timeout: float = 3.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def restart_hysteria_with_rollback(paths: Paths) -> None:
    sh(["systemctl", "restart", "hysteria-server"])
    time.sleep(3)
    if unit_active("hysteria-server"):
        return
    prev = paths.hy2_config.with_name(paths.hy2_config.name + ".prev")
    if prev.exists():
        shutil.copy2(prev, paths.hy2_config)
        sh(["systemctl", "restart", "hysteria-server"])
        raise SystemExit("hysteria-server не поднялся с новым конфигом — откатил на предыдущий. journalctl -xeu hysteria-server")
    raise SystemExit("hysteria-server не поднялся: journalctl -xeu hysteria-server")


def restart_naive(paths: Paths, recreate: bool = False) -> None:
    if not shutil.which("docker"):
        return
    def compose_up(*extra: str) -> None:
        subprocess.run(["docker", "compose", "up", "-d", "--remove-orphans", *extra],
                       cwd=paths.naive_dir, capture_output=True, text=True, timeout=180)

    if recreate:
        compose_up("--force-recreate")
    elif sh(["docker", "restart", "naiveproxy"], timeout=90).returncode != 0:
        compose_up()
    for _ in range(10):
        if container_state()["status"] == "running":
            return
        time.sleep(1)
    raise SystemExit("naiveproxy не запустился: docker logs naiveproxy")


def apply(cfg: Config, paths: Paths, force_restart: bool = False, only: str | None = None) -> dict[str, Any]:
    """Рендер → валидация → запись → рестарт только изменившегося. Возвращает отчёт."""
    with State(paths) as st:
        state = st.data
    report = {"hysteria": "unchanged", "naiveproxy": "unchanged"}

    if only in (None, "hysteria"):
        text = render_hysteria(cfg, state, paths)
        validate_hysteria_yaml(text)
        changed = not paths.hy2_config.exists() or paths.hy2_config.read_text() != text
        if changed:
            atomic_write(paths.hy2_config, text, 0o640, group="hysteria")
        if changed or force_restart:
            restart_hysteria_with_rollback(paths)
            report["hysteria"] = "restarted"
        elif not unit_active("hysteria-server"):
            restart_hysteria_with_rollback(paths)
            report["hysteria"] = "started"

    if only in (None, "naiveproxy"):
        text = render_singbox(cfg, state)
        candidate = paths.naive_config.with_name("config.candidate.json")
        candidate.parent.mkdir(parents=True, exist_ok=True)
        candidate.write_text(text, encoding="utf-8")
        os.chmod(candidate, 0o640)
        try:
            validate_singbox(cfg, candidate)
        finally:
            candidate.unlink(missing_ok=True)
        changed = not paths.naive_config.exists() or paths.naive_config.read_text() != text
        if changed:
            atomic_write(paths.naive_config, text, 0o640)
        if changed or force_restart:
            restart_naive(paths, recreate=force_restart)
            report["naiveproxy"] = "restarted"
        elif container_state()["status"] != "running":
            restart_naive(paths, recreate=True)
            report["naiveproxy"] = "started"
    return report


# ──────────────────────────────────────────────────────────────────────
# Ссылки и QR
# ──────────────────────────────────────────────────────────────────────
def hy2_link(cfg: Config, name: str, user: dict[str, Any], obfs_password: str) -> str:
    q = urllib.parse.quote
    params = [("sni", cfg.domain), ("insecure", "1" if cfg.insecure else "0"),
              ("mport", f"{cfg.hop_start}-{cfg.hop_end}")]
    if cfg.obfs:
        params += [("obfs", "salamander"), ("obfs-password", obfs_password)]
    query = "&".join(f"{k}={q(v, safe='-')}" for k, v in params)
    return f"hysteria2://{q(name)}:{q(user['hy2_password'])}@{cfg.domain}:{cfg.main_port}/?{query}#{q(name)}-HY2"


def naive_link(cfg: Config, name: str, user: dict[str, Any]) -> str:
    q = urllib.parse.quote
    return f"naive+https://{q(name)}:{q(user['naive_password'])}@{cfg.domain}:{cfg.main_port}#{q(name)}-Naive"


def links_for(cfg: Config, state: dict[str, Any], name: str) -> dict[str, Any]:
    validate_name(name)
    user = state["users"].get(name)
    if not user:
        raise SystemExit(f"Пользователь '{name}' не найден")
    return {
        "name": name,
        "enabled": user.get("enabled", True),
        "hysteria2": hy2_link(cfg, name, user, state["obfs_password"]),
        "hysteria2_client_yaml": {
            "server": f"{cfg.domain}:{cfg.main_port},{cfg.hop_start}-{cfg.hop_end}",
            "auth": f"{name}:{user['hy2_password']}",
            **({"obfs": {"type": "salamander", "salamander": {"password": state['obfs_password']}}} if cfg.obfs else {}),
            "tls": {"sni": cfg.domain, "insecure": cfg.insecure},
        },
        "naiveproxy": naive_link(cfg, name, user),
        "notes": (
            f"Port hopping — клиентская функция Hysteria2: клиент сам перебирает порты "
            f"{cfg.hop_start}-{cfg.hop_end} (mport в ссылке / диапазон в server:). "
            f"NaiveProxy — обычный TCP/TLS на порту {cfg.main_port}, port hopping к нему неприменим."
        ),
    }


def make_qr(link: str, out: Path) -> None:
    if not shutil.which("qrencode"):
        raise SystemExit("qrencode не установлен")
    sh(["qrencode", "-o", str(out), "-s", "8", "-m", "2", link], check=True)


# ──────────────────────────────────────────────────────────────────────
# Telegram-уведомления (с проверкой ответа и журналом недоставленных)
# ──────────────────────────────────────────────────────────────────────
def tg_api(cfg: Config, paths: Paths, method: str, data: dict[str, Any], file: tuple[str, Path] | None = None) -> bool:
    if not cfg.tg_token or not cfg.tg_chat_id:
        return False
    url = f"https://api.telegram.org/bot{cfg.tg_token}/{method}"
    try:
        if file is None:
            body = urllib.parse.urlencode(data).encode()
            req = urllib.request.Request(url, data=body)
        else:
            boundary = "----proxyadmin" + secrets.token_hex(8)
            parts = []
            for k, v in data.items():
                parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
            field_name, fpath = file
            parts.append((f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field_name}\"; "
                          f"filename=\"{fpath.name}\"\r\nContent-Type: application/octet-stream\r\n\r\n").encode())
            parts.append(fpath.read_bytes() + b"\r\n")
            parts.append(f"--{boundary}--\r\n".encode())
            req = urllib.request.Request(url, data=b"".join(parts),
                                         headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            ok = json.loads(resp.read().decode()).get("ok", False)
            if not ok:
                raise RuntimeError("telegram: ok=false")
            return True
    except (urllib.error.URLError, RuntimeError, OSError, ValueError) as e:
        paths.log_dir.mkdir(parents=True, exist_ok=True)
        with open(paths.log_dir / "undelivered-alerts.log", "a", encoding="utf-8") as f:
            f.write(f"{now_iso()} {method} FAILED ({e}): {data.get('text') or data.get('caption')}\n")
        print(f"telegram: доставка не удалась ({e}); записано в {paths.log_dir}/undelivered-alerts.log", file=sys.stderr)
        return False


def notify(cfg: Config, paths: Paths, text: str) -> bool:
    return tg_api(cfg, paths, "sendMessage", {"chat_id": cfg.tg_chat_id, "parse_mode": "HTML", "text": text})


# ──────────────────────────────────────────────────────────────────────
# Статус / watchdog / backup
# ──────────────────────────────────────────────────────────────────────
def hy2_online(cfg: Config) -> dict[str, int] | None:
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{cfg.stats_port}/online",
                                     headers={"Authorization": cfg.stats_secret})
        with urllib.request.urlopen(req, timeout=3) as r:
            return json.loads(r.read().decode() or "{}")
    except (urllib.error.URLError, OSError, ValueError):
        return None


def authd_healthy(cfg: Config) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{cfg.authd_port}/healthz", timeout=3) as r:
            return r.status == 200
    except (urllib.error.URLError, OSError):
        return False


def status(cfg: Config, paths: Paths) -> dict[str, Any]:
    c = container_state()
    with State(paths) as st:
        users = st.users
    online = hy2_online(cfg)
    disk = shutil.disk_usage("/")
    mem_total = mem_avail = 0
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                mem_total = int(line.split()[1]) // 1024
            elif line.startswith("MemAvailable:"):
                mem_avail = int(line.split()[1]) // 1024
    except OSError:
        pass
    return {
        "host": socket.gethostname(),
        "domain": cfg.domain,
        "ip": cfg.server_ip,
        "hysteria": {"active": unit_active("hysteria-server"), "online": online,
                     "port_open": tcp_open("127.0.0.1", cfg.main_port)},
        "naiveproxy": {"status": c["status"], "restarts": c["restarts"]},
        "authd": {"healthy": authd_healthy(cfg)},
        "bot": {"active": unit_active("proxy-bot")} if cfg.tg_token else None,
        "fail2ban": {"active": unit_active("fail2ban")},
        "nftables": {"table_loaded": sh(["nft", "list", "table", "inet", "proxy"]).returncode == 0},
        "users": {"total": len(users), "enabled": sum(1 for u in users.values() if u.get("enabled", True))},
        "disk": {"used_gb": round((disk.total - disk.free) / 2**30, 1), "total_gb": round(disk.total / 2**30, 1)},
        "mem": {"available_mb": mem_avail, "total_mb": mem_total},
        "uptime": sh(["uptime", "-p"]).stdout.strip(),
    }


def format_status(s: dict[str, Any]) -> str:
    def dot(ok: bool) -> str: return "🟢" if ok else "🔴"
    hy = s["hysteria"]
    nv = s["naiveproxy"]
    online = hy["online"]
    online_txt = f", онлайн: {sum(online.values())}" if isinstance(online, dict) else ""
    lines = [
        f"📊 <b>{s['host']}</b> — {s['domain']} ({s['ip']})",
        f"⏱ {s['uptime']}",
        f"💾 Диск: {s['disk']['used_gb']}/{s['disk']['total_gb']} ГБ   🧠 RAM свободно: {s['mem']['available_mb']}/{s['mem']['total_mb']} МБ",
        "",
        f"{dot(hy['active'] and hy['port_open'])} Hysteria2: {'active' if hy['active'] else 'inactive'}{online_txt}",
        f"{dot(nv['status'] == 'running')} NaiveProxy: {nv['status']} (рестартов: {nv['restarts']})",
        f"{dot(s['authd']['healthy'])} proxy-authd: {'ok' if s['authd']['healthy'] else 'недоступен'}",
        f"{dot(s['nftables']['table_loaded'])} nftables: {'таблица inet proxy загружена' if s['nftables']['table_loaded'] else 'ТАБЛИЦА НЕ ЗАГРУЖЕНА'}",
        f"{dot(s['fail2ban']['active'])} Fail2ban: {'active' if s['fail2ban']['active'] else 'inactive'}",
    ]
    if s.get("bot"):
        lines.append(f"{dot(s['bot']['active'])} Telegram-бот: {'active' if s['bot']['active'] else 'inactive'}")
    lines.append(f"👥 Пользователи: {s['users']['enabled']} активных из {s['users']['total']}")
    return "\n".join(lines)


def watchdog(cfg: Config, paths: Paths) -> list[str]:
    """Не «жив/мёртв», а реальные проверки: порт, healthz authd, crash-loop контейнера."""
    issues: list[str] = []
    paths.run_dir.mkdir(parents=True, exist_ok=True)
    memo_path = paths.run_dir / "watchdog.json"
    memo = json.loads(memo_path.read_text()) if memo_path.exists() else {}

    if not unit_active("hysteria-server"):
        sh(["systemctl", "restart", "hysteria-server"]); time.sleep(3)
        issues.append("⚠️ Hysteria2 был неактивен — перезапущен" if unit_active("hysteria-server")
                      else "🔴 Hysteria2 не запускается! journalctl -xeu hysteria-server")
    elif not tcp_open("127.0.0.1", cfg.main_port):
        issues.append(f"🔴 Hysteria2 активна, но порт {cfg.main_port}/tcp не отвечает (NaiveProxy тоже слушает его)")

    if not authd_healthy(cfg):
        sh(["systemctl", "restart", "proxy-authd"]); time.sleep(2)
        issues.append("⚠️ proxy-authd не отвечал — перезапущен" if authd_healthy(cfg)
                      else "🔴 proxy-authd не отвечает: аутентификация Hysteria2 НЕ РАБОТАЕТ")

    c = container_state()
    if c["status"] != "running":
        restart_ok = True
        try:
            restart_naive(paths, recreate=(c["status"] == "absent"))
        except SystemExit:
            restart_ok = False
        issues.append(f"⚠️ NaiveProxy был {c['status']} — перезапущен" if restart_ok
                      else f"🔴 NaiveProxy ({c['status']}) не запускается: docker logs naiveproxy")
    else:
        prev = memo.get("naive_restarts", c["restarts"])
        if c["restarts"] > prev:
            issues.append(f"🔴 NaiveProxy перезапускался {c['restarts'] - prev} раз за последние 5 минут (crash-loop?): docker logs naiveproxy")
    memo["naive_restarts"] = c["restarts"]

    if sh(["nft", "list", "table", "inet", "proxy"]).returncode != 0 and paths.nft_file.exists():
        r = sh(["nft", "-f", str(paths.nft_file)])
        issues.append("⚠️ Таблица nftables inet proxy отсутствовала — переприменена" if r.returncode == 0
                      else "🔴 Таблица nftables inet proxy отсутствует и не применяется: " + r.stderr.strip())

    memo["last_run"] = now_iso()
    memo_path.write_text(json.dumps(memo))
    if issues:
        notify(cfg, paths, f"🖥 <b>{socket.gethostname()}</b> — watchdog:\n" + "\n".join(issues))
    return issues


def backup(cfg: Config, paths: Paths, send: bool = True) -> Path:
    paths.backup_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(paths.backup_dir, 0o700)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    tar_path = paths.backup_dir / f"proxy-backup-{stamp}.tar.gz"
    members = [paths.state_dir, paths.nft_file, Path("/etc/fail2ban/jail.local"),
               paths.hy2_config, paths.naive_config, paths.naive_dir / "docker-compose.yml"]
    with tarfile.open(tar_path, "w:gz") as tar:
        for m in members:
            if m.exists():
                tar.add(m, arcname=str(m).lstrip("/"))
    os.chmod(tar_path, 0o600)
    out = tar_path
    if cfg.backup_passphrase and shutil.which("gpg"):
        enc = tar_path.with_suffix(".gz.gpg")
        r = subprocess.run(["gpg", "--batch", "--yes", "--symmetric", "--cipher-algo", "AES256",
                            "--passphrase-fd", "0", "-o", str(enc), str(tar_path)],
                           input=cfg.backup_passphrase, capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            raise SystemExit("gpg не смог зашифровать бэкап: " + r.stderr.strip())
        tar_path.unlink()
        os.chmod(enc, 0o600)
        out = enc
    else:
        print("ВНИМАНИЕ: BACKUP_PASSPHRASE не задан или нет gpg — бэкап НЕ зашифрован, в Telegram не отправляю",
              file=sys.stderr)
        send = False
    # Ротация: оставляем последние N локально (п.12)
    files = sorted(paths.backup_dir.glob("proxy-backup-*"), key=lambda p: p.stat().st_mtime)
    for old in files[:-cfg.backup_keep] if cfg.backup_keep > 0 else []:
        old.unlink()
    if send:
        tg_api(cfg, paths, "sendDocument",
               {"chat_id": cfg.tg_chat_id,
                "caption": f"🗄 Бэкап {socket.gethostname()} — {datetime.now():%d.%m.%Y %H:%M} (AES256, пароль в secrets.env)"},
               file=("document", out))
    return out


# ──────────────────────────────────────────────────────────────────────
# CLI
# ──────────────────────────────────────────────────────────────────────
def out(args: argparse.Namespace, data: Any, text: str | None = None) -> None:
    if getattr(args, "json", False):
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print(text if text is not None else json.dumps(data, ensure_ascii=False, indent=2))


def format_links(l: dict[str, Any]) -> str:
    y = l["hysteria2_client_yaml"]
    return (
        f"👤 {l['name']} ({'активен' if l['enabled'] else 'ОТКЛЮЧЁН'})\n\n"
        f"🔵 Hysteria2 (URI, port hopping через mport):\n{l['hysteria2']}\n\n"
        f"🔵 Hysteria2 (client.yaml):\n{yaml.safe_dump(y, sort_keys=False).rstrip()}\n\n"
        f"🟠 NaiveProxy:\n{l['naiveproxy']}\n\n"
        f"ℹ️ {l['notes']}"
    )


def main(argv: list[str] | None = None) -> int:
    try:
        return _main(argv)
    except ValueError as e:          # ошибки валидации конфигов — без traceback
        raise SystemExit(f"✗ {e}") from None


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="proxy-admin", description=__doc__.split("\n\n")[0])
    ap.add_argument("--version", action="version", version=f"proxy-admin {__version__}")
    ap.add_argument("--json", action="store_true", help="машиночитаемый вывод")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("init", help="создать users.json с первым пользователем"); p.add_argument("--first-user", default="admin")
    sub.add_parser("migrate", help="привести users.json к текущей схеме")
    sub.add_parser("list", help="список пользователей")
    p = sub.add_parser("add", help="добавить пользователя"); p.add_argument("name"); p.add_argument("--note", default="")
    p.add_argument("--no-apply", action="store_true", help="не применять конфиги (батч)")
    for c in ("del", "enable", "disable"):
        p = sub.add_parser(c); p.add_argument("name"); p.add_argument("--no-apply", action="store_true")
    p = sub.add_parser("rotate", help="ротация паролей"); p.add_argument("name", nargs="?")
    p.add_argument("--all", action="store_true"); p.add_argument("--no-apply", action="store_true")
    p = sub.add_parser("links", help="ссылки для пользователя"); p.add_argument("name")
    p = sub.add_parser("qr", help="QR-коды в PNG"); p.add_argument("name"); p.add_argument("--out", required=True)
    p = sub.add_parser("render", help="напечатать сгенерированные конфиги"); p.add_argument("what", choices=["hysteria", "singbox"])
    p = sub.add_parser("apply", help="рендер+валидация+рестарт изменившегося")
    p.add_argument("--restart", action="store_true", help="перезапустить оба сервиса в любом случае")
    p.add_argument("--only", choices=["hysteria", "naiveproxy"])
    sub.add_parser("check", help="валидация конфигов без записи")
    sub.add_parser("status")
    sub.add_parser("watchdog")
    p = sub.add_parser("backup"); p.add_argument("--no-send", action="store_true")
    p = sub.add_parser("notify"); p.add_argument("text")
    sub.add_parser("restart", help="перезапустить hysteria и naiveproxy")

    args = ap.parse_args(argv)
    paths = Paths()
    cfg = Config(paths)

    def do_apply(only: str | None = None) -> dict[str, Any]:
        if getattr(args, "no_apply", False):
            return {"applied": False}
        return apply(cfg, paths, only=only)

    if args.cmd == "init":
        name = validate_name(args.first_user)
        if paths.users_json.exists():
            raise SystemExit(f"{paths.users_json} уже существует — init отменён (используйте add)")
        with State(paths, write=True) as st:
            st.users[name] = new_user("первый пользователь, создан установщиком")
            st.save()
        out(args, {"created": name}, f"users.json создан, пользователь {name}")

    elif args.cmd == "migrate":
        with State(paths, write=True) as st:
            st.save()
        out(args, {"schema_version": SCHEMA_VERSION}, "ok")

    elif args.cmd == "list":
        with State(paths) as st:
            users = {n: {"enabled": u.get("enabled", True), "created_at": u.get("created_at"),
                         "rotated_at": u.get("rotated_at"), "note": u.get("note", "")}
                     for n, u in sorted(st.users.items())}
        text = "\n".join(f"{'🟢' if u['enabled'] else '🔴'} {n}" + (f"  — {u['note']}" if u["note"] else "")
                         for n, u in users.items()) or "(пусто)"
        out(args, {"users": users}, text)

    elif args.cmd == "add":
        name = validate_name(args.name)
        with State(paths, write=True) as st:
            if name in st.users:
                raise SystemExit(f"Пользователь '{name}' уже существует")
            st.users[name] = new_user(args.note)
            st.save()
            links = links_for(cfg, st.data, name)
        rep = do_apply("naiveproxy")   # HY2 — через authd, рестарт не нужен
        out(args, {"added": name, "links": links, "apply": rep}, f"✅ Пользователь {name} добавлен\n\n" + format_links(links))

    elif args.cmd in ("del", "enable", "disable"):
        name = validate_name(args.name)
        with State(paths, write=True) as st:
            if name not in st.users:
                raise SystemExit(f"Пользователь '{name}' не найден")
            if args.cmd == "del":
                del st.users[name]
            else:
                st.users[name]["enabled"] = args.cmd == "enable"
            st.save()
        rep = do_apply("naiveproxy")
        verb = {"del": "удалён", "enable": "включён", "disable": "отключён"}[args.cmd]
        out(args, {args.cmd: name, "apply": rep}, f"{'🗑' if args.cmd == 'del' else '🟢' if args.cmd == 'enable' else '🔴'} Пользователь {name} {verb}")

    elif args.cmd == "rotate":
        if not args.all and not args.name:
            raise SystemExit("Укажите имя пользователя или --all")
        with State(paths, write=True) as st:
            targets = list(st.users) if args.all else [validate_name(args.name)]
            for n in targets:
                if n not in st.users:
                    raise SystemExit(f"Пользователь '{n}' не найден")
                st.users[n]["hy2_password"] = gen_password()
                st.users[n]["naive_password"] = gen_password()
                st.users[n]["rotated_at"] = now_iso()
            st.save()
            all_links = {n: links_for(cfg, st.data, n) for n in targets}
        rep = do_apply("naiveproxy")
        out(args, {"rotated": targets, "links": all_links, "apply": rep},
            f"🔄 Пароли обновлены: {', '.join(targets)}. Новые ссылки: /links <имя>")

    elif args.cmd == "links":
        with State(paths) as st:
            l = links_for(cfg, st.data, args.name)
        out(args, l, format_links(l))

    elif args.cmd == "qr":
        with State(paths) as st:
            l = links_for(cfg, st.data, args.name)
        outdir = Path(args.out); outdir.mkdir(parents=True, exist_ok=True)
        files = {}
        for key in ("hysteria2", "naiveproxy"):
            f = outdir / f"{l['name']}-{key}.png"
            make_qr(l[key], f)
            files[key] = str(f)
        out(args, {"files": files, "links": l}, "\n".join(files.values()))

    elif args.cmd == "render":
        with State(paths) as st:
            print(render_hysteria(cfg, st.data, paths) if args.what == "hysteria" else render_singbox(cfg, st.data), end="")

    elif args.cmd == "check":
        with State(paths) as st:
            validate_hysteria_yaml(render_hysteria(cfg, st.data, paths))
            with tempfile.TemporaryDirectory() as d:
                cand = Path(d) / "config.json"; cand.write_text(render_singbox(cfg, st.data)); os.chmod(d, 0o755)
                validate_singbox(cfg, cand)
        out(args, {"ok": True}, "✓ Конфиги валидны")

    elif args.cmd == "apply":
        rep = apply(cfg, paths, force_restart=args.restart, only=args.only)
        out(args, rep, f"hysteria: {rep['hysteria']}, naiveproxy: {rep['naiveproxy']}")

    elif args.cmd == "restart":
        rep = apply(cfg, paths, force_restart=True)
        out(args, rep, "🔁 Сервисы перезапущены")

    elif args.cmd == "status":
        s = status(cfg, paths)
        out(args, s, format_status(s))

    elif args.cmd == "watchdog":
        issues = watchdog(cfg, paths)
        out(args, {"issues": issues}, "\n".join(issues) if issues else "ok")

    elif args.cmd == "backup":
        f = backup(cfg, paths, send=not args.no_send)
        out(args, {"file": str(f)}, f"📦 {f}")

    elif args.cmd == "notify":
        ok = notify(cfg, paths, args.text)
        out(args, {"sent": ok}, "sent" if ok else "not sent")
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
