# Архитектура hysteria_naive v3

## Слои

```
┌────────────────────────────── оркестрация ───────────────────────────────┐
│ install.sh   restore.sh                                                  │
│   аргументы → параметры (интерактивно или --config) → список шагов        │
└──────────────────────────────────┬───────────────────────────────────────┘
                                   │ source
┌──────────────────────────────────▼───────────────────────────────────────┐
│ lib/*.sh — bash-библиотеки по компонентам                                 │
│ common (состояние, запись файлов, шаблоны) · system · certs · hysteria    │
│ naiveproxy · firewall · fail2ban · proxy_tools · output · versions        │
└──────────────┬────────────────────────────────────────┬──────────────────┘
               │ render_template (envsubst)              │ proxy-admin apply
┌──────────────▼──────────────┐            ┌────────────▼──────────────────┐
│ templates/                  │            │ tools/proxy_admin.py           │
│ nftables, fail2ban, systemd │            │ users.json ⇄ hysteria.yaml     │
│ docker-compose, sysctl, …   │            │            ⇄ sing-box.json     │
└─────────────────────────────┘            └────────────┬──────────────────┘
                                                         │ import / CLI --json
                                   ┌─────────────────────┼─────────────────────┐
                                   ▼                     ▼                     ▼
                           proxy_authd.py          proxy_bot.py        systemd timers
                     (HTTP auth для hysteria)   (Telegram-обвязка)   (watchdog, backup)
```

## Источник правды: `/etc/proxy/`

Всё состояние установки — три файла плюс копия сертификатов. Конфиги сервисов генерируются из них
и никогда не редактируются руками. Это закрывает сразу несколько проблем v2: секреты в коде, скрытая
миграция схемы `password → userpass`, служебные поля `_disabled_users` внутри конфига sing-box (от которых
он падал), «угадывание» домена при restore, невозможность неинтерактивной установки.

`users.json` версионируется полем `schema_version`; миграции — явный код в `State._migrate()`,
выполняемый под `flock`.

## Поток изменения пользователя

```
proxy-admin add alice
  ├─ flock users.json → добавить запись (secrets-пароли) → atomic write
  ├─ Hysteria2: ничего — proxy-authd перечитает users.json по mtime при следующем подключении
  └─ sing-box: render config.json → `docker run … sing-box check` → atomic write (+ .prev)
               → docker restart naiveproxy → ждать State.Status == running
```

Hysteria2 использует `auth.type: http` → `proxy-authd` (127.0.0.1:9911). Поэтому add/disable/rotate
для Hysteria2 вступают в силу мгновенно и не рвут чужие сессии. sing-box не умеет перечитывать
пользователей без рестарта, поэтому для NaiveProxy рестарт остаётся, но только при реальном
изменении списка naive-пользователей, и один на операцию (или один на батч с `--no-apply`).

## Привилегии

| Процесс | Пользователь | Что может |
|---|---|---|
| hysteria-server | `hysteria` | читать `/etc/hysteria`, `/etc/proxy/certs`; сеть |
| proxy-authd | `proxyadmin` | читать `/etc/proxy`; слушать localhost |
| proxy-bot | `proxyadmin` | читать `/etc/proxy`; `sudo -n proxy-admin` |
| proxy-admin (из бота) | root через sudoers | всё, что нужно для apply/restart/backup; аргументы валидирует сам |
| proxy-watchdog/backup | root (таймер) | — |
| naiveproxy | root в контейнере | `read_only`, `cap_drop ALL`, `NET_BIND_SERVICE`, лимиты |

## Файрвол

Одна таблица `inet proxy` с двумя базовыми цепочками: `prerouting` (nat, dstnat) — редирект
диапазона hopping на основной порт для tcp и udp, IPv4 и IPv6; `input` (filter, policy drop) —
явный allow-list. Файл `/etc/nftables.d/proxy.nft` самодостаточен (`table … ; flush table … ; table … {…}`),
применяется через `nft -f`, `/etc/nftables.conf` лишь `include`'ит каталог для загрузки при boot.
Ни `flush ruleset`, ни `systemctl restart nftables` в runtime не используются, чтобы не сносить
таблицы Fail2ban и Docker.

## Наблюдаемость

Watchdog проверяет функциональные признаки (порт, healthz, RestartCount, наличие таблицы nft),
а не только «процесс есть». Уведомления в Telegram — с проверкой ответа API и журналом недоставленных.
Онлайн-пользователи — через Traffic Stats API Hysteria2 на localhost.

## Ограничения (осознанные)

- **Один сервер.** `users.json` локален. Для нескольких нод придётся вынести хранилище пользователей
  за пределы хоста (общий HTTP-бэкенд для `auth.type: http` — самый дешёвый путь: `proxy-authd` уже
  является таким бэкендом, его можно вынести на отдельный хост и указать URL в `install.env`).
- **Docker для sing-box.** Оставлен ради совместимости с v2 и простоты обновления образа. Альтернатива —
  нативный бинарник sing-box под systemd; шаблоны для этого не написаны.
- **Restore выпускает сертификат заново.** Копия из бэкапа используется как временная, если certbot не смог.
- **CI не запускает установщик на реальной ОС** — только синтаксис, рендер шаблонов и логику Python.

## Что изменилось относительно v2

Соответствие пунктам архитектурного анализа (см. `hysteria_naive_architecture_recommendations_v2.md`):

| № | Проблема v2 | Решение v3 |
|---|---|---|
| 1, 2, 15 | монолит `sh.sh` 1430 строк, дублирование с `restore_proxy.sh`, плоский репозиторий | `install.sh` + `lib/` + `templates/` + `tools/`; restore использует те же lib и install.sh |
| 3, 19 | секреты в коде, конфиги 644 | `/etc/proxy/secrets.env` 640, `EnvironmentFile`-подход через `Config`, конфиги 640 |
| 4 | `policy accept`, `flush ruleset`, только IPv4 NAT | `policy drop`, своя таблица `inet proxy`, `nft -f` со страховкой, tcp/80 для certbot |
| 5 | скрытая миграция `password → userpass` | одна схема с установки; `users.json` с `schema_version` |
| 6 | логика в трёх копиях, нет блокировок | `proxy_admin.py` + `flock` |
| 7 | `hash()` и `$RANDOM` для «hopping-порта» | `mport=start-end` в URI, диапазон в `client.yaml`; Naive без «hopping» |
| 8 | мёртвая ветка ротации по cron | удалена; README честен |
| 9, 24 | `latest`, `curl \| bash`, непинованный PTB, amd64-only | `versions.sh`, бинарник с релиза + опц. sha256, `requirements.txt` в venv, arm64 |
| 10 | `docker run` в bash | `docker-compose.yml` с лимитами, `read_only`, journald |
| 11 | watchdog «процесс есть», TG без проверки | функциональные проверки, RestartCount, `undelivered-alerts.log` |
| 12 | бэкап без шифрования, только Telegram | gpg AES256, локальная ротация, `restore.sh` |
| 13 | один сервер | зафиксировано как ограничение; authd — точка расширения |
| 14 | нет CI | shellcheck, ruff, pytest, рендер шаблонов + `nft -c` |
| 16 | `/disable` роняет sing-box | статус в `users.json`, конфиг без чужих полей, `sing-box check` до записи |
| 17 | рестарт всего на каждую операцию | `auth.type: http` + proxy-authd; sing-box — только при изменении |
| 18 | всё от root, `shell=True` | `User=hysteria`/`proxyadmin`, sudoers на один бинарник, list-args, валидация имени |
| 20 | restore ищет литерал `dport 22`, домен из пути LE | `install.env` в бэкапе, `detect_ssh_port`, `nft list` проверка живых правил |
| 21 | jail не банит (NAT), регулярки не сверены | jail по журналу authd (формат наш), `nftables[type=allports]`, тест регулярки |
| 22 | obfs + masquerade | obfs без masquerade (или `HY2_OBFS=no` — QUIC + заглушка) |
| 23 | `random` вместо `secrets` | `secrets.choice`, одна реализация |
| 25 | только интерактивный ввод | `--config install.env`, интерактив — обёртка |
| 26 | `ADMIN_ID == CHAT_ID` | `TG_ADMIN_IDS` ≠ `TG_CHAT_ID`, лог неавторизованных |
| 27 | не идемпотентен, нет отката | стоп без `--upgrade`, `SAFETY_DIR`, `--from-step`, `.prev` + автооткат hysteria |
