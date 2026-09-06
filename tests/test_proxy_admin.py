"""Тесты чистой логики proxy_admin / proxy_authd — без root, сети и docker."""
from __future__ import annotations

import json
import os
import sys
import threading
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import proxy_admin as pa  # noqa: E402
import proxy_authd as authd  # noqa: E402


@pytest.fixture
def env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> pa.Paths:
    state = tmp_path / "proxy"
    state.mkdir()
    (state / "certs").mkdir()
    (state / "certs" / "fullchain.pem").write_text("cert")
    (state / "certs" / "privkey.pem").write_text("key")
    (state / "install.env").write_text(
        'SERVER_DOMAIN="proxy.example.com"\nSERVER_IP=203.0.113.5\nMAIN_PORT=443\n'
        "HOP_START=20000\nHOP_END=50000\nCERT_MODE=letsencrypt\nHY2_OBFS=yes\nAUTHD_PORT=9911\nSTATS_PORT=9912\n"
        "SINGBOX_IMAGE=ghcr.io/sagernet/sing-box:v1.13.21\n# комментарий\n"
    )
    (state / "secrets.env").write_text('HY2_STATS_SECRET="s3cret"\nTG_ADMIN_IDS="1,2"\n')
    monkeypatch.setenv("PROXY_STATE_DIR", str(state))
    monkeypatch.setenv("PROXY_HY2_CONFIG", str(tmp_path / "hysteria.yaml"))
    monkeypatch.setenv("PROXY_NAIVE_DIR", str(tmp_path / "naive"))
    monkeypatch.setenv("PROXY_LOG_DIR", str(tmp_path / "log"))
    monkeypatch.setenv("PROXY_RUN_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("PROXY_BACKUP_DIR", str(tmp_path / "backups"))
    return pa.Paths()


def run(*argv: str) -> dict:
    """Запуск CLI с --json и захватом stdout."""
    import io
    from contextlib import redirect_stdout

    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = pa.main(["--json", *argv])
    assert rc == 0
    return json.loads(buf.getvalue())


def test_parse_env_file(env: pa.Paths) -> None:
    cfg = pa.Config(env)
    assert cfg.domain == "proxy.example.com"
    assert cfg.main_port == 443 and cfg.hop_end == 50000
    assert cfg.stats_secret == "s3cret"
    assert cfg.tg_admin_ids == [1, 2]
    assert cfg.obfs is True and cfg.insecure is False


def test_name_validation() -> None:
    for bad in ("Alice", "a b", "x/y", "a'b", "", "a" * 33, "имя"):
        with pytest.raises(SystemExit):
            pa.validate_name(bad)
    assert pa.validate_name("alice_01-x") == "alice_01-x"


def test_gen_password_is_cryptographic_and_long() -> None:
    p = pa.gen_password()
    assert len(p) == 32 and p.isalnum()
    assert len({pa.gen_password() for _ in range(50)}) == 50


def test_state_lifecycle(env: pa.Paths) -> None:
    assert run("init", "--first-user", "admin")["created"] == "admin"
    with pytest.raises(SystemExit):
        run("init")  # повторный init не перезаписывает
    run("add", "bob", "--no-apply", "--note", "друг")
    with pytest.raises(SystemExit):
        run("add", "bob", "--no-apply")
    users = run("list")["users"]
    assert set(users) == {"admin", "bob"} and users["bob"]["note"] == "друг"

    run("disable", "bob", "--no-apply")
    assert run("list")["users"]["bob"]["enabled"] is False
    run("enable", "bob", "--no-apply")
    assert run("list")["users"]["bob"]["enabled"] is True

    before = pa.State(env).__enter__().users["bob"]["hy2_password"]
    run("rotate", "bob", "--no-apply")
    after = pa.State(env).__enter__().users["bob"]["hy2_password"]
    assert before != after

    run("del", "bob", "--no-apply")
    assert set(run("list")["users"]) == {"admin"}
    data = json.loads(env.users_json.read_text())
    assert data["schema_version"] == pa.SCHEMA_VERSION and "obfs_password" in data


def test_links_contain_mport_and_obfs(env: pa.Paths) -> None:
    run("init", "--first-user", "admin")
    l = run("links", "admin")
    assert l["hysteria2"].startswith("hysteria2://admin:")
    assert "@proxy.example.com:443/?" in l["hysteria2"]
    assert "mport=20000-50000" in l["hysteria2"]
    assert "obfs=salamander&obfs-password=" in l["hysteria2"]
    assert "insecure=0" in l["hysteria2"]
    assert l["hysteria2_client_yaml"]["server"] == "proxy.example.com:443,20000-50000"
    assert l["naiveproxy"].startswith("naive+https://admin:") and ":443#" in l["naiveproxy"]
    assert "hopping" not in l["naiveproxy"]


def test_links_selfsigned_sets_insecure(env: pa.Paths) -> None:
    (env.state_dir / "install.env").write_text(
        (env.state_dir / "install.env").read_text().replace("CERT_MODE=letsencrypt", "CERT_MODE=selfsigned"))
    run("init")
    assert "insecure=1" in run("links", "admin")["hysteria2"]


def test_render_hysteria_http_auth_no_masquerade_with_obfs(env: pa.Paths) -> None:
    run("init")
    cfg = pa.Config(env)
    with pa.State(env) as st:
        doc = yaml.safe_load(pa.render_hysteria(cfg, st.data, env))
    assert doc["auth"] == {"type": "http", "http": {"url": "http://127.0.0.1:9911/auth", "insecure": False}}
    assert doc["obfs"]["type"] == "salamander"
    assert "masquerade" not in doc
    assert doc["trafficStats"] == {"listen": "127.0.0.1:9912", "secret": "s3cret"}
    assert doc["tls"]["cert"] == str(env.cert_dir / "fullchain.pem")
    pa.validate_hysteria_yaml(pa.render_hysteria(cfg, st.data, env))


def test_render_singbox_excludes_disabled_and_has_no_foreign_fields(env: pa.Paths) -> None:
    run("init")
    run("add", "bob", "--no-apply")
    run("disable", "bob", "--no-apply")
    with pa.State(env) as st:
        doc = json.loads(pa.render_singbox(pa.Config(env), st.data))
    inbound = doc["inbounds"][0]
    assert inbound["type"] == "naive" and inbound["listen_port"] == 443
    assert [u["username"] for u in inbound["users"]] == ["admin"]
    assert not any(k.startswith("_") for k in inbound)  # никаких _disabled_users (п.16)
    assert inbound["tls"]["certificate_path"] == "/etc/proxy/certs/fullchain.pem"


def test_authd_checks_password_and_logs_failures(env: pa.Paths, caplog: pytest.LogCaptureFixture) -> None:
    run("init")
    run("add", "bob", "--no-apply")
    run("disable", "bob", "--no-apply")
    with pa.State(env) as st:
        admin_pw = st.users["admin"]["hy2_password"]
        bob_pw = st.users["bob"]["hy2_password"]

    store = authd.UserStore(env.users_json)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), authd.make_handler(store))
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    port = srv.server_address[1]

    def auth(payload: str, addr: str = "198.51.100.7:4242") -> dict:
        req = urllib.request.Request(f"http://127.0.0.1:{port}/auth",
                                     data=json.dumps({"addr": addr, "auth": payload, "tx": 0}).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())

    try:
        with caplog.at_level("INFO"):
            assert auth(f"admin:{admin_pw}") == {"ok": True, "id": "admin"}
            assert auth("admin:wrong")["ok"] is False
            assert auth(f"bob:{bob_pw}")["ok"] is False          # отключён → как неизвестный
            assert auth("nocolon")["ok"] is False
            assert auth(f"admin:{admin_pw}", addr="[2001:db8::1]:5")["ok"] is True
        failed = [r.message for r in caplog.records if "auth failed" in r.message]
        assert any("ip=198.51.100.7 port=4242 user=admin reason=bad-password" in m for m in failed)
        assert any("user=bob reason=unknown-or-disabled" in m for m in failed)
        assert any("reason=no-username" in m for m in failed)
        # hot reload: включаем bob — без рестарта
        run("enable", "bob", "--no-apply")
        os.utime(env.users_json, None)
        assert auth(f"bob:{bob_pw}")["ok"] is True
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=5) as r:
            assert r.status == 200
    finally:
        srv.shutdown()


def test_fail2ban_regex_matches_authd_line() -> None:
    """Регулярка из templates/fail2ban/filter-hysteria2.conf должна ловить строку authd."""
    import re

    tpl = (Path(__file__).resolve().parents[1] / "templates" / "fail2ban" / "filter-hysteria2.conf").read_text()
    regex = next(l.split("=", 1)[1].strip() for l in tpl.splitlines() if l.startswith("failregex"))
    py_regex = regex.replace("<HOST>", r"(?P<host>\S+)")
    m = re.match(py_regex, "Sep 05 12:00:00 host proxy-authd[123]: auth failed ip=203.0.113.9 port=1 user=x reason=bad-password")
    assert m and m.group("host") == "203.0.113.9"
    assert not re.match(py_regex, "auth ok ip=203.0.113.9 user=x")


def test_split_addr() -> None:
    assert authd.split_addr("1.2.3.4:55") == ("1.2.3.4", "55")
    assert authd.split_addr("[::1]:55") == ("::1", "55")


def test_migrate_v2_preserves_users(tmp_path: Path) -> None:
    """Бэкап v2 → v3: пароли, obfs, порты и статусы переносятся один в один."""
    import subprocess
    import tarfile

    hy2 = {"listen": ":443", "tls": {"cert": "/etc/letsencrypt/live/hy2.example.com/fullchain.pem",
                                     "key": "/etc/letsencrypt/live/hy2.example.com/privkey.pem"},
           "auth": {"type": "userpass", "userpass": {"admin": "A" * 32, "eva": "E" * 32}},
           "_disabled_users": {"old": "O" * 32},
           "obfs": {"type": "salamander", "salamander": {"password": "S" * 32}},
           "bandwidth": {"up": "50 mbps", "down": "150 mbps"}}
    naive = {"inbounds": [{"type": "naive", "listen_port": 443,
                           "users": [{"username": "admin", "password": "N" * 32}, {"username": "eva", "password": "V" * 32}],
                           "_disabled_users": [{"username": "old", "password": "D" * 32}]}], "outbounds": [{"type": "direct"}]}
    nft = "table inet filter { chain input { tcp dport 25000-26000 redirect to :443\ntcp dport 443 accept\ntcp dport 2222 accept } }"
    src = tmp_path / "v2.tar.gz"
    with tarfile.open(src, "w:gz") as t:
        for name, data in (("etc/hysteria/config.yaml", yaml.safe_dump(hy2)),
                           ("opt/naiveproxy/config/config.json", json.dumps(naive)), ("etc/nftables.conf", nft)):
            p = tmp_path / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(data); t.add(p, arcname=name)
    out = tmp_path / "v3.tar.gz"
    r = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / "tools" / "migrate_v2.py"),
                        str(src), "-o", str(out), "--tg-token", "1:x", "--tg-chat-id", "5"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    with tarfile.open(out) as t:
        users = json.load(t.extractfile("etc/proxy/users.json"))
        env = dict(
            line.split("=", 1) for line in t.extractfile("etc/proxy/install.env").read().decode().splitlines()
            if "=" in line and not line.startswith("#"))
        secrets = t.extractfile("etc/proxy/secrets.env").read().decode()
    assert users["obfs_password"] == "S" * 32
    assert users["users"]["admin"] == {**users["users"]["admin"], "hy2_password": "A" * 32, "naive_password": "N" * 32, "enabled": True}
    assert users["users"]["old"]["enabled"] is False and users["users"]["old"]["hy2_password"] == "O" * 32
    assert env["SERVER_DOMAIN"] == '"hy2.example.com"' and env["HOP_START"] == "25000" and env["HOP_END"] == "26000"
    assert env["SSH_PORT"] == "2222" and env["HY2_UP_MBPS"] == "50" and env["CERT_MODE"] == '"letsencrypt"'
    assert 'TG_TOKEN="1:x"' in secrets and 'TG_ADMIN_IDS="5"' in secrets
