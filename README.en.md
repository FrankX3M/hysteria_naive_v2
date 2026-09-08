# hysteria_naive v2

[![License: MIT](https://img.shields.io/github/license/FrankX3M/hysteria_naive_v2?color=blue)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/FrankX3M/hysteria_naive_v2)](https://github.com/FrankX3M/hysteria_naive_v2/commits/main)
[![CI](https://img.shields.io/github/actions/workflow/status/FrankX3M/hysteria_naive_v2/ci.yml?branch=main&label=CI)](https://github.com/FrankX3M/hysteria_naive_v2/actions/workflows/ci.yml)
[![Bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](install.sh)
[![Python 3](https://img.shields.io/badge/python-3-3776AB?logo=python&logoColor=white)](tools/)
[![Platform: Debian | Ubuntu](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-informational)](#%D1%82%D1%80%D0%B5%D0%B1%D0%BE%D0%B2%D0%B0%D0%BD%D0%B8%D1%8F)
[![Lint: ruff · shellcheck](https://img.shields.io/badge/lint-ruff%20%7C%20shellcheck-informational)](#%D1%80%D0%B0%D0%B7%D1%80%D0%B0%D0%B1%D0%BE%D1%82%D0%BA%D0%B0-%D0%B8-ci)
[![Open issues](https://img.shields.io/github/issues/FrankX3M/hysteria_naive_v2)](https://github.com/FrankX3M/hysteria_naive_v2/issues)

*[Русская версия / Russian version](README.md)*

Installer and management tools for **Hysteria2 + NaiveProxy (sing-box in Docker)** bundle with port hopping,
Telegram bot, watchdog, encrypted backups, Fail2ban and nftables firewall.

v2 — rework based on [architectural analysis](docs/ARCHITECTURE.md#what-changed-relative-to-v2):
modular installer, unified state file `/etc/proxy/`, configs as derived artifacts,
Hysteria2 authentication without restarts, services not from root, firewall with `policy drop`.

Migration from v1 — [step-by-step guide for running server](docs/RUNBOOK.md)
or [brief migration reference](docs/MIGRATION.md).

## 🚀 Quick Start (TL;DR)
 
```bash
git clone https://github.com/FrankX3M/hysteria_naive_v2.git
cd hysteria_naive_v2
sudo ./install.sh
```
 
You'll need: Debian 11/12 or Ubuntu 22.04/24.04, root access, ≥ 1 GB RAM, and a domain with an A record pointing to the server. The installer asks a few questions and deploys Hysteria2 + NaiveProxy for you.
 
Full details, non-interactive mode, and resuming after a failed step — see the [full "Quick Start" section](#quick-start) below.

## Table of Contents

- [What Gets Installed](#what-gets-installed)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Non-interactive Installation](#non-interactive-installation)
- [Repository Structure](#repository-structure)
- [Server State: /etc/proxy](#server-state-etcproxy)
- [Management: proxy-admin](#management-proxy-admin)
- [Telegram Bot](#telegram-bot)
- [Port Hopping — How It Actually Works](#port-hopping--how-it-actually-works)
- [Bridge to Second Server (chain-route-setup.sh)](#bridge-to-second-server-chain-route-setupsh)
- [Security Model](#security-model)
- [Backups and Recovery](#backups-and-recovery)
- [Updates](#updates)
- [Monitoring and Logs](#monitoring-and-logs)
- [Post-Installation Verification](#post-installation-verification)
- [Development and CI](#development-and-ci)

## What Gets Installed

| Component | How | Run As |
|---|---|---|
| Hysteria2 (`lib/versions.sh`: v2.9.2) | binary from GitHub Releases, pinned version, optional sha256 | `hysteria` (systemd, hardening) |
| NaiveProxy = sing-box (v1.13.21) | `docker compose`, `mem_limit`/`cpus`, `read_only`, `cap_drop` | container |
| nftables | dedicated table `inet proxy`, `policy drop`, NAT redirect of hopping range (IPv4+IPv6) | — |
| proxy-authd | HTTP backend for Hysteria2 authentication (`auth.type: http`) on 127.0.0.1 | `proxyadmin` |
| proxy-admin | CLI: users, links/QR, config render and validation, status, watchdog, backup | root / `proxyadmin` |
| proxy-bot (optional) | Telegram wrapper over proxy-admin, no business logic, no `shell=True` | `proxyadmin` + sudoers |
| Fail2ban (optional) | jail `sshd` + jail `hysteria2` from proxy-authd log, ban via `nftables[type=allports]` | — |
| systemd Timers | `proxy-watchdog` (5 min), `proxy-backup` (03:00), `servercleanup` (03:30, optional) | root |
| certbot (optional) | standalone on tcp/80, deploy-hook copies cert and restarts services | — |
| sysctl, swap | BBR + buffers; swap defaults to `auto` (create if missing) | — |

Grafana Alloy removed from v1: all component logs go to journald (`journalctl -u hysteria-server`,
`journalctl -t naiveproxy`, `journalctl -u proxy-authd`); attach any collector if needed.

## Requirements

Debian 11/12 or Ubuntu 22.04/24.04, root access, amd64 or arm64, ≥ 1 GB RAM (with 512 MB — swap
and `tmux` required), domain with A record pointing to server IP (for Let's Encrypt), cloud firewall
allowing `tcp/SSH`, `tcp/80`, `tcp+udp/443`, `tcp+udp/20000-50000`.

## Quick Start

```bash
git clone https://github.com/FrankX3M/hysteria_naive.git
cd hysteria_naive
sudo ./install.sh
```

Installer prompts for domain, certificate type, ports, first username, Telegram data and system parameters,
shows summary and executes steps (`--list-steps`). At end outputs links for first user, saves them to
`/root/proxy-config.txt` (600), and sends notification via Telegram if configured.

If installation fails at step N — fix the issue and resume from that step; parameters already saved:

```bash
sudo ./install.sh --config /etc/proxy/install.env --from-step firewall
```

## Non-interactive Installation

```bash
cp install.env.example install.env   # fill in
sudo ./install.sh --config install.env
```

Interactive mode is merely a wrapper filling the same variables. The same configuration
is reproducible on second server, in cloud-init, Ansible or CI.

## Repository Structure

```
install.sh              entry point: args, parameter collection, step orchestration
restore.sh              restoration from backup / --hard-reload (uses same lib/)
lib/
  common.sh             logging, state file, atomic writes, pre-overwrite backup, template render
  versions.sh           SINGLE place with dependency versions
  system.sh certs.sh hysteria.sh naiveproxy.sh firewall.sh fail2ban.sh proxy_tools.sh output.sh
templates/              configs as files (nftables, fail2ban, systemd, docker-compose, sysctl, sudoers, hook)
tools/
  proxy_admin.py        unified management logic (CLI + library), config render
  proxy_authd.py        HTTP Hysteria2 authentication (stdlib)
  proxy_bot.py          Telegram bot
  migrate_v2.py         v1 → v2 backup conversion (passwords and users preserved)
  requirements.txt      pinned python dependencies
maintenance/            serveraudit.sh (read-only), servercleanup.sh + unit/timer
tests/                  pytest (logic, authd, links) + test_templates.sh (render, nft -c, units)
docs/                   RUNBOOK.md (step-by-step v1 server migration), ARCHITECTURE.md, MIGRATION.md
.github/workflows/ci.yml
```

## Server State: /etc/proxy

| File | Permissions | Content |
|---|---|---|
| `install.env` | 640 root:proxyadmin | domain, IP, ports, cert mode, versions, flags — everything installer asked |
| `secrets.env` | 640 root:proxyadmin | `TG_TOKEN`, `TG_CHAT_ID`, `TG_ADMIN_IDS`, `BACKUP_PASSPHRASE`, `HY2_STATS_SECRET` |
| `users.json` | 640 root:proxyadmin | `schema_version`, `obfs_password`, users: HY2/Naive passwords, `enabled`, dates |
| `certs/` | 750 root:hysteria | copy of `fullchain.pem`/`privkey.pem` (640), read by hysteria and sing-box |

`/etc/hysteria/config.yaml` and `/opt/naiveproxy/config/config.json` are **derived** files: generated
by `proxy-admin apply` from `/etc/proxy`. Manual edits will be overwritten; modify `install.env`
and run `proxy-admin apply`. No service fields like `_disabled_users` in configs.

## Management: proxy-admin

```
proxy-admin list                      # users
proxy-admin add <name> [--note "..."]  # add (HY2 — instant, sing-box restarts)
proxy-admin disable|enable|del <name>
proxy-admin rotate <name> | --all      # new passwords
proxy-admin links <name>               # URI + client.yaml
proxy-admin qr <name> --out /tmp/qr    # PNG
proxy-admin status                    # all component status, online users
proxy-admin apply [--restart]         # render → validate (sing-box check) → restart changed
proxy-admin check                     # validation only
proxy-admin backup [--no-send]        # encrypted archive + Telegram
proxy-admin watchdog                  # what timer does
proxy-admin --json <cmd>              # machine-readable output (used by bot)
```

Username — `[a-z0-9_-]{1,32}`, validated before any use. Passwords — `secrets.choice`,
32 chars. All `users.json` entries under `flock`, configs written atomically with `.prev` copy; if
hysteria fails to start with new config, previous reverts automatically. Mutating commands have `--no-apply`
to batch operations and apply once.

Password rotation by schedule intentionally omitted — manual only or via bot (v1 README promised automatic
rotation, code never ran it).

## Telegram Bot

`/status` `/users` `/adduser` `/deluser` `/enable` `/disable` `/links` `/qr` `/rotate` `/backup` `/restart` `/whoami`.

- `TG_CHAT_ID` — notification destination (can be group), `TG_ADMIN_IDS` — who commands
  (user id list). Different concepts; v1 conflated them, bot stayed silent in groups.
- Unauthorized attempts logged (`journalctl -u proxy-bot | grep UNAUTHORIZED`).
- Bot runs as `proxyadmin`; root operations via `sudo -n /usr/local/bin/proxy-admin` —
  single `/etc/sudoers.d/proxyadmin` line. Token compromise ≠ root shell.
- Nothing executes via shell: only `subprocess.run([...])` with argument list.

Get token from `@BotFather`; your user id — `/whoami` to bot or `@userinfobot`.

## Port Hopping — How It Actually Works

Port hopping in Hysteria2 is a **client** feature: client itself iterates ports in range, server only
redirects range to main port (nftables `prerouting … redirect`). Therefore link carries
range, not single "random port from range" as in v1:

```
hysteria2://user:pass@proxy.example.com:443/?sni=…&mport=20000-50000&obfs=salamander&obfs-password=…
```

For official client in `client.yaml`: `server: proxy.example.com:443,20000-50000` (as `proxy-admin links` outputs).
`mport` understood by v2rayN, NekoBox/NekoRay, Shadowrocket, Hiddify, Streisand.

**NaiveProxy** — plain TCP/TLS on port 443; port hopping concept doesn't apply, no
"NaiveProxy (hopping)" links anymore.

## Bridge to Second Server (chain-route-setup.sh)

Separate optional script atop already-installed server — for when this server should only be entry point,
real internet exit for most traffic on another server (e.g., this server in RF, other abroad), while
some traffic (own domains/countries, default `.ru`/`.su`/`.рф` and YouTube) still exits directly from this server.
Not in `install.sh`, changes nothing in base install, no requirements; applied and rolled back separately.

```
Client ──┬─(NaiveProxy)──┐
         └─(Hysteria2)───┴──▶ This Server ──(GeoIP/domain routing)──┬──▶ .ru/.su/.рф/YouTube — direct
                                                                      └──▶ rest — tunnel to Server2
```

Actions:

| Step | How |
|---|---|
| Raises outbound Hysteria2 client to second server | via supplied `hysteria2://...`/`hy2://...` link; local SOCKS5/HTTP on this server |
| Patches `render_singbox()` in `tools/proxy_admin.py` | NaiveProxy input: `sniff` + GeoIP (`sing-geoip`, `*.srs`) + domains → `route.rules`, else `outbound: chain-fin` |
| Patches `render_hysteria()` in same file | Hysteria2 input (`hysteria-server`): `outbounds` + `acl.inline` (`direct(suffix:...)`, `direct(geoip:...)`, `chain_fin(all)`) |
| GeoIP bases | `sing-geoip/*.srs` for sing-box; single `geoip.dat` (Loyalsoldier/geoip, world-readable — hysteria-server process not root) for Hysteria2 |
| Apply | `proxy-admin apply` — same validation before overwrite and automatic rollback on error as regular `proxy-admin` commands |

```bash
sudo bash chain-route-setup.sh                # full setup: client to 2nd server + routing on both inputs
sudo bash chain-route-setup.sh --skip-client  # client to 2nd server already manual — routing only
sudo bash chain-route-setup.sh --only-geoip   # update both GeoIP bases and restart both services
sudo bash chain-route-setup.sh --undo         # revert to clean direct-only on both inputs
```

Country list (GeoIP) and domain exclusions asked interactively on first run, saved in patch; to change —
run script again, patch idempotent (own marker-comments in code, rerun rebuilds both blocks with new params,
no duplicates, doesn't touch rest of `proxy_admin.py` logic — `proxy-admin apply/check/status` work normally).

Important for forks: sing-box and native Hysteria2 have different independent ACL engines.
Hysteria2 (`acl.inline`) has mini-rule parser `outbound(matcher)`, doesn't understand dashes
in outbound name — uses `chain_fin` (underscore) not `chain-fin` like sing-box.
Implementation details, GeoIP format nuances and troubleshooting — in README next to script (`README-chain-route-setup.md`).

## Security Model

**DPI.** Hysteria2 works with obfs `salamander` (resistance to signature analysis). Masquerade not enabled:
with obfs server doesn't answer "garbage" to probes without obfs-key, masquerade only added outbound requests
and false security. `HY2_OBFS=no` switches to plain QUIC with masquerade stub (404) — choose one. NaiveProxy
on 443/tcp has no fallback site; need indistinguishability from web server — separate scheme (Caddy + forwardproxy).

**Firewall.** Table `inet proxy` (one for IPv4/IPv6), `policy drop` in `input`, allow only
loopback, established/related, ICMP, SSH port (from `sshd -T`), tcp/80 (certbot), tcp+udp
main port. Hopping range in `input` unnecessary — redirect in `prerouting` already rewrote port. No `flush ruleset`:
Fail2ban and Docker tables untouched; apply via `nft -f` with guard (`at` deletes table in 3 min if apply not confirmed).

**Privileges.** hysteria — `User=hysteria`, `NoNewPrivileges`, `ProtectSystem=strict`,
capabilities only `NET_BIND_SERVICE/NET_ADMIN/NET_RAW`. authd and bot — `proxyadmin`. sing-box container —
`read_only`, `cap_drop: ALL`, `no-new-privileges`, memory/CPU limits.

**Secrets.** Not in scripts: only `/etc/proxy/*.env` (640) and `users.json` (640). Generated
configs — 640. `serveraudit.sh` verifies permissions on these files.

**Fail2ban.** Jail `hysteria2` watches `proxy-authd` log — line format `auth failed ip=… user=…`
controlled by us, regex covered by test. Ban — `nftables[type=allports]`, so hopping range NAT redirect harmless
(v1 jail couldn't work for that reason). Check on live server: `fail2ban-regex systemd-journal /etc/fail2ban/filter.d/hysteria2.conf`.

**Supply chain.** Versions pinned in `lib/versions.sh` and `tools/requirements.txt`; hysteria can specify
binary sha256. Docker installed via get.docker.com (no pin), packages `apt-mark hold` after. Python deps —
venv `/opt/proxy/venv`, not system Python.

What's **not** done and why: container hardening to rootless Docker (complexity on 1-GB VPS),
multi-server (see `docs/ARCHITECTURE.md`), auto sha256 check without your involvement (hashes from
release page, enter in `versions.sh`).

## Backups and Recovery

Daily at 03:00 `proxy-admin backup` archives `/etc/proxy` (including certs), `nftables.d/proxy.nft`,
`jail.local`, generated configs and `docker-compose.yml`, encrypts with `gpg --symmetric AES256` using
`BACKUP_PASSPHRASE`, keeps last `BACKUP_KEEP` (7) in `/var/backups/proxy/` and sends to Telegram.
Without passphrase/gpg, archive stays local, doesn't go to Telegram.

Recovery on new server:

```bash
git clone … && cd hysteria_naive
sudo BACKUP_PASSPHRASE='…' ./restore.sh proxy-backup-20260905-030000.tar.gz.gpg --yes
```

`restore.sh` decrypts archive, places `/etc/proxy`, substitutes real SSH port of new server
and runs `install.sh --from-step deps`: delivers packages, issues cert (if certbot fails —
temporarily uses backup copy), generates configs, starts services. Nothing inferred
by indirect signs — all params in `install.env`.

`sudo ./restore.sh --hard-reload [--pull]` — resync certs, kill orphan processes, reapply nftables,
recreate container — no archive.

## Updates

```bash
git pull
sudo ./install.sh --upgrade
```

Updates hysteria binary and sing-box image to versions in `lib/versions.sh`, scripts to `/opt/proxy`,
units and templates. `users.json` and `secrets.env` untouched. Copies of all replaced files —
in `/root/proxy-pre-change-<date>/`. Repeat `install.sh` without `--upgrade` on configured
server stops with hint (`--reinstall` — start over, old `users.json` goes to backup).

## Monitoring and Logs

Watchdog every 5 minutes checks not "process alive" but: hysteria active **and** port responds; authd
responds to `/healthz`; container in `running` **and** `RestartCount` not growing (catches crash-loop shown
as alive by `docker ps`); nftables table present. Restarts what possible, reports result to Telegram. If
Telegram unavailable, message goes to `/var/log/proxy/undelivered-alerts.log`.

`proxy-admin status` shows online users via Hysteria2 Traffic Stats API
(`127.0.0.1:9912`, secret in `secrets.env`).

```bash
journalctl -u hysteria-server -f
journalctl -t naiveproxy -f          # container writes to journald
journalctl -u proxy-authd | grep 'auth failed'
journalctl -u proxy-bot
systemctl list-timers 'proxy-*'
```

## Post-Installation Verification

1. `proxy-admin status` — all green, `nftables: table loaded`.
2. `nft list table inet proxy` — `policy drop`, your SSH port in accept.
3. Connect real client via link from `proxy-admin links <user>` (with `mport`) and without.
4. `proxy-admin disable <user>` — Hysteria2 connection should drop immediately, other users unaffected.
5. Enter wrong password 10 times → `fail2ban-client status hysteria2` shows ban.
6. `proxy-admin backup --no-send` and `gpg -d /var/backups/proxy/…gpg | tar tz` — archive readable.

## Development and CI

```bash
pip install -r tools/requirements-dev.txt
ruff check tools tests && pytest -q tests
shellcheck -S warning -x install.sh restore.sh lib/*.sh maintenance/*.sh
sudo bash tests/test_templates.sh        # template render, nft -c, units
```

GitHub Actions (`.github/workflows/ci.yml`) runs same checks on each push. Installer scripts
work only on real server (root, systemd, docker) — CI checks syntax, render and logic.
