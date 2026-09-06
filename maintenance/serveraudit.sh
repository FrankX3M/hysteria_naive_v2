#!/usr/bin/env bash
#
# serveraudit.sh — исчерпывающий аудит Debian-сервера:
#   железо/ресурсы, systemd-сервисы, docker/docker-compose,
#   и поиск "мусора", который можно безопасно удалить.
#
# РЕЖИМ РАБОТЫ: только чтение (read-only). Скрипт НИЧЕГО не удаляет
# и не изменяет — он только собирает информацию и в конце печатает
# ГОТОВЫЕ КОМАНДЫ, которые вы можете просмотреть и выполнить вручную.
#
# Использование:
#   sudo bash serveraudit.sh                 # полный отчёт в файл + на экран
#   sudo bash serveraudit.sh --top 50        # топ-50 больших файлов вместо 30
#   sudo bash serveraudit.sh --min-size 200M # порог "больших файлов"
#   sudo bash serveraudit.sh --output /root/audit.txt
#
# Рекомендуется запускать с sudo — иначе часть данных (journalctl, docker,
# некоторые каталоги) будет недоступна и попадёт в отчёт как "нет доступа".

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Параметры
# ---------------------------------------------------------------------------
TOP_N=30
MIN_SIZE="100M"
TS="$(date +%Y%m%d_%H%M%S)"
OUTFILE="./server-audit_${TS}.txt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --top) TOP_N="$2"; shift 2 ;;
    --min-size) MIN_SIZE="$2"; shift 2 ;;
    --output) OUTFILE="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Неизвестный параметр: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Инфраструктура вывода: пишем одновременно в файл и на экран
# ---------------------------------------------------------------------------
exec > >(tee "$OUTFILE") 2>&1

IS_ROOT=0
[[ $EUID -eq 0 ]] && IS_ROOT=1

HAS_DOCKER=0; command -v docker >/dev/null 2>&1 && HAS_DOCKER=1
DOCKER_OK=0
if [[ $HAS_DOCKER -eq 1 ]] && docker info >/dev/null 2>&1; then
  DOCKER_OK=1
fi
HAS_COMPOSE_PLUGIN=0; docker compose version >/dev/null 2>&1 && HAS_COMPOSE_PLUGIN=1
HAS_COMPOSE_BIN=0; command -v docker-compose >/dev/null 2>&1 && HAS_COMPOSE_BIN=1
HAS_SNAP=0; command -v snap >/dev/null 2>&1 && HAS_SNAP=1
HAS_JOURNALCTL=0; command -v journalctl >/dev/null 2>&1 && HAS_JOURNALCTL=1

declare -a RECOMMENDATIONS=()
add_rec() { RECOMMENDATIONS+=("$1"); }

hr()   { printf '%.0s=' {1..80}; printf '\n'; }
sub()  { printf -- '-%.0s' {1..80}; printf '\n'; }
section() { echo; hr; echo "  $1"; hr; }
subsection() { echo; sub; echo "  $1"; sub; }

run() {
  # run "описание" -- команда...
  local desc="$1"; shift
  echo "\$ $*"
  if ! "$@" 2>&1; then
    echo "[!] Команда завершилась с ошибкой или недоступна: $desc"
  fi
  echo
}

# ===========================================================================
section "0. ОБЩАЯ ИНФОРМАЦИЯ ОБ ОТЧЁТЕ"
# ===========================================================================
echo "Дата генерации : $(date)"
echo "Хост           : $(hostname -f 2>/dev/null || hostname)"
echo "Запущено от    : $(whoami) (root: $IS_ROOT)"
echo "Файл отчёта    : $OUTFILE"
if [[ $IS_ROOT -eq 0 ]]; then
  echo
  echo "[!] Скрипт запущен БЕЗ root. Часть разделов (journalctl, docker,"
  echo "    некоторые системные каталоги) может быть неполной или недоступной."
  echo "    Рекомендуется перезапустить: sudo bash $0"
fi

# ===========================================================================
section "1. СИСТЕМА"
# ===========================================================================
subsection "ОС и ядро"
run "os-release" cat /etc/os-release
run "uname" uname -a
echo "Работает с: $(uptime -p 2>/dev/null || uptime)"

subsection "CPU"
run "lscpu" lscpu 2>/dev/null || run "cpuinfo" grep -m1 "model name" /proc/cpuinfo

subsection "Память"
run "free" free -h
echo "Top-10 процессов по RSS:"
ps -eo pid,ppid,user,%mem,%cpu,rss,cmd --sort=-rss | head -n 11

subsection "Загрузка системы"
run "loadavg" cat /proc/loadavg
echo "Top-10 процессов по CPU:"
ps -eo pid,ppid,user,%cpu,%mem,cmd --sort=-%cpu | head -n 11

# ===========================================================================
section "2. ДИСКОВОЕ ПРОСТРАНСТВО"
# ===========================================================================
subsection "Смонтированные файловые системы"
run "df" df -hT -x tmpfs -x devtmpfs -x squashfs

subsection "inode (иногда место есть, а inode кончились)"
run "df -i" df -hiT -x tmpfs -x devtmpfs -x squashfs

subsection "Крупнейшие каталоги верхнего уровня (глубина 2)"
for d in /var /home /opt /usr /srv /root; do
  if [[ -d "$d" ]]; then
    echo "--- $d ---"
    du -xh --max-depth=2 "$d" 2>/dev/null | sort -rh | head -n 15
    echo
  fi
done

subsection "Топ-$TOP_N самых больших файлов на диске (> $MIN_SIZE, исключая /proc,/sys,/dev)"
find / -xdev -xautofs -type f -size +"$MIN_SIZE" \
    \( -path /proc -o -path /sys -o -path /dev \) -prune -o \
    -type f -size +"$MIN_SIZE" -printf '%s\t%p\n' 2>/dev/null \
  | sort -rn | head -n "$TOP_N" \
  | awk -F'\t' '{printf "%10.1f MB   %s\n", $1/1024/1024, $2}'

# ===========================================================================
section "3. SYSTEMD: СЕРВИСЫ И ТАЙМЕРЫ"
# ===========================================================================
subsection "Запущенные сервисы"
run "running services" systemctl list-units --type=service --state=running --no-pager --no-legend

subsection "Включённые в автозагрузку (enabled)"
run "enabled services" systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend

subsection "Сервисы с ошибками (failed)"
run "failed" systemctl --failed --no-pager --no-legend

subsection "Активные таймеры (cron-подобные)"
run "timers" systemctl list-timers --all --no-pager --no-legend

subsection "Замаскированные/статические сервисы, занимающие ресурсы диска (журналы юнитов)"
echo "Топ-15 сервисов по объёму их логов в journald:"
if [[ $HAS_JOURNALCTL -eq 1 ]]; then
  journalctl --no-pager -F _SYSTEMD_UNIT 2>/dev/null | while read -r unit; do
    [[ -z "$unit" ]] && continue
    size=$(journalctl -u "$unit" --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | tail -1)
    echo -e "${size:-0}\t$unit"
  done | sort -rh | head -n 15
fi

# ===========================================================================
section "4. JOURNALD (системные логи)"
# ===========================================================================
if [[ $HAS_JOURNALCTL -eq 1 ]]; then
  run "journal disk usage" journalctl --disk-usage
  echo "Каталоги журнала:"
  du -sh /var/log/journal 2>/dev/null
  du -sh /run/log/journal 2>/dev/null
  add_rec "# Очистить журналы systemd старше 7 дней (или ограничить по размеру):
sudo journalctl --vacuum-time=7d
sudo journalctl --vacuum-size=500M"
else
  echo "journalctl не найден (не systemd-journald или не установлен)."
fi

# ===========================================================================
section "5. /var/log (файловые логи)"
# ===========================================================================
run "size" du -sh /var/log 2>/dev/null
subsection "Топ-20 крупнейших файлов в /var/log"
find /var/log -xdev -type f -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n 20 \
  | awk -F'\t' '{printf "%10.1f MB   %s\n", $1/1024/1024, $2}'
subsection "Уже сжатые/ротированные логи (*.gz, *.1, *.old)"
find /var/log -xdev -type f \( -name '*.gz' -o -name '*.old' -o -regex '.*\.[0-9]+$' \) \
  -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n 20 \
  | awk -F'\t' '{printf "%10.1f MB   %s\n", $1/1024/1024, $2}'
if command -v logrotate >/dev/null 2>&1; then
  echo
  echo "logrotate установлен: $(logrotate --version 2>&1 | head -1)"
fi
add_rec "# Если логи большие, но нужны — настройте logrotate (/etc/logrotate.d/),
# а не удаляйте вручную. Уже сжатые ротированные логи (*.gz) обычно можно
# смело удалять, если ретеншн вас устраивает:
#   find /var/log -type f -name '*.gz' -mtime +30 -delete"

# ===========================================================================
section "6. DOCKER"
# ===========================================================================
if [[ $HAS_DOCKER -eq 0 ]]; then
  echo "Docker не установлен."
elif [[ $DOCKER_OK -eq 0 ]]; then
  echo "[!] Docker установлен, но демон недоступен для текущего пользователя."
  echo "    Запустите скрипт с sudo или добавьте пользователя в группу docker."
else
  echo "Docker версия: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"

  subsection "Сводка использования диска Docker'ом (уже посчитанный reclaimable)"
  run "docker system df" docker system df
  run "docker system df -v" docker system df -v

  subsection "Все контейнеры (включая остановленные)"
  run "docker ps -a" docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Size}}'

  subsection "Остановленные контейнеры (кандидаты на удаление)"
  EXITED=$(docker ps -a --filter status=exited --filter status=created --format '{{.Names}}\t{{.Status}}')
  echo "${EXITED:-нет остановленных контейнеров}"

  subsection "Образы: висящие (dangling, без тега — точно мусор)"
  DANGLING_IMG=$(docker images -f dangling=true --format '{{.ID}}\t{{.Size}}\t{{.CreatedSince}}')
  echo "${DANGLING_IMG:-нет висящих образов}"

  subsection "Образы: неиспользуемые (не привязаны ни к одному контейнеру)"
  run "unused images" docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.ID}}'

  subsection "Тома (volumes): неиспользуемые (dangling)"
  DANGLING_VOL=$(docker volume ls -f dangling=true --format '{{.Name}}')
  if [[ -n "$DANGLING_VOL" ]]; then
    echo "$DANGLING_VOL" | while read -r v; do
      [[ -z "$v" ]] && continue
      sz=$(docker run --rm -v "${v}:/vol" alpine sh -c 'du -sh /vol 2>/dev/null | cut -f1' 2>/dev/null)
      echo -e "${v}\t${sz:-?}"
    done
  else
    echo "нет неиспользуемых томов"
  fi

  subsection "Сети: неиспользуемые (custom, без подключённых контейнеров)"
  run "unused networks" docker network ls --filter dangling=true

  subsection "Build cache"
  run "docker builder du" docker builder du 2>/dev/null

  subsection "Логи контейнеров (json-file драйвер) — частая причина разросшегося /var/lib/docker"
  if [[ -d /var/lib/docker/containers ]]; then
    find /var/lib/docker/containers -maxdepth 1 -type d -name '*-*' 2>/dev/null | while read -r cdir; do
      for f in "$cdir"/*-json.log; do
        [[ -f "$f" ]] || continue
        sz=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
        cid=$(basename "$cdir")
        name=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')
        echo -e "${sz}\t${name:-$cid}\t$f"
      done
    done | sort -rn | head -n 15 \
      | awk -F'\t' '{printf "%10.1f MB   %-30s %s\n", $1/1024/1024, $2, $3}'
    echo
    if [[ -f /etc/docker/daemon.json ]]; then
      echo "Текущая конфигурация логирования (/etc/docker/daemon.json):"
      cat /etc/docker/daemon.json
    else
      echo "[!] /etc/docker/daemon.json отсутствует — по умолчанию логи контейнеров"
      echo "    НЕ ротируются и НЕ ограничены по размеру. Это частая причина"
      echo "    внезапного заполнения диска."
    fi
  fi

  subsection "docker-compose проекты, обнаруженные на диске"
  COMPOSE_FILES=$(find / -xdev -maxdepth 8 \
      \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \
         -o -name 'compose.yml' -o -name 'compose.yaml' \) \
      -not -path '*/node_modules/*' 2>/dev/null)
  if [[ -n "$COMPOSE_FILES" ]]; then
    echo "$COMPOSE_FILES" | while read -r f; do
      [[ -z "$f" ]] && continue
      dir=$(dirname "$f")
      echo "--- $f ---"
      if [[ $HAS_COMPOSE_PLUGIN -eq 1 ]]; then
        (cd "$dir" && docker compose ps 2>/dev/null | sed 's/^/    /')
      elif [[ $HAS_COMPOSE_BIN -eq 1 ]]; then
        (cd "$dir" && docker-compose ps 2>/dev/null | sed 's/^/    /')
      fi
    done
  else
    echo "Файлы compose не найдены (искали до 8 уровней вложенности)."
  fi

  add_rec "# --- DOCKER: посмотрите точные цифры в 'docker system df -v' выше, затем: ---
# Удалить только висящие образы (без тега) — почти всегда безопасно:
docker image prune -f
# Удалить остановленные контейнеры:
docker container prune -f
# Удалить неиспользуемые (не dangling) образы, сети, контейнеры сразу:
docker system prune -f
# ОСТОРОЖНО: удалить ещё и неиспользуемые volumes (может стереть данные БД
# и т.п., если они не примонтированы к активному контейнеру!):
docker system prune -a -f --volumes
# Если у вас нет /etc/docker/daemon.json — ограничьте логи контейнеров:
#   {\"log-driver\": \"json-file\", \"log-opts\": {\"max-size\": \"10m\", \"max-file\": \"3\"}}
# затем: sudo systemctl restart docker  (перезапустит ВСЕ контейнеры!)
# Если нужно немедленно освободить место без рестарта — можно безопасно
# обнулить текущий лог-файл работающего контейнера:
#   sudo truncate -s 0 /var/lib/docker/containers/<ID>/<ID>-json.log"
fi

# ===========================================================================
section "7. ПАКЕТЫ (APT / dpkg)"
# ===========================================================================
subsection "Кэш скачанных .deb пакетов"
run "apt cache size" du -sh /var/cache/apt/archives 2>/dev/null

subsection "Пакеты-кандидаты на autoremove"
if command -v apt-get >/dev/null 2>&1; then
  apt-get --dry-run autoremove 2>/dev/null | grep -E '^(Remv|The following packages)' | head -n 40
fi

subsection "Установленные ядра vs текущее"
echo "Текущее загруженное ядро: $(uname -r)"
dpkg -l 'linux-image-*' 2>/dev/null | grep '^ii' | awk '{print $2}'

add_rec "# --- APT: старые ядра и ненужные зависимости ---
sudo apt-get autoremove --purge
sudo apt-get clean          # полностью чистит /var/cache/apt/archives
sudo apt-get autoclean      # чистит только устаревшие версии в кэше (безопаснее)
# Старые ядра (НЕ удаляйте то, что сейчас загружено — см. 'uname -r' выше!):
#   sudo apt-get purge linux-image-<старая-версия>"

# ===========================================================================
section "8. ВРЕМЕННЫЕ ФАЙЛЫ И КЭШИ"
# ===========================================================================
subsection "/tmp и /var/tmp"
du -sh /tmp /var/tmp 2>/dev/null
echo "Файлов в /tmp старше 30 дней: $(find /tmp -xdev -type f -mtime +30 2>/dev/null | wc -l)"

subsection "Кэши пакетных менеджеров (npm/yarn/pip/go/cargo)"
for c in "$HOME/.npm" "$HOME/.cache/yarn" "$HOME/.cache/pip" "$HOME/go/pkg/mod/cache" "$HOME/.cargo/registry" "/root/.npm" "/root/.cache/pip" "/root/.cache/yarn"; do
  [[ -d "$c" ]] && du -sh "$c" 2>/dev/null
done

subsection "Core dump файлы"
find / -xdev \( -name 'core' -o -name 'core.[0-9]*' \) -type f -printf '%s\t%p\n' 2>/dev/null \
  | sort -rn | head -n 10 | awk -F'\t' '{printf "%10.1f MB   %s\n", $1/1024/1024, $2}'

if [[ $HAS_SNAP -eq 1 ]]; then
  subsection "Snap: старые ревизии (disabled)"
  snap list --all 2>/dev/null | awk '/disabled/{print}'
  add_rec "# Snap хранит старые ревизии пакетов — можно удалить неактивные:
snap list --all | awk '/disabled/{print \$1, \$3}' | while read name rev; do sudo snap remove \"\$name\" --revision=\"\$rev\"; done"
fi

subsection "lost+found (если есть — обычно можно чистить на неsystem-разделах, но проверьте содержимое!)"
find / -xdev -maxdepth 3 -type d -name 'lost+found' -exec du -sh {} \; 2>/dev/null

add_rec "# --- Временные файлы ---
sudo find /tmp -xdev -type f -atime +30 -delete
sudo find /var/tmp -xdev -type f -atime +30 -delete"

# ===========================================================================
section "8b. HYSTERIA_NAIVE: ПРАВА НА СЕКРЕТЫ И СОСТОЯНИЕ СЕРВИСОВ"
# ===========================================================================
# Проверка п.19 рекомендаций: файлы с паролями не должны быть читаемы «всем».
if [[ -d /etc/proxy ]]; then
  bad_perms=0
  while IFS= read -r f; do
    [[ -e "$f" ]] || continue
    mode="$(stat -c '%a' "$f")"; owner="$(stat -c '%U:%G' "$f")"
    if [[ "${mode: -1}" != "0" ]]; then
      echo "[!] $f: права $mode ($owner) — доступен всем на чтение"
      bad_perms=1
    else
      echo "ok  $f: $mode ($owner)"
    fi
  done < <(printf '%s\n' /etc/proxy/install.env /etc/proxy/secrets.env /etc/proxy/users.json \
                          /etc/proxy/certs/privkey.pem /etc/hysteria/config.yaml \
                          /opt/naiveproxy/config/config.json /root/proxy-config.txt)
  [[ $bad_perms -eq 1 ]] && add_rec "# --- hysteria_naive: закрыть права на секреты ---
sudo chmod 640 /etc/proxy/*.env /etc/proxy/users.json /etc/hysteria/config.yaml /opt/naiveproxy/config/config.json
sudo chmod 600 /root/proxy-config.txt"
  echo
  for u in hysteria-server proxy-authd proxy-bot proxy-watchdog.timer proxy-backup.timer fail2ban; do
    printf '%-24s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || echo 'n/a')"
  done
  printf '%-24s %s\n' "naiveproxy (docker)" "$(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' naiveproxy 2>/dev/null || echo 'n/a')"
  printf '%-24s %s\n' "nft table inet proxy" "$(nft list table inet proxy >/dev/null 2>&1 && echo loaded || echo MISSING)"
  ls -1t /var/backups/proxy 2>/dev/null | head -3 | sed 's/^/последние бэкапы: /'
else
  echo "hysteria_naive не установлен (нет /etc/proxy)"
fi

# ===========================================================================
section "9. СВОДНЫЕ РЕКОМЕНДАЦИИ (ничего не выполнялось автоматически!)"
# ===========================================================================
echo "Ниже — команды-кандидаты на основе того, что обнаружил скрипт."
echo "ПЕРЕД выполнением любой команды прочитайте её и проверьте на своих данных —"
echo "особенно всё, что касается docker volumes и старых ядер."
echo
for r in "${RECOMMENDATIONS[@]}"; do
  echo "$r"
  echo
done

hr
echo "Отчёт сохранён в: $OUTFILE"
hr
