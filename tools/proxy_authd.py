#!/usr/bin/env python3
"""proxy-authd — HTTP-бэкенд аутентификации для Hysteria2 (auth.type: http).

Hysteria2 при каждом подключении делает POST /auth с JSON {"addr": "ip:port", "auth": "...", "tx": N}
и ожидает {"ok": true/false, "id": "<идентификатор клиента>"}. Мы сверяем auth вида
`user:password` с /etc/proxy/users.json (перечитывается при изменении mtime).

Зачем: добавление/отключение/ротация пользователей Hysteria2 вступает в силу мгновенно,
без рестарта сервера и обрыва чужих сессий (п.17). Неудачные попытки логируются строкой
`auth failed ip=<ip> port=<port> user=<name> reason=<...>` — это источник событий для
jail [hysteria2] в Fail2ban (п.21).

Только stdlib: никаких зависимостей, слушает 127.0.0.1, работает от пользователя proxyadmin.
"""
from __future__ import annotations

import hmac
import json
import logging
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from proxy_admin import Config, Paths  # noqa: E402

log = logging.getLogger("proxy-authd")
logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stdout)


class UserStore:
    """users.json с кэшем по mtime; потокобезопасно."""

    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.Lock()
        self._mtime = -1.0
        self._users: dict[str, str] = {}

    def _reload_if_needed(self) -> None:
        try:
            mtime = self.path.stat().st_mtime
        except FileNotFoundError:
            self._users, self._mtime = {}, -1.0
            return
        if mtime == self._mtime:
            return
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            self._users = {n: u["hy2_password"] for n, u in data.get("users", {}).items() if u.get("enabled", True)}
            self._mtime = mtime
            log.info("users.json reloaded: %d enabled users", len(self._users))
        except (OSError, ValueError, KeyError) as e:
            log.error("users.json unreadable, keeping previous set: %s", e)

    def check(self, auth: str) -> tuple[bool, str, str]:
        """→ (ok, user, reason)"""
        with self._lock:
            self._reload_if_needed()
            users = dict(self._users)
        if ":" not in auth:
            return False, "", "no-username"
        name, password = auth.split(":", 1)
        expected = users.get(name)
        if expected is None:
            return False, name, "unknown-or-disabled"
        if not hmac.compare_digest(expected.encode(), password.encode()):
            return False, name, "bad-password"
        return True, name, "ok"


def split_addr(addr: str) -> tuple[str, str]:
    if addr.startswith("["):                      # [ipv6]:port
        host, _, port = addr[1:].partition("]:")
        return host, port
    host, _, port = addr.rpartition(":")
    return (host or addr), port


def make_handler(store: UserStore):
    class Handler(BaseHTTPRequestHandler):
        server_version = "proxy-authd/3.0"

        def log_message(self, *_):  # тихий access-log; пишем только auth-события
            pass

        def _json(self, code: int, body: dict) -> None:
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/healthz":
                self._json(200, {"ok": True})
            else:
                self._json(404, {"ok": False})

        def do_POST(self):
            if self.path != "/auth":
                self._json(404, {"ok": False})
                return
            length = int(self.headers.get("Content-Length") or 0)
            try:
                req = json.loads(self.rfile.read(min(length, 65536)) or b"{}")
            except ValueError:
                self._json(400, {"ok": False})
                return
            addr = str(req.get("addr", ""))
            ip, port = split_addr(addr)
            ok, user, reason = store.check(str(req.get("auth", "")))
            if ok:
                log.info("auth ok ip=%s user=%s", ip, user)
                self._json(200, {"ok": True, "id": user})
            else:
                log.warning("auth failed ip=%s port=%s user=%s reason=%s", ip, port, user or "-", reason)
                self._json(200, {"ok": False, "id": ""})

    return Handler


def main() -> int:
    paths = Paths()
    cfg = Config(paths)
    port = int(os.environ.get("PROXY_AUTHD_PORT", cfg.authd_port))
    store = UserStore(paths.users_json)
    srv = ThreadingHTTPServer(("127.0.0.1", port), make_handler(store))
    srv.daemon_threads = True
    log.info("proxy-authd listening on 127.0.0.1:%d, users=%s", port, paths.users_json)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
