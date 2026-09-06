# Инструкция: перевод работающего сервера с v2 на v3

Пошаговый сценарий для сервера, где уже крутится v2 (`sh.sh`) и есть бэкап `proxybackupYYYYMMDD.tar.gz`.
Пример на данных из вашего бэкапа: домен `hy2.1rtp.ru`, порт 443, hopping 20000–50000, SSH 22,
Let's Encrypt, 13 пользователей (`admin, alex_m, andrey, eva, katrin, max_orlov, maxx5, natly, pavel_t,
server, server_as, test, vlad`) — все переносятся со своими текущими паролями.

**Сколько это занимает:** 15–25 минут, из них простой сервиса — один перезапуск (5–15 секунд)
на шаге 5. Клиентские ссылки не меняются.

---

## Что понадобится под рукой

| Что | Зачем | Где взять |
|---|---|---|
| SSH-доступ root | вся установка | — |
| Бэкап v2 `proxybackup20260905.tar.gz` | пользователи и пароли | Telegram-чат бота v2 или `/root` |
| Токен Telegram-бота | бот v3 | `@BotFather` → выберите бота → API Token |
| Chat ID для уведомлений | watchdog, бэкапы | ваш текущий v2-конфиг или `@userinfobot` |
| Ваш Telegram user id | права администратора бота | `@userinfobot` (в личке боту это то же число, что chat id) |
| Архив `hysteria_naive-v3.tar.gz` | код v3 | из чата, либо `git clone` после того как зальёте в GitHub |

Проверьте до начала, что в **облачном файрволе** (панель провайдера, не сервер) открыты:
`tcp/22`, `tcp/80`, `tcp+udp/443`, `tcp+udp/20000-50000`. В v3 порт 80 нужен обязательно — через него
идёт автопродление сертификата (в v2 он был не нужен только потому, что файрвол на сервере ничего
не фильтровал).

---

## Шаг 0. Свежий бэкап v2 и страховка (2 мин)

Работаем **в tmux** — если SSH оборвётся (на 1 ГБ RAM `apt`/`docker pull` могут вызвать OOM),
процесс продолжится:

```bash
ssh root@hy2.1rtp.ru
apt-get install -y tmux
tmux new -s migrate
```

Внутри tmux сделайте свежий бэкап v2 и локальную копию конфигов:

```bash
/usr/local/bin/proxy-manager.sh backup          # придёт в Telegram
mkdir -p /root/v2-snapshot
cp -a /etc/hysteria /opt/naiveproxy/config /etc/nftables.conf /etc/fail2ban/jail.local \
      /etc/systemd/system/hysteria-server.service /usr/local/bin/proxy-manager.sh \
      /usr/local/bin/proxy_bot.py /root/v2-snapshot/ 2>/dev/null
ls -la /root/v2-snapshot
```

Это ваш «билет назад»: даже если что-то пойдёт не так, все пароли и конфиги v2 лежат тут же на диске.

Если tmux оборвётся — вернуться: `ssh root@hy2.1rtp.ru`, затем `tmux attach -t migrate`.

---

## Шаг 1. Положить код v3 на сервер (2 мин)

**Вариант А — из архива** (быстрее, ничего не надо заливать в GitHub):

```bash
# на своём компьютере:
scp hysteria_naive-v3.tar.gz root@hy2.1rtp.ru:/root/
# на сервере (в tmux):
cd /root && tar xzf hysteria_naive-v3.tar.gz && cd hysteria_naive && ls
```

**Вариант Б — через GitHub** (если уже залили v3 в репозиторий):

```bash
cd /root && git clone https://github.com/FrankX3M/hysteria_naive.git && cd hysteria_naive
```

Проверка, что распаковалось правильно:

```bash
./install.sh --list-steps     # должен вывести: deps sysctl swap certs hysteria docker tools firewall …
```

---

## Шаг 2. Сконвертировать бэкап v2 (1 мин)

Положите `proxybackup20260905.tar.gz` на сервер (`scp` или скачайте из Telegram) и выполните,
подставив свои значения Telegram:

```bash
cd /root/hysteria_naive
python3 tools/migrate_v2.py /root/proxybackup20260905.tar.gz -o /root/proxy-backup-v3.tar.gz \
    --tg-token '123456789:AA…' \
    --tg-chat-id 123456789 \
    --tg-admin-ids 123456789
```

Ожидаемый вывод:

```
✓ /root/proxy-backup-v3.tar.gz: домен hy2.1rtp.ru, порт 443, hopping 20000-50000, SSH 22,
  cert=letsencrypt, пользователей 13 (активных 13)
```

Сверьте: домен, порты и **13 пользователей**. Если число меньше — значит, чьё-то имя не прошло
валидацию (`[a-z0-9_-]`, до 32 символов), утилита напишет какое; такого пользователя добавите
вручную после миграции.

Хотите заглянуть внутрь перед накатом:

```bash
tar xzOf /root/proxy-backup-v3.tar.gz etc/proxy/users.json | python3 -m json.tool | head -30
```

Telegram-флаги можно не указывать — тогда бот просто не запустится, а токен допишете позже
(см. «Если бот не настроен» в конце).

---

## Шаг 3. Проверить свободную память (30 сек)

```bash
free -m
```

Если в колонке `available` меньше 300 МБ и swap отсутствует — включите его заранее, иначе
`apt-get`/`docker pull` могут убить sshd:

```bash
fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
```

(Установщик и сам умеет создавать swap, но лучше до, а не во время.)

---

## Шаг 4. Прогон вхолостую: убедиться, что состояние читается (1 мин)

Ничего не меняя на сервере, разверните состояние во временный каталог и посмотрите,
какие конфиги сгенерирует v3:

```bash
mkdir -p /tmp/dryrun && tar xzf /root/proxy-backup-v3.tar.gz -C /tmp/dryrun
PROXY_STATE_DIR=/tmp/dryrun/etc/proxy python3 tools/proxy_admin.py list
PROXY_STATE_DIR=/tmp/dryrun/etc/proxy python3 tools/proxy_admin.py links admin
```

Вторая команда покажет будущую ссылку для `admin`. Сравните пароль в ней с текущим
в `/etc/hysteria/config.yaml` — они должны совпадать. Это и есть доказательство бесшовности.

```bash
rm -rf /tmp/dryrun
```

---

## Шаг 5. Накат (10–15 мин, здесь единственный перерыв в работе прокси)

```bash
cd /root/hysteria_naive
./restore.sh /root/proxy-backup-v3.tar.gz --yes
```

Что произойдёт по порядку (можно следить по выводу, полный лог — `/var/log/proxy/setup.log`):

1. `/etc/proxy` — разложены `install.env`, `secrets.env`, `users.json`; SSH-порт подставлен реальный.
2. `deps` — доустанавливаются пакеты (`nftables`, `jq`, `at`, `python3-venv`, `qrencode`, `gnupg`…).
3. `sysctl`, `swap` — BBR остаётся включённым, swap не трогается (`ENABLE_SWAP=auto`).
4. `certs` — существующий сертификат Let's Encrypt найден, копируется в `/etc/proxy/certs`
   (600 → 640 `root:hysteria`); certbot не запускается.
5. `hysteria` — ставится Hysteria **v2.9.2** (пин версии), юнит заменяется на вариант с
   `User=hysteria` и hardening. **Здесь сервис перезапускается.**
6. `docker` — проверяется Docker и плагин compose, скачивается образ `sing-box:v1.13.21`,
   пишется `/opt/naiveproxy/docker-compose.yml`, старый контейнер `docker run` удаляется.
7. `tools` — venv `/opt/proxy/venv`, `proxy-admin`, `sudoers`, пользователь `proxyadmin`.
   `users.json` уже существует → **пользователи сохраняются, пароли не генерируются заново**.
8. `firewall` — новая таблица `inet proxy` (policy drop) с автооткатом через `at`:
   если через 3 минуты применение не подтвердится, таблица удаляется сама.
9. `fail2ban`, `certhook`, `services` — jail'ы, deploy-hook, `proxy-authd`, бот, таймеры.
10. `apply` — генерируются `/etc/hysteria/config.yaml` и `config.json`, проверяются
    (`sing-box check`), сервисы стартуют.
11. `output` — ссылки для первого пользователя в `/root/proxy-config.txt`.

В конце увидите строку `Готово. Копии заменённых файлов: /root/proxy-pre-change-<дата>` — там лежат
все старые версии файлов, которые v3 перезаписал.

**Если упало на каком-то шаге** — вывод скажет, на каком. Исправьте причину и продолжите с него:

```bash
./install.sh --config /etc/proxy/install.env --from-step firewall
```

Повторный запуск с начала (`--from-step deps`) тоже безопасен: пользователи не перезаписываются.


### Если упало на шаге `firewall`

Симптом: `В активных правилах нет accept для SSH-порта 22 — оставляю автооткат`.
Правила при этом применились корректно — не срабатывала проверка (в nftables до версии 1.0
вывод показывает имена служб: `tcp dport ssh accept` вместо `tcp dport 22 accept`).
Исправлено в v3.0.1: проверка читает `nft -j` (JSON), текстовый разбор оставлен запасным
вариантом и понимает оба написания.

Что сделать:

```bash
nft --version                       # если < 1.0 — вы поймали именно этот случай
atq                                 # остался ли автооткат; atrm <номер> — снять
nft list chain inet proxy input     # правила скорее всего на месте
```

Обновите код (перекопируйте архив или `git pull`) и продолжите с этого шага:

```bash
./install.sh --config /etc/proxy/install.env --from-step firewall
```

---

## Шаг 6. Проверка (5 мин)

### 6.1 Состояние компонентов

```bash
proxy-admin status
```

Ожидаемо: 🟢 у Hysteria2, NaiveProxy (`running`, restarts 0), proxy-authd, nftables, Fail2ban,
бота; «Пользователи: 13 активных из 13».

### 6.2 Файрвол не отрезал вас

```bash
nft list chain inet proxy input
```

Должны быть `policy drop` и accept для `tcp dport 22`, `tcp dport 80`, `tcp/udp dport 443`.
**Не закрывайте текущую SSH-сессию,** пока не откроете вторую и не убедитесь, что она проходит:

```bash
# с другого терминала на своём компьютере:
ssh root@hy2.1rtp.ru 'echo SSH-OK'
```

### 6.3 Клиент подключается со старой ссылкой

Самая важная проверка — реальным клиентом, старой ссылкой из v2. Должно работать без изменений.
Заодно посмотрите, что аутентификация идёт через новый сервис:

```bash
journalctl -u proxy-authd -n 20 --no-pager     # строки «auth ok ip=… user=…»
```

### 6.4 Мгновенное отключение (то, чего не было в v2)

```bash
proxy-admin disable test          # клиент test отваливается сразу, остальные не рвутся
proxy-admin enable test
```

### 6.5 Бэкап работает и читается

```bash
proxy-admin backup                # придёт в Telegram, зашифрованный
ls -la /var/backups/proxy
gpg --batch --passphrase "$(grep BACKUP_PASSPHRASE /etc/proxy/secrets.env | cut -d'"' -f2)" \
    -d /var/backups/proxy/proxy-backup-*.tar.gz.gpg | tar tz | head
```

### 6.6 Бот отвечает

В Telegram: `/whoami` → должно быть «— администратор», затем `/status`, `/users`.

---

## Шаг 7. Уборка после успешной миграции (3 мин)

Сначала — остатки v2, которые v3 не трогает:

```bash
systemctl disable --now alloy 2>/dev/null
rm -rf /etc/systemd/system/alloy.service /usr/local/bin/alloy /etc/alloy
rm -f /etc/letsencrypt/renewal-hooks/deploy/restart-proxy.sh
systemctl daemon-reload
```

(`proxy-manager.sh`, старый `proxy_bot.py` и `/etc/cron.d/proxy-manager` установщик удалил сам.)

Затем — старые правила nftables, которые остались в памяти ядра с прошлой загрузки. Проверьте:

```bash
nft list ruleset | grep -E '^table' 
```

Если видите `table inet filter` (это таблица v2 с `policy accept`) — удалите её:

```bash
nft delete table inet filter
```

`table ip nat` **не трогайте** — в ней живут и правила Docker. Оставшийся там дубликат
редиректа v2 безвреден (он перенаправляет на тот же порт 443) и исчезнет при первой перезагрузке
сервера. Таблицы `inet f2b-table` (Fail2ban) и `ip/ip6 filter` (Docker) — рабочие, их не трогаем.

Проверьте, что после перезагрузки всё поднимется (лучше сделать это в удобное окно):

```bash
reboot
# через минуту:
proxy-admin status && nft list ruleset | grep -E '^table'
```

Наконец, удалите незашифрованные копии с паролями:

```bash
shred -u /root/proxy-backup-v3.tar.gz /root/proxybackup20260905.tar.gz
# /root/v2-snapshot оставьте на неделю, потом: rm -rf /root/v2-snapshot
```

`/root/proxy-config.txt` v3 создал заново (права 600) — там ссылки только для первого пользователя.

---

## Если что-то пошло не так: откат к v2

Ничего необратимого миграция не делает — пароли те же, сертификат тот же, старые файлы сохранены.

```bash
# 1. Остановить v3
systemctl disable --now proxy-authd proxy-bot proxy-watchdog.timer proxy-backup.timer

# 2. Вернуть конфиги и юнит v2 (SAFETY_DIR — из вывода установщика)
S=/root/proxy-pre-change-<дата>
cp -a $S/etc/hysteria/config.yaml /etc/hysteria/config.yaml
cp -a $S/opt/naiveproxy/config/config.json /opt/naiveproxy/config/config.json
cp -a $S/etc/systemd/system/hysteria-server.service /etc/systemd/system/
cp -a $S/etc/nftables.conf /etc/nftables.conf         # v2-версия с flush ruleset
# либо из /root/v2-snapshot, если SAFETY_DIR не сохранился

# 3. Применить
systemctl daemon-reload && systemctl restart hysteria-server
nft -f /etc/nftables.conf
cd /opt/naiveproxy && docker compose down 2>/dev/null
docker run -d --name naiveproxy --network host --restart always \
  -v /opt/naiveproxy/config:/etc/sing-box ghcr.io/sagernet/sing-box:latest \
  run -c /etc/sing-box/config.json
```

Клиенты вернутся к работе с теми же ссылками — пароли между версиями одинаковые.

---

## Повседневная эксплуатация после миграции

| Задача | Команда в терминале | Команда в боте |
|---|---|---|
| Список пользователей | `proxy-admin list` | `/users` |
| Добавить | `proxy-admin add ivan --note "ноутбук"` | `/adduser ivan ноутбук` |
| Выдать ссылки/QR | `proxy-admin links ivan` / `proxy-admin qr ivan --out /tmp/qr` | `/links ivan`, `/qr ivan` |
| Временно отключить | `proxy-admin disable ivan` | `/disable ivan` |
| Удалить | `proxy-admin del ivan` | `/deluser ivan` |
| Сменить пароли | `proxy-admin rotate ivan` или `--all` | `/rotate ivan` |
| Состояние | `proxy-admin status` | `/status` |
| Бэкап сейчас | `proxy-admin backup` | `/backup` |

Что происходит само: watchdog каждые 5 минут (перезапускает упавшее, пишет в Telegram),
бэкап ежедневно в 03:00 (7 копий в `/var/backups/proxy`), очистка диска в 03:30,
продление сертификата — certbot по своему таймеру, с перезапуском сервисов через deploy-hook.

Массовые операции лучше батчить, чтобы не дёргать sing-box на каждого:

```bash
proxy-admin add ivan --no-apply
proxy-admin add petr --no-apply
proxy-admin apply            # один перезапуск контейнера на всех
```

Обновление версий Hysteria/sing-box: правите `lib/versions.sh`, затем
`git pull && ./install.sh --upgrade` — пользователи и секреты не трогаются.

---

## Частые вопросы

**Клиентам нужно менять ссылки?** Нет. Старые работают. Но новые (`proxy-admin links`) содержат
`mport=20000-50000` — это настоящий port hopping (клиент сам перебирает порты), которого в v2 не было,
хотя ссылка так называлась. Имеет смысл разослать новые ссылки тем, у кого бывают блокировки.

**Почему в ссылке появилось имя пользователя?** Оно там было и в v2 — ваш сервер уже работал в режиме
`userpass` (13 пользователей). Ничего не поменялось.

**Если бот не настроен.** Допишите токен и id в секреты и включите сервис:

```bash
nano /etc/proxy/secrets.env      # TG_TOKEN, TG_CHAT_ID, TG_ADMIN_IDS
systemctl enable --now proxy-bot && systemctl status proxy-bot
```

**Как добавить второго администратора бота.** `TG_ADMIN_IDS="111,222"` в `/etc/proxy/secrets.env`,
затем `systemctl restart proxy-bot`. Переустановка не нужна (в v2 была нужна).

**Не приходят уведомления.** Проверьте `/var/log/proxy/undelivered-alerts.log` — туда пишется всё,
что Telegram не принял (отозванный токен, блокировка, сеть).

**Где теперь пароли.** Только в `/etc/proxy/users.json` (640 `root:proxyadmin`). В скриптах и
конфигах их нет; `/etc/hysteria/config.yaml` вообще не содержит паролей — аутентификация идёт
через `proxy-authd`.

**Хочу проверить, что Fail2ban действительно банит.** Сделайте 10 неудачных подключений и:

```bash
fail2ban-client status hysteria2
fail2ban-regex systemd-journal /etc/fail2ban/filter.d/hysteria2.conf
```
