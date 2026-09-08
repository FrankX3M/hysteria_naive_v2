# Hysteria_naive v2 — установка и настройка VPN на VDS (Hysteria2 + NaiveProxy)

**Готовый скрипт, чтобы поднять VPN на VDS и создать свой личный VPN-сервер: Hysteria2 + NaiveProxy в Docker, файрвол, бэкапы и Telegram-бот «из коробки».**

[![License: MIT](https://img.shields.io/github/license/FrankX3M/hysteria_naive_v2?color=blue)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/FrankX3M/hysteria_naive_v2)](https://github.com/FrankX3M/hysteria_naive_v2/commits/main)
[![CI](https://img.shields.io/github/actions/workflow/status/FrankX3M/hysteria_naive_v2/ci.yml?branch=main&label=CI)](https://github.com/FrankX3M/hysteria_naive_v2/actions/workflows/ci.yml)
[![Bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](install.sh)
[![Python 3](https://img.shields.io/badge/python-3-3776AB?logo=python&logoColor=white)](tools/)
[![Platform: Debian | Ubuntu](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-informational)](#требования)
[![Lint: ruff · shellcheck](https://img.shields.io/badge/lint-ruff%20%7C%20shellcheck-informational)](#разработка-и-ci)

Инсталлятор и инструменты управления для связки **Hysteria2 + NaiveProxy (sing-box в Docker)** с port hopping,
Telegram-ботом, watchdog'ом, шифрованными бэкапами, Fail2ban и файрволом на nftables.

Если вы ищете, **как поднять VPN на VDS** без ручной настройки каждого компонента — этот проект решает
именно эту задачу: один скрипт разворачивает связку из двух протоколов (Hysteria2 и NaiveProxy), настраивает
файрвол, защиту от брутфорса, автоматические бэкапы и уведомления в Telegram. Подходит и для тех, кто **создаёт
свой первый личный VPN-сервер на VDS**, и для тех, кто хочет **настроить VPN сервер на VDS** более защищённо,
чем типовые однокомандные скрипты из интернета.

v2 — переработка на основе [архитектурного анализа](docs/ARCHITECTURE.md#что-изменилось-относительно-v1):
модульный установщик, единый файл состояния `/etc/proxy/`, конфиги как производные артефакты,
аутентификация Hysteria2 без перезапусков, сервисы не из-под root, файрвол с `policy drop`.

Миграция с v1 — [пошаговая инструкция для работающего сервера](docs/RUNBOOK.md)
или [краткая справка по миграции](docs/MIGRATION.md).

## 🚀 Быстрый старт (TL;DR)

Если нужно быстро **установить VPN на VDS** прямо сейчас:

```bash
git clone https://github.com/FrankX3M/hysteria_naive_v2.git
cd hysteria_naive_v2
sudo ./install.sh
```

Понадобится: Debian 11/12 или Ubuntu 22.04/24.04, root, ≥ 1 ГБ RAM и домен с A-записью на сервер.
Установщик задаст несколько вопросов и сам развернёт Hysteria2 + NaiveProxy — вручную конфигурировать
каждый компонент не нужно.

Подробности, неинтерактивный режим и восстановление после сбоя шага — в разделе
[«Быстрый старт»](#быстрый-старт) ниже.

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
- [Почему стоит настраивать VPN на VDS именно так](#почему-стоит-настраивать-vpn-на-vds-именно-так)
- [Разработка и CI](#разработка-и-ci)

## Что ставится

| Компонент | Как | От чьего имени |
|---|---|---|
| Hysteria2 (`lib/versions.sh`: v2.9.2) | бинарник из GitHub Releases, зафиксированная версия, опционально sha256 | `hysteria` (systemd, hardening) |
| NaiveProxy = sing-box (v1.13.21) | `docker compose`, `mem_limit`/`cpus`, `read_only`, `cap_drop` | контейнер |
| nftables | отдельная таблица `inet proxy`, `policy drop`, NAT-редирект диапазона hopping (IPv4+IPv6) | — |
| proxy-authd | HTTP-backend для аутентификации Hysteria2 (`auth.type: http`) на 127.0.0.1 | `proxyadmin` |
| proxy-admin | CLI: пользователи, ссылки/QR, рендер и валидация конфигов, статус, watchdog, бэкап | root / `proxyadmin` |
| proxy-bot (опционально) | Telegram-обёртка над proxy-admin, без бизнес-логики, без `shell=True` | `proxyadmin` + sudoers |
| Fail2ban (опционально) | jail `sshd` + jail `hysteria2` по логу proxy-authd, бан через `nftables[type=allports]` | — |
| systemd-таймеры | `proxy-watchdog` (5 мин), `proxy-backup` (03:00), `servercleanup` (03:30, опц.) | root |
| certbot (опционально) | standalone на tcp/80, deploy-hook копирует сертификат и перезапускает сервисы | — |
| sysctl, swap | BBR + буферы; swap по умолчанию `auto` (создаётся, если отсутствует) | — |

Grafana Alloy убран из v1: все логи компонентов идут в journald (`journalctl -u hysteria-server`,
`journalctl -t naiveproxy`, `journalctl -u proxy-authd`); при необходимости подключите любой коллектор.

## Требования

Что нужно, чтобы настроить свой VPN-сервер на VDS с этим проектом: Debian 11/12 или Ubuntu 22.04/24.04,
root-доступ, amd64 или arm64, ≥ 1 ГБ RAM (при 512 МБ — обязательны swap и `tmux`), домен с A-записью,
указывающей на IP сервера (для Let's Encrypt), облачный файрвол, разрешающий `tcp/SSH`, `tcp/80`,
`tcp+udp/443`, `tcp+udp/20000-50000`.

## Быстрый старт

```bash
git clone https://github.com/FrankX3M/hysteria_naive.git
cd hysteria_naive
sudo ./install.sh
```

Установщик спрашивает домен, тип сертификата, порты, имя первого пользователя, данные Telegram и
системные параметры, показывает сводку и выполняет шаги (`--list-steps`). В конце выводит ссылки для
первого пользователя, сохраняет их в `/root/proxy-config.txt` (600) и отправляет уведомление в Telegram,
если он настроен.

Если установка упала на шаге N — исправьте проблему и продолжите с этого шага, параметры уже сохранены:

```bash
sudo ./install.sh --config /etc/proxy/install.env --from-step firewall
```

## Неинтерактивная установка

Для тех, кто настраивает VPN на VDS через автоматизацию (Ansible, cloud-init, CI), а не вручную:

```bash
cp install.env.example install.env   # заполнить
sudo ./install.sh --config install.env
```

Интерактивный режим — просто обёртка, заполняющая те же переменные. Та же конфигурация
воспроизводима на втором сервере, в cloud-init, Ansible или CI.

## Структура репозитория

```
install.sh              точка входа: аргументы, сбор параметров, оркестрация шагов
restore.sh              восстановление из бэкапа / --hard-reload (использует тот же lib/)
lib/
  common.sh             логирование, файл состояния, атомарная запись, бэкап перед перезаписью, рендер шаблонов
  versions.sh           ЕДИНСТВЕННОЕ место с версиями зависимостей
  system.sh certs.sh hysteria.sh naiveproxy.sh firewall.sh fail2ban.sh proxy_tools.sh output.sh
templates/              конфиги как файлы (nftables, fail2ban, systemd, docker-compose, sysctl, sudoers, hook)
tools/
  proxy_admin.py        единая логика управления (CLI + библиотека), рендер конфигов
  proxy_authd.py        HTTP-аутентификация Hysteria2 (только stdlib)
  proxy_bot.py          Telegram-бот
  migrate_v2.py         конвертация бэкапа v1 → v2 (пароли и пользователи сохраняются)
  requirements.txt      зафиксированные python-зависимости
maintenance/            serveraudit.sh (только чтение), servercleanup.sh + unit/timer
tests/                  pytest (логика, authd, ссылки) + test_templates.sh (рендер, nft -c, unit-файлы)
docs/                   RUNBOOK.md (пошаговая миграция сервера v1), ARCHITECTURE.md, MIGRATION.md
.github/workflows/ci.yml
```

## Состояние на сервере: /etc/proxy

| Файл | Права | Содержимое |
|---|---|---|
| `install.env` | 640 root:proxyadmin | домен, IP, порты, режим сертификата, версии, флаги — всё, что спросил установщик |
| `secrets.env` | 640 root:proxyadmin | `TG_TOKEN`, `TG_CHAT_ID`, `TG_ADMIN_IDS`, `BACKUP_PASSPHRASE`, `HY2_STATS_SECRET` |
| `users.json` | 640 root:proxyadmin | `schema_version`, `obfs_password`, пользователи: пароли HY2/Naive, `enabled`, даты |
| `certs/` | 750 root:hysteria | копия `fullchain.pem`/`privkey.pem` (640), читается hysteria и sing-box |

`/etc/hysteria/config.yaml` и `/opt/naiveproxy/config/config.json` — **производные** файлы: генерируются
`proxy-admin apply` из `/etc/proxy`. Ручные правки будут перезаписаны; меняйте `install.env`
и запускайте `proxy-admin apply`.

## Управление: proxy-admin

```
proxy-admin list                      # пользователи
proxy-admin add <name> [--note "..."]  # добавить (HY2 — сразу, sing-box перезапускается)
proxy-admin disable|enable|del <name>
proxy-admin rotate <name> | --all      # новые пароли
proxy-admin links <name>               # URI + client.yaml
proxy-admin qr <name> --out /tmp/qr    # PNG
proxy-admin status                    # статус всех компонентов, онлайн-пользователи
proxy-admin apply [--restart]         # рендер → валидация (sing-box check) → перезапуск изменённого
proxy-admin check                     # только валидация
proxy-admin backup [--no-send]        # зашифрованный архив + Telegram
proxy-admin watchdog                  # то же, что делает таймер
proxy-admin --json <cmd>              # машиночитаемый вывод (используется ботом)
```

Имя пользователя — `[a-z0-9_-]{1,32}`, валидируется перед любым использованием. Пароли — `secrets.choice`,
32 символа. Все записи `users.json` под `flock`, конфиги пишутся атомарно с копией `.prev`; если
hysteria не стартует с новым конфигом — предыдущий откатывается автоматически.

## Telegram-бот

`/status` `/users` `/adduser` `/deluser` `/enable` `/disable` `/links` `/qr` `/rotate` `/backup` `/restart` `/whoami`.

- `TG_CHAT_ID` — куда шлются уведомления (может быть группа), `TG_ADMIN_IDS` — кто может отдавать команды
  (список id пользователей). Разные понятия; в v1 их путали, бот молчал в группах.
- Неавторизованные попытки логируются (`journalctl -u proxy-bot | grep UNAUTHORIZED`).
- Бот работает от `proxyadmin`; root-операции — через `sudo -n /usr/local/bin/proxy-admin`, одна строка
  в `/etc/sudoers.d/proxyadmin`. Компрометация токена ≠ root-шелл.
- Ничего не выполняется через shell: только `subprocess.run([...])` со списком аргументов.

Токен — у `@BotFather`; свой id — командой `/whoami` боту или у `@userinfobot`.

## Port hopping — как это работает на самом деле

Port hopping в Hysteria2 — это функция **клиента**: клиент сам перебирает порты в диапазоне, сервер
только редиректит диапазон на основной порт (nftables `prerouting … redirect`). Поэтому в ссылке —
диапазон, а не один "случайный порт из диапазона", как было в v1:

```
hysteria2://user:pass@proxy.example.com:443/?sni=…&mport=20000-50000&obfs=salamander&obfs-password=…
```

Для официального клиента в `client.yaml`: `server: proxy.example.com:443,20000-50000` (как выводит
`proxy-admin links`). `mport` понимают v2rayN, NekoBox/NekoRay, Shadowrocket, Hiddify, Streisand.

**NaiveProxy** — обычный TCP/TLS на порту 443; концепция port hopping к нему не применяется, ссылок
вида "NaiveProxy (hopping)" больше нет.

## Мост на второй сервер (chain-route-setup.sh)

Отдельный опциональный скрипт поверх уже установленного сервера — для случая, когда этот сервер должен
быть только точкой входа, а реальный выход в интернет для большей части трафика — на другом сервере
(например, этот сервер в РФ, другой — за границей), при этом часть трафика (свои домены/страны, по
умолчанию `.ru`/`.su`/`.рф` и YouTube) всё равно выходит напрямую с этого сервера. Не входит в
`install.sh`, ничего не меняет в базовой установке, применяется и откатывается отдельно. Подробное
описание — в [`README-chain-route-setup.md`](README-chain-route-setup.md).

## Модель безопасности

**DPI.** Hysteria2 работает с obfs `salamander` (устойчивость к сигнатурному анализу). Masquerade не
включён: с obfs сервер не отвечает "мусором" на пробы без obfs-key, masquerade только добавил бы
исходящие запросы и ложное чувство защиты. `HY2_OBFS=no` переключает на чистый QUIC с
masquerade-заглушкой (404) — нужно выбрать одно. NaiveProxy на 443/tcp без fallback-сайта; для
неотличимости от веб-сервера нужна отдельная схема (Caddy + forwardproxy).

**Firewall.** Таблица `inet proxy` (одна для IPv4/IPv6), `policy drop` в `input`, разрешён только
loopback, established/related, ICMP, порт SSH (из `sshd -T`), tcp/80 (certbot), tcp+udp основной порт.
Диапазон hopping в `input` не нужен — редирект в `prerouting` уже переписал порт. Без `flush ruleset`:
таблицы Fail2ban и Docker не трогаются; применяется через `nft -f` со страховкой (`at` удаляет
таблицу через 3 минуты, если apply не подтверждён).

**Привилегии.** hysteria — `User=hysteria`, `NoNewPrivileges`, `ProtectSystem=strict`, только
capabilities `NET_BIND_SERVICE/NET_ADMIN/NET_RAW`. authd и бот — `proxyadmin`. Контейнер sing-box —
`read_only`, `cap_drop: ALL`, `no-new-privileges`, лимиты памяти/CPU.

**Секреты.** Не в скриптах: только `/etc/proxy/*.env` (640) и `users.json` (640). Сгенерированные
конфиги — 640. `serveraudit.sh` проверяет права на эти файлы.

**Fail2ban.** Jail `hysteria2` следит за логом `proxy-authd` — формат строки `auth failed ip=… user=…`
контролируется нами, регэксп покрыт тестом. Бан — `nftables[type=allports]`, поэтому NAT-редирект
диапазона hopping не мешает (в v1 jail по этой причине не работал).

**Supply chain.** Версии зафиксированы в `lib/versions.sh` и `tools/requirements.txt`; для hysteria
можно указать sha256 бинарника. Docker ставится через get.docker.com (без пина), пакеты после —
`apt-mark hold`. Python-зависимости — venv `/opt/proxy/venv`, не системный Python.

## Бэкапы и восстановление

Ежедневно в 03:00 `proxy-admin backup` архивирует `/etc/proxy` (включая сертификаты),
`nftables.d/proxy.nft`, `jail.local`, сгенерированные конфиги и `docker-compose.yml`, шифрует
`gpg --symmetric AES256` с `BACKUP_PASSPHRASE`, хранит последние `BACKUP_KEEP` (7) в
`/var/backups/proxy/` и отправляет в Telegram.

Восстановление на новом сервере:

```bash
git clone … && cd hysteria_naive
sudo BACKUP_PASSPHRASE='…' ./restore.sh proxy-backup-20260905-030000.tar.gz.gpg --yes
```

`restore.sh` расшифровывает архив, раскладывает `/etc/proxy`, подставляет реальный SSH-порт нового
сервера и запускает `install.sh --from-step deps`: доставляет пакеты, выпускает сертификат, генерирует
конфиги, запускает сервисы.

## Обновление

```bash
git pull
sudo ./install.sh --upgrade
```

Обновляет бинарник hysteria и образ sing-box до версий из `lib/versions.sh`, скрипты в `/opt/proxy`,
unit-файлы и шаблоны. `users.json` и `secrets.env` не трогаются. Копии всех заменённых файлов — в
`/root/proxy-pre-change-<date>/`.

## Мониторинг и логи

Watchdog каждые 5 минут проверяет не "процесс жив", а: hysteria активна **и** порт отвечает; authd
отвечает на `/healthz`; контейнер в `running` **и** `RestartCount` не растёт (ловит crash-loop, который
`docker ps` покажет как "живой"); таблица nftables присутствует. Перезапускает что можно, репортит
результат в Telegram.

```bash
journalctl -u hysteria-server -f
journalctl -t naiveproxy -f          # контейнер пишет в journald
journalctl -u proxy-authd | grep 'auth failed'
journalctl -u proxy-bot
systemctl list-timers 'proxy-*'
```

## Проверка после установки

1. `proxy-admin status` — всё зелёное, `nftables: table loaded`.
2. `nft list table inet proxy` — `policy drop`, ваш SSH-порт в accept.
3. Подключить реальный клиент по ссылке из `proxy-admin links <user>` (с `mport`) и без.
4. `proxy-admin disable <user>` — подключение Hysteria2 должно немедленно отвалиться, другие пользователи
   не затронуты.
5. Ввести неверный пароль 10 раз → `fail2ban-client status hysteria2` показывает бан.
6. `proxy-admin backup --no-send` и `gpg -d /var/backups/proxy/…gpg | tar tz` — архив читается.

## Почему стоит настраивать VPN на VDS именно так

Большинство инструкций «как поднять VPN на VDS» сводятся к одной команде `curl | bash` без файрвола,
без бэкапов и без защиты от перебора паролей. Этот проект — вариант для тех, кто хочет **настроить
свой личный VPN-сервер на VDS** осознанно: с файрволом `policy drop` по умолчанию, разделением
привилегий (сервисы не от root), шифрованными автоматическими бэкапами и управлением через CLI/Telegram
без ручного редактирования конфигов. Если задача — не просто разово поднять VPN на VDS, а поддерживать
сервер долго (обновления, ротация паролей, мониторинг) — это и есть основной сценарий использования
`proxy-admin` и watchdog-таймеров, описанных выше.

## Разработка и CI

```bash
pip install -r tools/requirements-dev.txt
ruff check tools tests && pytest -q tests
shellcheck -S warning -x install.sh restore.sh lib/*.sh maintenance/*.sh
sudo bash tests/test_templates.sh        # рендер шаблонов, nft -c, unit-файлы
```

GitHub Actions (`.github/workflows/ci.yml`) прогоняет те же проверки на каждый push. Скрипты
установки работают только на реальном сервере (root, systemd, docker) — CI проверяет синтаксис,
рендер и логику.
