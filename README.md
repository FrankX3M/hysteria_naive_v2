# hysteria_naive v2

[![License: MIT](https://img.shields.io/github/license/FrankX3M/hysteria_naive_v2?color=blue)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/FrankX3M/hysteria_naive_v2)](https://github.com/FrankX3M/hysteria_naive_v2/commits/main)
[![CI](https://img.shields.io/github/actions/workflow/status/FrankX3M/hysteria_naive_v2/ci.yml?branch=main&label=CI)](https://github.com/FrankX3M/hysteria_naive_v2/actions/workflows/ci.yml)
[![Bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](install.sh)
[![Python 3](https://img.shields.io/badge/python-3-3776AB?logo=python&logoColor=white)](tools/)
[![Platform: Debian | Ubuntu](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-informational)](#%D1%82%D1%80%D0%B5%D0%B1%D0%BE%D0%B2%D0%B0%D0%BD%D0%B8%D1%8F)
[![Lint: ruff · shellcheck](https://img.shields.io/badge/lint-ruff%20%7C%20shellcheck-informational)](#%D1%80%D0%B0%D0%B7%D1%80%D0%B0%D0%B1%D0%BE%D1%82%D0%BA%D0%B0-%D0%B8-ci)
[![Open issues](https://img.shields.io/github/issues/FrankX3M/hysteria_naive_v2)](https://github.com/FrankX3M/hysteria_naive_v2/issues)

*[Английская версия / English version](README.en.md)*

Установщик и инструменты управления связкой **Hysteria2 + NaiveProxy (sing-box в Docker)** с port hopping,
Telegram-ботом, watchdog'ом, зашифрованными бэкапами, Fail2ban и nftables-файрволом.

v2 — переработка по итогам [архитектурного анализа](docs/ARCHITECTURE.md#что-изменилось-относительно-v2):
модульный установщик, единый файл состояния `/etc/proxy/`, конфиги как производные артефакты,
аутентификация Hysteria2 без рестартов, сервисы не от root, файрвол с `policy drop`.

Как перейти с v1 — [пошаговая инструкция для работающего сервера](docs/RUNBOOK.md)
или [краткая справка по миграции](docs/MIGRATION.md).

## Содержание

- [Что ставится](#что-ставится)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Неинтерактивная установка](#неинтерактивная-установка)
- [Структура репозитория](#структура-репозитория)
- [Состояние на сервере: /etc/proxy](#состояние-на-сервере-etcproxy)
- [Управление: proxy-admin](#управление-proxy-admin)
- [Telegram-бот](#telegram-бот)
- [Port hopping — как это работает на самом деле](#port-hopping--как-это-работает-на-самом-деле)
- [Мост на второй сервер (chain-route-setup.sh)](#мост-на-второй-сервер-chain-route-setupsh)
- [Модель безопасности](#модель-безопасности)
- [Бэкапы и восстановление](#бэкапы-и-восстановление)
- [Обновление](#обновление)
- [Мониторинг и логи](#мониторинг-и-логи)
- [Проверка после установки](#проверка-после-установки)
- [Разработка и CI](#разработка-и-ci)

## Что ставится

| Компонент | Как | От кого |
|---|---|---|
| Hysteria2 (`lib/versions.sh`: v2.9.2) | бинарник с GitHub Releases, пин версии, опц. sha256 | `hysteria` (systemd, hardening) |
| NaiveProxy = sing-box (v1.13.21) | `docker compose`, `mem_limit`/`cpus`, `read_only`, `cap_drop` | контейнер |
| nftables | своя таблица `inet proxy`, `policy drop`, NAT-редирект hopping-диапазона (IPv4+IPv6) | — |
| proxy-authd | HTTP-бэкенд аутентификации Hysteria2 (`auth.type: http`) на 127.0.0.1 | `proxyadmin` |
| proxy-admin | CLI: пользователи, ссылки/QR, рендер и валидация конфигов, статус, watchdog, бэкап | root / `proxyadmin` |
| proxy-bot (опц.) | Telegram-обвязка над proxy-admin, без бизнес-логики, без `shell=True` | `proxyadmin` + sudoers |
| Fail2ban (опц.) | jail `sshd` + jail `hysteria2` по журналу proxy-authd, бан `nftables[type=allports]` | — |
| Таймеры systemd | `proxy-watchdog` (5 мин), `proxy-backup` (03:00), `servercleanup` (03:30, опц.) | root |
| certbot (опц.) | standalone на tcp/80, deploy-hook копирует сертификат и перезапускает сервисы | — |
| sysctl, swap | BBR + буферы; swap по умолчанию `auto` (создать, если нет) | — |

Grafana Alloy из v2 удалён: логи всех компонентов идут в journald (`journalctl -u hysteria-server`,
`journalctl -t naiveproxy`, `journalctl -u proxy-authd`), при необходимости подключайте любой сборщик.

## Требования

Debian 11/12 или Ubuntu 22.04/24.04, root, amd64 или arm64, ≥ 1 ГБ RAM (при 512 МБ — обязательно swap
и запуск в `tmux`), домен с A-записью на IP сервера (для Let's Encrypt), открытые в облачном файрволе
`tcp/SSH`, `tcp/80`, `tcp+udp/443`, `tcp+udp/20000-50000`.

## Быстрый старт

```bash
git clone https://github.com/FrankX3M/hysteria_naive.git
cd hysteria_naive
sudo ./install.sh
```

Установщик спросит домен, тип сертификата, порты, имя первого пользователя, данные Telegram и параметры
системы, покажет сводку и выполнит шаги (`--list-steps`). В конце выведет ссылки для первого пользователя,
сохранит их в `/root/proxy-config.txt` (600) и, если настроен Telegram, пришлёт уведомление.

Если установка упала на шаге N — исправьте причину и продолжите с этого шага, параметры уже сохранены:

```bash
sudo ./install.sh --config /etc/proxy/install.env --from-step firewall
```

## Неинтерактивная установка

```bash
cp install.env.example install.env   # заполнить
sudo ./install.sh --config install.env
```

Интерактивный режим — лишь обёртка, заполняющая те же переменные. Поэтому одна и та же конфигурация
воспроизводима на втором сервере, в cloud-init, Ansible или CI.

## Структура репозитория

```
install.sh              точка входа: аргументы, сбор параметров, оркестрация шагов
restore.sh              восстановление из бэкапа / --hard-reload (использует те же lib/)
lib/
  common.sh             логирование, файл состояния, атомарная запись, бэкап перед перезаписью, рендер шаблонов
  versions.sh           ЕДИНСТВЕННОЕ место с версиями зависимостей
  system.sh certs.sh hysteria.sh naiveproxy.sh firewall.sh fail2ban.sh proxy_tools.sh output.sh
templates/              конфиги как файлы (nftables, fail2ban, systemd, docker-compose, sysctl, sudoers, hook)
tools/
  proxy_admin.py        единая логика управления (CLI + библиотека), рендер конфигов
  proxy_authd.py        HTTP-аутентификация Hysteria2 (stdlib)
  proxy_bot.py          Telegram-бот
  migrate_v2.py         конвертация бэкапа v1 → v2 (пароли и пользователи сохраняются)
  requirements.txt      пины python-зависимостей
maintenance/            serveraudit.sh (read-only), servercleanup.sh + unit/timer
tests/                  pytest (логика, authd, ссылки) + test_templates.sh (рендер, nft -c, юниты)
docs/                   RUNBOOK.md (пошаговый перевод сервера с v2), ARCHITECTURE.md, MIGRATION.md
.github/workflows/ci.yml
```

## Состояние на сервере: /etc/proxy

| Файл | Права | Содержимое |
|---|---|---|
| `install.env` | 640 root:proxyadmin | домен, IP, порты, режим сертификата, версии, флаги — всё, что спросил установщик |
| `secrets.env` | 640 root:proxyadmin | `TG_TOKEN`, `TG_CHAT_ID`, `TG_ADMIN_IDS`, `BACKUP_PASSPHRASE`, `HY2_STATS_SECRET` |
| `users.json` | 640 root:proxyadmin | `schema_version`, `obfs_password`, пользователи: пароли HY2/Naive, `enabled`, даты |
| `certs/` | 750 root:hysteria | копия `fullchain.pem`/`privkey.pem` (640), которую читают hysteria и sing-box |

`/etc/hysteria/config.yaml` и `/opt/naiveproxy/config/config.json` — **производные** файлы: их генерирует
`proxy-admin apply` из `/etc/proxy`. Ручные правки в них будут перезаписаны; меняйте `install.env`
и запускайте `proxy-admin apply`. Служебных полей вроде `_disabled_users` в конфигах нет.

## Управление: proxy-admin

```
proxy-admin list                      # пользователи
proxy-admin add <имя> [--note "..."]  # добавить (HY2 — мгновенно, sing-box перезапустится)
proxy-admin disable|enable|del <имя>
proxy-admin rotate <имя> | --all      # новые пароли
proxy-admin links <имя>               # URI + client.yaml
proxy-admin qr <имя> --out /tmp/qr    # PNG
proxy-admin status                    # состояние всех компонентов, онлайн-пользователи
proxy-admin apply [--restart]         # рендер → валидация (sing-box check) → рестарт изменившегося
proxy-admin check                     # только валидация
proxy-admin backup [--no-send]        # зашифрованный архив + Telegram
proxy-admin watchdog                  # то, что делает таймер
proxy-admin --json <cmd>              # машиночитаемый вывод (так его зовёт бот)
```

Имя пользователя — `[a-z0-9_-]{1,32}`, проверяется до любого использования. Пароли — `secrets.choice`,
32 символа. Все записи в `users.json` под `flock`, конфиги пишутся атомарно с копией `.prev`; если
hysteria не поднимается с новым конфигом, предыдущий возвращается автоматически. `--no-apply` у
мутирующих команд позволяет батчить операции и применить один раз.

Ротация паролей по расписанию намеренно не включена — только вручную или через бота (в v2 README
обещал автоматическую ротацию, а код её не запускал).

## Telegram-бот

`/status` `/users` `/adduser` `/deluser` `/enable` `/disable` `/links` `/qr` `/rotate` `/backup` `/restart` `/whoami`.

- `TG_CHAT_ID` — куда идут уведомления (можно группу), `TG_ADMIN_IDS` — кто может командовать
  (список user id). Это разные вещи; в v2 они совпадали, и в группе бот молчал.
- Неавторизованные обращения пишутся в журнал (`journalctl -u proxy-bot | grep UNAUTHORIZED`).
- Бот работает от `proxyadmin`; root-операции идут через `sudo -n /usr/local/bin/proxy-admin` —
  единственная строка в `/etc/sudoers.d/proxyadmin`. Компрометация токена ≠ root-шелл.
- Ничего не выполняется через shell: только `subprocess.run([...])` со списком аргументов.

Получить токен — `@BotFather`; свой user id — `/whoami` у бота или `@userinfobot`.

## Port hopping — как это работает на самом деле

Port hopping в Hysteria2 — **клиентская** функция: клиент сам перебирает порты из диапазона, сервер
лишь редиректит диапазон на основной порт (nftables `prerouting … redirect`). Поэтому в ссылке передаётся
диапазон, а не один «случайный порт из диапазона», как было в v2:

```
hysteria2://user:pass@proxy.example.com:443/?sni=…&mport=20000-50000&obfs=salamander&obfs-password=…
```

Для официального клиента в `client.yaml`: `server: proxy.example.com:443,20000-50000` (то, что выводит
`proxy-admin links`). `mport` понимают v2rayN, NekoBox/NekoRay, Shadowrocket, Hiddify, Streisand.

**NaiveProxy** — обычный TCP/TLS на порту 443; понятие port hopping к нему неприменимо, и никаких
«NaiveProxy (hopping)» ссылок больше нет.

## Мост на второй сервер (chain-route-setup.sh)

Отдельный, необязательный скрипт поверх уже установленного сервера — для случая, когда этот сервер
должен быть только точкой входа, а реальный выход в интернет для большей части трафика — на другом
сервере (например, этот сервер в РФ, второй — за рубежом), при этом часть трафика (свои домены/страны,
по умолчанию `.ru`/`.su`/`.рф` и YouTube) должна по-прежнему выходить напрямую с этого сервера. Не входит
в `install.sh`, ничего в основной установке не меняет и не требует; накатывается и откатывается отдельно.

```
Клиент ──┬─(NaiveProxy)──┐
         └─(Hysteria2)───┴──▶ Этот сервер ──(GeoIP/domain routing)──┬──▶ .ru/.su/.рф/YouTube — напрямую
                                                                      └──▶ остальное — в туннель на Сервер2
```

Что делает:

| Шаг | Как |
|---|---|
| Поднимает исходящий Hysteria2-клиент до второго сервера | по вставленной `hysteria2://...`/`hy2://...` ссылке; локальный SOCKS5/HTTP на этом сервере |
| Патчит `render_singbox()` в `tools/proxy_admin.py` | NaiveProxy-вход: `sniff` + GeoIP (`sing-geoip`, `*.srs`) + домены → `route.rules`, иначе `outbound: chain-fin` |
| Патчит `render_hysteria()` в том же файле | Hysteria2-вход (`hysteria-server`): `outbounds` + `acl.inline` (`direct(suffix:...)`, `direct(geoip:...)`, `chain_fin(all)`) |
| GeoIP-базы | `sing-geoip/*.srs` для sing-box; единая `geoip.dat` (Loyalsoldier/geoip, world-readable — процесс hysteria-server не root) для Hysteria2 |
| Применение | `proxy-admin apply` — та же валидация перед перезаписью и автоматический откат при ошибке, что и у обычных команд `proxy-admin` |

```bash
sudo bash chain-route-setup.sh                # полная настройка: клиент к 2-му серверу + маршрутизация на обоих входах
sudo bash chain-route-setup.sh --skip-client  # клиент к 2-му серверу уже настроен вручную — только маршрутизация
sudo bash chain-route-setup.sh --only-geoip   # обновить обе GeoIP-базы и перезапустить оба сервиса
sudo bash chain-route-setup.sh --undo         # откатить к чистому direct-only на обоих входах
```

Список стран (GeoIP) и доменов-исключений спрашивается интерактивно при первом запуске и сохраняется
в патче; чтобы поменять — просто запустить скрипт снова, патч идемпотентный (свои маркеры-комментарии
в коде, повторный запуск пересобирает оба блока с новыми параметрами, не плодит дублей и не трогает
остальную логику `proxy_admin.py` — `proxy-admin apply/check/status` продолжают работать как обычно).

Важно для своей вилки/форка: у sing-box и у нативного Hysteria2 — разные, независимые ACL-движки.
У Hysteria2 (`acl.inline`) свой мини-парсер правил `outbound(matcher)`, который не понимает дефис
в имени outbound'а — поэтому там используется имя `chain_fin` (с подчёркиванием), а не `chain-fin`,
как на sing-box-стороне. Подробности реализации, нюансы GeoIP-форматов и troubleshooting — в
README рядом со скриптом (`README-chain-route-setup.md`).

## Модель безопасности

**DPI.** Hysteria2 работает с obfs `salamander` (стойкость к сигнатурному анализу). Masquerade при этом
не включается: при obfs сервер и так не отвечает «мусором» на пробинг без obfs-ключа, а masquerade
только добавлял исходящие запросы и ложное чувство защиты. `HY2_OBFS=no` переключает на чистый QUIC
с masquerade-заглушкой (404) — выбирайте одно. NaiveProxy на 443/tcp fallback-сайта не имеет; если
нужна неотличимость от веб-сервера, это отдельная схема (Caddy + forwardproxy).

**Файрвол.** Таблица `inet proxy` (одна для IPv4/IPv6), `policy drop` в `input`, разрешены только
loopback, established/related, ICMP, SSH-порт (определяется из `sshd -T`), tcp/80 (certbot), tcp+udp
основной порт. Диапазон hopping в `input` открывать не нужно — редирект в `prerouting` уже переписал
порт. Никакого `flush ruleset`: таблицы Fail2ban и Docker не трогаются; применение — `nft -f` со
страховкой (`at` удалит таблицу через 3 минуты, если применение не подтвердится).

**Привилегии.** hysteria — `User=hysteria`, `NoNewPrivileges`, `ProtectSystem=strict`,
capability только `NET_BIND_SERVICE/NET_ADMIN/NET_RAW`. authd и бот — `proxyadmin`. Контейнер
sing-box — `read_only`, `cap_drop: ALL`, `no-new-privileges`, лимиты памяти/CPU.

**Секреты.** Не в коде скриптов: только `/etc/proxy/*.env` (640) и `users.json` (640). Сгенерированные
конфиги — 640. `serveraudit.sh` проверяет права на эти файлы.

**Fail2ban.** Jail `hysteria2` смотрит журнал `proxy-authd` — формат строки `auth failed ip=… user=…`
контролируем мы, регулярка покрыта тестом. Бан — `nftables[type=allports]`, поэтому NAT-редирект
hopping-диапазона не мешает (в v2 jail не мог сработать по этой причине). Проверить на живом сервере:
`fail2ban-regex systemd-journal /etc/fail2ban/filter.d/hysteria2.conf`.

**Supply chain.** Версии зафиксированы в `lib/versions.sh` и `tools/requirements.txt`; для hysteria
можно указать sha256 бинарника. Docker ставится через get.docker.com (у него нет пина), после установки
пакеты ставятся на `apt-mark hold`. Python-зависимости — в venv `/opt/proxy/venv`, а не в системный
Python.

Что **не** сделано и почему: hardening контейнера до rootless Docker (сложность на 1-ГБ VPS),
multi-server (см. `docs/ARCHITECTURE.md`), автопроверка sha256 без вашего участия (хеши нужно взять
со страницы релиза и вписать в `versions.sh`).

## Бэкапы и восстановление

Ежедневно в 03:00 `proxy-admin backup` архивирует `/etc/proxy` (включая сертификаты), `nftables.d/proxy.nft`,
`jail.local`, сгенерированные конфиги и `docker-compose.yml`, шифрует `gpg --symmetric AES256` паролем
`BACKUP_PASSPHRASE`, оставляет последние `BACKUP_KEEP` (7) в `/var/backups/proxy/` и отправляет в Telegram.
Без passphrase/gpg архив остаётся локально и в Telegram не уходит.

Восстановление на новом сервере:

```bash
git clone … && cd hysteria_naive
sudo BACKUP_PASSPHRASE='…' ./restore.sh proxy-backup-20260905-030000.tar.gz.gpg --yes
```

`restore.sh` расшифрует архив, положит `/etc/proxy`, подставит реальный SSH-порт нового сервера
и запустит `install.sh --from-step deps`: доставит пакеты, выпустит сертификат (если certbot не сможет —
временно поедет на копии из бэкапа), сгенерирует конфиги, поднимет сервисы. Ничего не угадывается
по косвенным признакам — все параметры в `install.env`.

`sudo ./restore.sh --hard-reload [--pull]` — пересинхронизация сертификатов, убийство осиротевших
процессов, переприменение nftables, пересоздание контейнера — без архива.

## Обновление

```bash
git pull
sudo ./install.sh --upgrade
```

Обновляет бинарник hysteria и образ sing-box до версий из `lib/versions.sh`, скрипты в `/opt/proxy`,
юниты и шаблоны. `users.json` и `secrets.env` не трогаются. Копии всех заменённых файлов —
в `/root/proxy-pre-change-<дата>/`. Повторный запуск `install.sh` без `--upgrade` на настроенном
сервере останавливается с подсказкой (`--reinstall` — начать заново, старый `users.json` уедет в копию).

## Мониторинг и логи

Watchdog каждые 5 минут проверяет не «процесс жив», а: hysteria активна **и** порт отвечает; authd
отвечает на `/healthz`; контейнер в `running` **и** `RestartCount` не растёт (ловит crash-loop, который
`docker ps` показывал как живой); таблица nftables на месте. Что можно — перезапускает, о результате
сообщает в Telegram. Если Telegram недоступен, сообщение пишется в `/var/log/proxy/undelivered-alerts.log`.

`proxy-admin status` показывает онлайн-пользователей через Traffic Stats API Hysteria2
(`127.0.0.1:9912`, секрет в `secrets.env`).

```bash
journalctl -u hysteria-server -f
journalctl -t naiveproxy -f          # контейнер пишет в journald
journalctl -u proxy-authd | grep 'auth failed'
journalctl -u proxy-bot
systemctl list-timers 'proxy-*'
```

## Проверка после установки

1. `proxy-admin status` — всё зелёное, `nftables: таблица загружена`.
2. `nft list table inet proxy` — `policy drop`, ваш SSH-порт в accept.
3. Подключиться реальным клиентом по ссылке из `proxy-admin links <user>` (с `mport`) и без.
4. `proxy-admin disable <user>` — подключение Hysteria2 должно отваливаться сразу, другие пользователи не рвутся.
5. Ввести неверный пароль 10 раз → `fail2ban-client status hysteria2` покажет бан.
6. `proxy-admin backup --no-send` и `gpg -d /var/backups/proxy/…gpg | tar tz` — архив читается.

## Разработка и CI

```bash
pip install -r tools/requirements-dev.txt
ruff check tools tests && pytest -q tests
shellcheck -S warning -x install.sh restore.sh lib/*.sh maintenance/*.sh
sudo bash tests/test_templates.sh        # рендер шаблонов, nft -c, юниты
```

GitHub Actions (`.github/workflows/ci.yml`) гоняет то же самое на каждый push. Скрипты установщика
работают только на реальном сервере (root, systemd, docker) — CI проверяет синтаксис, рендер и логику.
