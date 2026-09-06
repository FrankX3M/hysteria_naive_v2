# Переход с v2 (sh.sh) на v3

В v2 не было файла состояния: пользователи жили прямо в `config.yaml`/`config.json`. Перенос делается
один раз, не требует переустановки ОС и не меняет пароли клиентов.

## Быстрый путь: конвертация бэкапа v2

Если у вас есть бэкап v2 (`proxybackupYYYYMMDD.tar.gz`, который `proxy-manager.sh backup` слал в Telegram),
переносить пользователей руками не нужно:

```bash
git clone https://github.com/FrankX3M/hysteria_naive.git && cd hysteria_naive
python3 tools/migrate_v2.py proxybackup20260905.tar.gz -o proxy-backup-v3.tar.gz \
    --tg-token '123:ABC…' --tg-chat-id 123456789 --tg-admin-ids 123456789
sudo ./restore.sh proxy-backup-v3.tar.gz --yes
```

`migrate_v2.py` читает `config.yaml`/`config.json`/`nftables.conf` из архива и собирает `/etc/proxy`:
все пользователи Hysteria2 (`userpass` и `_disabled_users`) и NaiveProxy с **теми же паролями**,
тот же obfs-пароль, домен, порты, диапазон hopping и SSH-порт. Клиенты продолжают работать со старыми
ссылками — и «прямыми», и «hopping» с одиночным портом (NAT-редирект диапазона остаётся). Telegram-данные
в бэкапе v2 не хранились, их надо передать флагами (или дописать в `/etc/proxy/secrets.env` после restore).

Единственный случай, когда ссылки меняются: v2 до первого `/adduser` (режим одного пароля `auth.type: password`,
ссылка без имени) — пароль назначается пользователю `admin`, и клиенту нужна новая ссылка вида `admin:пароль@`.
Утилита об этом предупредит.

`restore.sh` на старом сервере тоже работает (это и есть in-place обновление): он положит `/etc/proxy`
и запустит `install.sh --from-step deps`, который заменит юнит hysteria, nftables, контейнер и бота.
Рестарт сервисов при этом один. Ручной вариант ниже — на случай, если бэкапа нет.

## Ручной путь (без бэкапа v2)

### 0. Что сохранить перед началом

```bash
mkdir -p /root/v2-backup && cp -a /etc/hysteria /opt/naiveproxy/config /etc/nftables.conf \
   /etc/fail2ban/jail.local /usr/local/bin/proxy-manager.sh /usr/local/bin/proxy_bot.py /root/v2-backup/ 2>/dev/null
```

Список пользователей и их паролей v2:

```bash
python3 - <<'EOF'
import yaml, json
h = yaml.safe_load(open('/etc/hysteria/config.yaml'))
n = json.load(open('/opt/naiveproxy/config/config.json'))
a = h.get('auth', {})
hy = a.get('userpass') or {'admin': a.get('password')}
print("HY2:", hy); print("HY2 disabled:", h.get('_disabled_users', {}))
print("Naive:", [(u['username'], u['password']) for u in n['inbounds'][0].get('users', [])])
print("Naive disabled:", n['inbounds'][0].get('_disabled_users', []))
print("obfs:", h.get('obfs', {}).get('salamander', {}).get('password'))
EOF
```

### 1. Остановить компоненты v2

```bash
systemctl disable --now proxy-bot alloy 2>/dev/null
rm -f /etc/cron.d/proxy-manager
```

Hysteria и контейнер можно не останавливать — установщик v3 их заменит.

### 2. Установить v3

```bash
git clone https://github.com/FrankX3M/hysteria_naive.git && cd hysteria_naive
cp install.env.example install.env      # домен, порты, TG_TOKEN/TG_CHAT_ID/TG_ADMIN_IDS — как было
sudo ./install.sh --config install.env
```

Сертификат Let's Encrypt v2 в `/etc/letsencrypt/live/<домен>/` будет подхвачен как есть.
Старый `/etc/nftables.conf` с `flush ruleset` заменится (копия — в `/root/proxy-pre-change-<дата>/`).
Старый юнит `hysteria-server.service` без `User=` заменится hardened-версией.

### 3. Перенести пользователей

`users.json` создаётся с одним первым пользователем и **новыми** паролями. Чтобы клиенты v2
продолжили работать без перевыпуска ссылок, впишите старые пароли:

```bash
proxy-admin add alice --no-apply
proxy-admin add bob   --no-apply
# … затем старые пароли и obfs:
python3 - <<'EOF'
import json
p = '/etc/proxy/users.json'; d = json.load(open(p))
d['obfs_password'] = 'OLD_OBFS_PASSWORD'
d['users']['alice'].update(hy2_password='OLD_HY2', naive_password='OLD_NAIVE')
json.dump(d, open(p, 'w'), indent=2)
EOF
proxy-admin apply --restart
```

Важно: в v3 Hysteria2 аутентифицирует по паре `user:password` (proxy-authd), тогда как v2 до первого
`/adduser` работала в режиме одного пароля без имени. Клиентам с такой v2-ссылкой нужно выдать новую
(`proxy-admin links <имя>`); заодно они получат `mport=` и настоящий port hopping, которого в v2 не было.
Пользователи, добавленные в v2 через бота (`userpass`), со старыми паролями подключатся без изменений.

### 4. Проверить

```bash
proxy-admin status
nft list table inet proxy
fail2ban-client status
journalctl -u proxy-authd -n 20
```

### 5. Убрать остатки v2

```bash
rm -f /usr/local/bin/proxy-manager.sh /usr/local/bin/proxy_bot.py \
      /etc/systemd/system/alloy.service /usr/local/bin/alloy /etc/alloy -r \
      /etc/letsencrypt/renewal-hooks/deploy/restart-proxy.sh
systemctl daemon-reload
```

`/root/proxy-config.txt` v2 содержит старые пароли — после переноса удалите или перезапишите
(`proxy-admin links admin > /root/proxy-config.txt && chmod 600 /root/proxy-config.txt`).
