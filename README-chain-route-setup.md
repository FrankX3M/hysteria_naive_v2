# chain-route-setup.sh

*[Английская версия / English version](README-chain-route-setup.en.md)*

Дополнительный скрипт для проекта [hysteria_naive_v2](https://github.com/FrankX3M/hysteria_naive_v2).
Превращает установленный сервер в **мост на второй сервер** с гео-маршрутизацией:
указанные страны и домены идут напрямую, всё остальное — через SOCKS5/HTTP-туннель
ко второму серверу. Патчит **оба** входа проекта — NaiveProxy (`sing-box`) и
нативный Hysteria2 (`hysteria-server`, профили `admin-HY2`/`test-HY2`) — одной и
той же политикой доменов/стран, так что не важно, каким протоколом подключается
конкретный клиент.

Типичная схема:

```
                       ┌─(NaiveProxy)──┐
Клиент ────────────────┤               ├──▶ Сервер1 (RU) ──(GeoIP/domain routing)──┬──▶ .ru / .su / .рф / YouTube — напрямую
                       └─(Hysteria2)───┘                                            └──▶ всё остальное — через Hysteria2-туннель
                                                                                          на Сервер2 (например, зарубежный)
```

## Что делает

1. **Настраивает локальный Hysteria2-клиент** на Сервере1 — просит вставить
   `hysteria2://...`/`hy2://...` ссылку Сервера2, устанавливает `hysteria`,
   генерирует `/etc/hysteria/client.yaml`, поднимает `hysteria-client.service`
   (systemd) и проверяет, что туннель реально работает.
2. **Патчит `render_singbox()`** в `tools/proxy_admin.py` проекта так, чтобы
   NaiveProxy-вход:
   - заворачивал весь исходящий трафик в SOCKS5/HTTP клиента из шага 1;
   - пускал напрямую (`direct`) трафик, реально принадлежащий указанным
     странам — по актуальной GeoIP-базе (`sing-geoip`, ветка `rule-set`);
   - пускал напрямую домены из списка исключений (по умолчанию
     `.ru`, `.su`, `.рф` и домены YouTube — редактируется);
   - определял реальный домен по SNI/Host через `sniff`, даже если клиент
     передаёт голый IP вместо домена (важно — часть VPN/прокси-клиентов
     резолвит DNS сама и шлёт на сервер уже IP, из-за чего маршрутизация
     по домену без sniff-а не сработала бы вообще);
   - резолвила домены для обоих outbound'ов принудительно в IPv4
     (`domain_resolver: ipv4_only`), чтобы не было разброса — когда часть
     клиентов получает IPv4 адрес сервера, а часть IPv6.
3. **Патчит `render_hysteria()`** в том же файле — той же политикой, но
   нативным для Hysteria2 механизмом (`outbounds` + `acl.inline`), чтобы
   вход `hysteria-server` (профили `admin-HY2`/`test-HY2`) вёл себя
   идентично NaiveProxy-входу: те же домены и страны — напрямую, всё
   остальное — в тот же локальный SOCKS5/HTTP туннель из шага 1. Включает
   серверный `sniff` Hysteria2 (нужна версия **≥ 2.6.0**) — без него ACL по
   доменам не срабатывает для клиентов, которые резолвят DNS сами и шлют
   на сервер голый IP (см. «Важные детали»).
3a. **Опционально — домены принудительно через цепочку.** Список доменов,
   которые должны идти через второй сервер, даже если попадают под `.ru` или
   GeoIP-страну (например `gosuslugi.ru`). Правило ставится в обоих движках
   *раньше* direct-правил.
3b. **Опционально — reject BitTorrent** на NaiveProxy-входе (sing-box
   определяет протокол через `sniff`), чтобы торренты не улетали через
   второй сервер и не собирали abuse-жалобы от зарубежного хостера.
   На Hysteria2-входе такого правила нет — там ACL не умеет матчить по
   протоколу, отключай прокси в самом торрент-клиенте.
4. Сам находит установленную копию `proxy_admin.py` (через `/usr/local/bin/proxy-admin`)
   и папку конфига NaiveProxy (через `docker inspect naiveproxy`) — руками
   указывать пути не нужно.
5. Скачивает актуальные GeoIP-базы: `geoip-<cc>.srs` для sing-box (`sing-geoip`)
   и единый `geoip.dat` для нативного Hysteria2 (`Loyalsoldier/geoip`).
6. Патчит **идемпотентно** — весь добавленный код в обеих функциях обёрнут
   своими маркерами (`HYSTERIA_NAIVE_CHAIN_ROUTE` для `render_singbox()`,
   `HYSTERIA_NAIVE_CHAIN_ROUTE_HY2` для `render_hysteria()`). Повторный
   запуск полностью пересобирает оба блока с новыми параметрами (смена
   сервера, добавление страны и т.п.), а не плодит дубли и не требует,
   чтобы старый текст совпадал побайтово.
7. Синхронизирует патч в установленную копию (`/opt/proxy/tools/proxy_admin.py`)
   и вызывает `proxy-admin apply`. Эта команда сама валидирует оба конфига
   перед применением — если что-то невалидно, ничего не сломается, старый
   рабочий вариант останется активным, а скрипт завершится с ошибкой и
   выведет точную причину.

## Требования

- Тот же VDS, где уже развёрнут `hysteria_naive_v2` (команда `proxy-admin`
  должна быть в `PATH`, контейнер `naiveproxy` — запущен).
- root.
- `docker`, `python3`, `curl` (обычно уже стоят вместе с проектом).
- Доступ с сервера до `github.com` (для скачивания Hysteria2 и GeoIP-баз).

## Использование

```bash
# Полная настройка: клиент к второму серверу + маршрутизация
sudo bash chain-route-setup.sh
```

Скрипт спросит по очереди:

| Вопрос | Значение по умолчанию |
|---|---|
| Ссылка `hysteria2://...` второго сервера | — (обязательно) |
| Тип цепочки — socks/http | `socks` (адрес и порт клиента из шага 1) |
| Адрес/порт прокси второго сервера | `127.0.0.1:1080` |
| Коды стран для GeoIP-direct (через запятую) | `ru` |
| Домены напрямую (через запятую) | `.ru,.su,.рф,youtube.com,youtu.be,googlevideo.com,ytimg.com,youtube-nocookie.com,ggpht.com,youtubei.googleapis.com,youtube.googleapis.com,youtubekids.com,youtubeeducation.com,gvt1.com,gvt2.com,gvt3.com,video.google.com` |
| Домены принудительно через цепочку | — (пусто; пример: `gosuslugi.ru,gu-st.ru`) |
| Блокировать BitTorrent на NaiveProxy-входе | `N` |

Про поле «Домены напрямую»: введённый список **полностью заменяет** дефолт.
Чтобы просто *добавить* домены к дефолтному списку, начни ввод с `+`:
`+vk.com,mail.ru`. Типичная ошибка при ручной вставке — потерять `youtube.com`
из начала списка; тогда сам `youtube.com` (в т.ч. `redirector.c.youtube.com`)
уходит через цепочку, хотя `googlevideo.com` идёт напрямую. Скрипт печатает
итоговые параметры перед применением — сверь их.

`gstatic.com`, `googleusercontent.com`, `googleapis.com` в дефолт намеренно
не включены: это общая инфраструктура Google (Gmail, Drive, Play, поиск),
и добавив их, ты пустишь напрямую с Сервера1 гораздо больше, чем YouTube.
Видео без них играет нормально.

Если Hysteria-клиент к второму серверу уже настроен и работает — скрипт
спросит, перенастраивать ли его новой ссылкой, а не полезет менять молча.

### Дополнительные режимы

```bash
# Не трогать Hysteria-клиента (он уже настроен вручную) — только маршрутизация
sudo bash chain-route-setup.sh --skip-client

# Обновить только GeoIP-базы (например, по cron раз в неделю —
# диапазоны IP у стран со временем меняются) и перезапустить контейнер
sudo bash chain-route-setup.sh --only-geoip

# Откатить маршрутизацию к чистому direct-only (Hysteria-клиента не трогает)
sudo bash chain-route-setup.sh --undo
```

Чтобы сменить второй сервер или список исключений позже — просто запусти
скрипт снова без флагов, он пересоберёт всё заново с новыми ответами.

## Проверка после применения

```bash
systemctl status hysteria-client        # клиент к второму серверу жив?
systemctl status hysteria-server        # нативный Hysteria2-вход жив?
docker logs naiveproxy --tail 20        # NaiveProxy стартовал без ошибок?
cat /opt/naiveproxy/config/config.json  # итоговый конфиг NaiveProxy с dns/outbounds/route
cat /etc/hysteria/config.yaml           # итоговый конфиг Hysteria2 с outbounds/acl
```

Живой тест маршрутизации на стороне Hysteria2 — включить debug-лог:

```bash
journalctl -u hysteria-server -f
# зайти с клиента admin-HY2/test-HY2 на .ru-сайт и на не-.ru — в логе будет
# видно, каким ACL-правилом (direct(...) или chain-fin(all)) ушло соединение
```

Живой тест маршрутизации — включить debug-лог и посмотреть, куда реально
уходит трафик:

```bash
sed -i 's/"level": "info"/"level": "debug"/' /opt/naiveproxy/config/config.json
docker restart naiveproxy
docker logs -f --since 0s naiveproxy
# зайти с клиента на любой .ru-сайт и на любой не-.ru — в логе будет видно
# router: sniffed protocol / match ... => route(direct) для .ru,
# и outbound/socks[chain-fin] для остального

# вернуть обратно, чтобы не забивать диск:
sed -i 's/"level": "debug"/"level": "info"/' /opt/naiveproxy/config/config.json
docker restart naiveproxy
```

Проверка конечного IP — с двух разных клиентов зайти на `ifconfig.me` /
`myip.com`:
- запрос на `.ru`-домен или YouTube → IP Сервера1 (RU);
- любой другой запрос → IPv4-адрес Сервера2 (второго сервера в цепочке),
  одинаковый для всех клиентов (мобильных и десктопных) — это то, что
  чинит `domain_resolver: ipv4_only`.

Быстрый тест обеих веток из консоли клиента (через прокси):

```bash
curl -s https://api.ipify.org                                      # → IP Сервера2 (цепочка)
curl -s http://redirector.c.youtube.com/report_mapping | head -c 120  # → IP Сервера1 (direct)
```

`redirector.c.youtube.com/report_mapping` возвращает IP, с которого Google
видит запрос, — удобно, чтобы проверить именно YouTube-ветку. Ошибка
`curl: (23) Failure writing output` при `| head` — безобидна (head закрыл пайп).
Прогнать тест стоит с **обоих** типов клиентов — NaiveProxy и HY2-профиль,
они идут через разные движки правил.

## Важные детали реализации

- **Почему нужен `sniff`.** NaiveProxy — это HTTP CONNECT-туннель. Часть
  VPN/прокси-клиентов на устройствах резолвит DNS локально и отправляет на
  сервер сразу IP-адрес вместо домена — тогда правило по `domain_suffix`
  не с чем сравнивать. `sniff` считывает реальный домен из SNI в TLS
  ClientHello (или из HTTP Host для plain HTTP) прямо из потока, независимо
  от того, что было передано в CONNECT — и подставляет его для дальнейшей
  маршрутизации, не меняя фактический адрес соединения.
- **Почему GeoIP, а не только домены.** Часть трафика в принципе не несёт
  домена (например, доступ по IP, часть P2P) или SNI скрыт (ECH). GeoIP по
  IP-диапазонам страны подхватывает такие случаи как страховка поверх
  доменных правил.
- **Почему `domain_resolver: ipv4_only`, а не просто "оставить как есть".**
  Без явного резолвинга sing-box передаёт домен как есть в SOCKS5/HTTP
  прокси второго сервера, и уже ТОТ решает, резолвить в IPv4 или IPv6 —
  из-за чего разные клиенты (в зависимости от их точки входа) видели
  разные адреса выхода. Явный `domain_resolver` заставляет сам sing-box
  резолвить домен по A-записи и передать вниз уже готовый IPv4-адрес.
- **Почему у Hysteria2-стороны другая GeoIP-база.** Нативный Hysteria2
  использует не `sing-geoip`-файлы (те заточены под формат sing-box, `.srs`),
  а свой ACL-движок с полем `acl.geoip: <path к geoip.dat>` — совместимый
  файл (единый, все страны сразу, формат V2Ray/Xray) скрипт качает из
  [`Loyalsoldier/geoip`](https://github.com/Loyalsoldier/geoip) в
  `/etc/hysteria/geoip.dat`. Явно прописанный путь (а не оставленный пустым)
  — чтобы не зависеть от автозакачки Hysteria2 в рабочую директорию процесса
  при старте (`WorkingDirectory=` у systemd-юнита при этом можно не трогать)
  и чтобы `--only-geoip` мог обновлять её тем же понятным способом, что и
  `.srs`-файлы NaiveProxy-стороны.
- **Почему у Hysteria2-ACL синтаксис `outboundName(matcher)`, а не
  `route.rules` как в sing-box.** Это два независимых движка правил разных
  проектов — `render_singbox()` генерирует JSON для `sing-box`
  (`route.rules`/`rule_set`), `render_hysteria()` — YAML для официального
  бинаря `hysteria` (`acl.inline`, правила вида `direct(suffix:example.com)`,
  `direct(geoip:ru)`, последним всегда идёт catch-all `chain_fin(all)`,
  правила проверяются по порядку, срабатывает первое совпадение). Имя
  outbound'а — `chain_fin` с подчёркиванием: ACL-парсер Hysteria2 не
  принимает дефис в имени, `chain-fin(all)` падает с `invalid syntax`.
- **Почему у Hysteria2 нужен серверный `sniff`.** В отличие от sing-box,
  ACL Hysteria2 по умолчанию матчит только то, что прислал клиент в запросе
  на соединение. Многие HY2-клиенты (в т.ч. десктопные с системным TUN)
  резолвят DNS сами и шлют серверу голый IP — тогда `direct(suffix:...)`
  не с чем сравнивать, `geoip:ru` для адреса Google не совпадает, и YouTube
  уходит в `chain_fin(all)`. В логе `hysteria-server` это видно как
  `reqAddr` с IP-адресами вместо доменов. Начиная с Hysteria 2.6.0 есть
  серверная опция `sniff` (HTTP Host / TLS SNI / QUIC), скрипт включает её
  с `rewriteDomain: false` — домен используется только для ACL, соединение
  идёт на тот адрес, который прислал клиент (аналог `sniff` без override в
  sing-box). Если `hysteria version` < 2.6.0, скрипт предупредит и sniff не
  включит — обнови бинарь (`bash <(curl -fsSL https://get.hy2.sh/)`).
- **Почему домены «принудительно через цепочку» стоят первыми.** В обоих
  движках побеждает первое совпавшее правило. `gosuslugi.ru` попадает и под
  `.ru`, и под `geoip:ru`, поэтому единственный способ отправить его на
  Сервер2 — правило `chain-fin`/`chain_fin(suffix:...)` до всех direct-правил.
  Учти, что ряд российских сервисов (Госуслуги/ЕСИА в том числе) периодически
  ограничивают доступ с зарубежных IP — тогда получишь заглушку или капчу;
  это не ошибка маршрутизации.
- **Права на `geoip.dat`.** `hysteria-server` в проекте работает под
  пользователем `hysteria` в песочнице systemd (`ProtectSystem=strict`,
  `ReadOnlyPaths=/etc/hysteria`). Файл `/etc/hysteria/geoip.dat` должен быть
  читаем этим пользователем — скрипт ставит `644`. Если файл окажется
  `640 root:root` (например, после ручного `mv` из `/tmp`), сервер уйдёт в
  цикл перезапуска с `open /etc/hysteria/geoip.dat: permission denied`, причём
  откат `proxy-admin apply` на предыдущий конфиг **не поможет** — старый конфиг
  ссылается на тот же файл. Лечится `chmod 644 /etc/hysteria/geoip.dat`.
- **Синтаксис sing-box меняется между версиями.** Скрипт написан под
  синтаксис sing-box 1.13.x: `action: "sniff"` в `route.rules` (не
  `sniff`/`sniff_override_destination` на inbound — убраны в 1.13) и
  `domain_resolver` на outbound (не `domain_strategy` — deprecated в 1.12,
  требует `ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true` начиная
  с некоторой версии). Если после обновления образа `sing-box` в проекте
  `proxy-admin apply` начнёт падать с `FATAL` про deprecated/legacy поля —
  скрипт нужно будет поправить под новый синтаксис (обычно `sing-box`
  прямо в тексте ошибки даёт ссылку на актуальный раздел миграции:
  `https://sing-box.sagernet.org/migration/`).

## Типичные проблемы

**`proxy-admin apply` пишет «hysteria-server не поднялся с новым конфигом — откатил».**
Смотри `journalctl -u hysteria-server -n 40 --no-pager`. Частые причины:
`permission denied` на `geoip.dat` (см. выше, `chmod 644`); `invalid syntax`
в `acl.inline` — обычно дефис в имени outbound'а или опечатка в домене.
После `apply` обязательно проверь `systemctl is-active hysteria-server`:
если там `activating`, сервер лежит в цикле перезапусков, и HY2-профили
не работают, хотя NaiveProxy-вход жив.

**YouTube идёт через Сервер2 с HY2-клиента, но напрямую с NaiveProxy.**
Это симптом отсутствующего `sniff` на Hysteria2-стороне: в
`journalctl -u hysteria-server -f` `reqAddr` — голые IP. Проверь
`hysteria version` (нужно ≥ 2.6.0) и `grep -A3 '^sniff:' /etc/hysteria/config.yaml`.

**YouTube идёт через Сервер2 с обоих клиентов.** Скорее всего, из списка
доменов выпал `youtube.com`. Проверь:
`grep -c '"youtube.com"' /opt/naiveproxy/config/config.json` и
`grep -c 'suffix:youtube.com)' /etc/hysteria/config.yaml` — оба должны дать `1`.

**В логах много `bittorrent` / `TCP error ... i/o timeout` на порты 6881, 51413.**
Кто-то из клиентов гоняет торрент-клиент через прокси; зарубежные пиры уходят
через Сервер2. Либо включи reject BitTorrent в скрипте (NaiveProxy-вход), либо
выключи прокси в торрент-клиенте.

**Ручные правки блока между маркерами пропадают.** Так и задумано: любой
запуск скрипта пересобирает оба блока целиком. Всё, что хочется сохранить,
должно быть параметром скрипта (домены, страны, принудительная цепочка,
BitTorrent), а не правкой `proxy_admin.py` руками.

## Резервные копии

Перед каждой правкой скрипт сохраняет бэкап патчимого файла рядом с ним:
`tools/proxy_admin.py.bak-<дата-время>` (в git-клоне) и
`/opt/proxy/tools/proxy_admin.py.bak-<дата-время>` (в установленной копии).
Старые бэкапы скрипт сам не удаляет — почисти их со временем вручную, если
накопится много.
