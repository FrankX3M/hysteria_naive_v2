#!/usr/bin/env bash
#
# servercleanup.sh — ежедневная БЕЗОПАСНАЯ очистка сервера.
#
# Делает только то, что было размечено как "безопасно" в аудите
# (serveraudit.sh) и обсуждалось в переписке. Осознанно НЕ включено:
#   - docker system prune -a --volumes / удаление НЕ-dangling образов —
#     раз в день автоматически это рискованно (может задеть то, что
#     нужно, но временно не запущено);
#   - удаление старых ядер сверх того, что и так безопасно решает
#     apt-get autoremove (apt не удаляет пакет текущего запущенного ядра);
#   - /var/log/btmp* (лог неудачных входов) — это security-артефакт,
#     удалять его автоматикой не стоит, решение оставлено на человека.
#
# Одна упавшая команда не должна валить весь прогон — поэтому без `set -e`,
# каждый шаг обёрнут и падение логируется, но не прерывает следующие шаги.

set -uo pipefail

LOG_FILE="/var/log/server-cleanup.log"
MAX_LOG_SIZE=$((5*1024*1024))   # 5 МБ — если лог сам разросся, ротируем
TMP_MAX_AGE_DAYS=30
JOURNAL_KEEP="7d"
STOPPED_GRACE="24h"             # не трогать то, что остановлено/висит < суток

if [[ $EUID -ne 0 ]]; then
  echo "Этот скрипт должен выполняться от root (sudo)." >&2
  exit 1
fi

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }

step() {
  local desc="$1"; shift
  log "-> $desc"
  if "$@" >>"$LOG_FILE" 2>&1; then
    log "   OK"
  else
    local rc=$?
    log "   [!] завершилось с кодом $rc, продолжаю дальше"
  fi
}

# --- ротация собственного лога, чтобы он сам не стал новым мусором ---
if [[ -f "$LOG_FILE" ]] && [[ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]]; then
  mv -f "$LOG_FILE" "${LOG_FILE}.1"
fi

log "===================================================================="
log "Старт ежедневной очистки"
DISK_BEFORE=$(df -h / | awk 'NR==2{print $4" своб. из "$2" ("$5" занято)"}')
log "Диск / до очистки: $DISK_BEFORE"

# 1. APT: кэш скачанных .deb + осиротевшие пакеты
if command -v apt-get >/dev/null 2>&1; then
  step "apt-get clean (кэш .deb-пакетов)" apt-get clean
  step "apt-get autoremove (осиротевшие зависимости)" apt-get autoremove --purge -y
else
  log "apt-get не найден, пропускаю раздел APT"
fi

# 2. journald: держим только последние N дней
if command -v journalctl >/dev/null 2>&1; then
  step "journalctl --vacuum-time=$JOURNAL_KEEP" journalctl --vacuum-time="$JOURNAL_KEEP"
else
  log "journalctl не найден, пропускаю"
fi

# 3. Docker — только заведомо безопасные операции с запасом в 24ч
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  step "docker image prune (только dangling, старше $STOPPED_GRACE)" \
    docker image prune -f --filter "until=$STOPPED_GRACE"
  step "docker container prune (только exited, старше $STOPPED_GRACE)" \
    docker container prune -f --filter "until=$STOPPED_GRACE"
  step "docker builder prune (build cache старше 10д)" \
    docker builder prune -f --filter "until=240h"
elif command -v docker >/dev/null 2>&1; then
  log "docker установлен, но демон недоступен — пропускаю раздел Docker"
else
  log "docker не найден, пропускаю раздел Docker"
fi

# 4. Кэши пакетных менеджеров root-пользователя
if command -v npm >/dev/null 2>&1; then
  step "npm cache clean --force" npm cache clean --force
fi
if command -v pip3 >/dev/null 2>&1; then
  step "pip3 cache purge" pip3 cache purge
elif command -v pip >/dev/null 2>&1; then
  step "pip cache purge" pip cache purge
fi

# 5. Временные файлы старше 30 дней
step "очистка /tmp (файлы старше ${TMP_MAX_AGE_DAYS}д)" \
  find /tmp -xdev -type f -atime +"$TMP_MAX_AGE_DAYS" -delete
step "очистка /var/tmp (файлы старше ${TMP_MAX_AGE_DAYS}д)" \
  find /var/tmp -xdev -type f -atime +"$TMP_MAX_AGE_DAYS" -delete

DISK_AFTER=$(df -h / | awk 'NR==2{print $4" своб. из "$2" ("$5" занято)"}')
log "Диск / после очистки: $DISK_AFTER"
log "Готово."
log "===================================================================="
