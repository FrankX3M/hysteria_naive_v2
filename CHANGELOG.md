# Changelog

## 3.0.1 — 2026-09-06

### Fixed
- `apply_firewall_safely`: проверка «SSH-порт разрешён» падала на серверах с nftables < 1.0,
  где текстовый вывод печатает имена служб (`tcp dport ssh accept`) вместо номеров портов.
  Установка обрывалась на шаге `firewall`, хотя правила применялись правильно.
  Теперь проверка разбирает JSON (`nft -j`), а текстовый разбор — запасной вариант,
  понимающий и номер, и имя службы; оба пути покрыты тестами.

## 3.0.0 — 2026-09-05

Полная переработка по итогам архитектурного анализа (`docs/ARCHITECTURE.md`, раздел «Что изменилось»).

### Breaking
- Установщик — `install.sh` (вместо `sh.sh`), состояние — `/etc/proxy/` (install.env, secrets.env, users.json).
- Hysteria2: `auth.type: http` через `proxy-authd`; ссылки всегда `user:password@`, port hopping через `mport=`.
- `proxy-manager.sh`, cron-задачи, Grafana Alloy удалены; watchdog/backup — systemd-таймеры, `proxy-admin`.
- nftables: своя таблица `inet proxy`, `policy drop`; `/etc/nftables.conf` только `include`.
- Бот: `TG_ADMIN_IDS` отдельно от `TG_CHAT_ID`; запускается от `proxyadmin`.
- Бэкапы шифруются gpg; формат архива изменён (`restore.sh` понимает только v3).

### Added
- `install.sh --config/--upgrade/--from-step/--list-steps`, `install.env.example`.
- `proxy-admin` CLI (add/del/enable/disable/rotate/links/qr/status/apply/check/backup/watchdog/notify).
- Валидация конфигов до записи (`sing-box check`), автооткат конфига hysteria, `.prev`-копии.
- Docker Compose с лимитами ресурсов и journald-логами; поддержка arm64.
- Fail2ban jail по журналу proxy-authd с `nftables[type=allports]`.
- `tools/migrate_v2.py`: конвертация бэкапа v2 в v3 без смены паролей.
- Тесты (pytest, рендер шаблонов, `nft -c`) и GitHub Actions.
- `serveraudit.sh`: раздел с проверкой прав на секреты и состоянием сервисов; исправлен путь в `servercleanup.service`.

### Removed
- Masquerade при включённом obfs; «NaiveProxy (hopping)»-ссылки; мёртвая ветка cron-ротации.
