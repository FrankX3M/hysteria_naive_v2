#!/usr/bin/env bash
# lib/versions.sh — единственное место, где зафиксированы версии внешних зависимостей.
# Обновлять осознанно, по одной, с проверкой на тестовом сервере.
#
# Откуда брать новые версии:
#   Hysteria2 : https://github.com/apernet/hysteria/releases   (тег app/vX.Y.Z → здесь vX.Y.Z)
#   sing-box  : https://github.com/SagerNet/sing-box/releases  (образ ghcr.io/sagernet/sing-box:<tag>)
#   Python    : tools/requirements.txt (python-telegram-bot, PyYAML)
#
# Docker ставится через get.docker.com (у него нет стабильного пина версии внутри скрипта);
# версия фиксируется на уровне apt после установки: `apt-mark hold docker-ce docker-ce-cli`.

# shellcheck disable=SC2034
HYSTERIA_VERSION="v2.9.2"
SINGBOX_VERSION="v1.13.21"

# Опционально: sha256 бинарника hysteria для вашей архитектуры. Если задано — проверяется.
# Значения берутся со страницы релиза (файл hysteria-linux-<arch>). Пусто = не проверять.
HYSTERIA_SHA256_amd64=""
HYSTERIA_SHA256_arm64=""
