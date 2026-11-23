#!/usr/bin/env bash
# ==============================================================================
# setup_ssl.sh — Автоматический выпуск Wildcard SSL-сертификата через DuckDNS + acme.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
SSL_DIR="$BASE_DIR/ssl"

mkdir -p "$SSL_DIR"

# Загрузка переменных окружения
if [ -f "$BASE_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$BASE_DIR/.env"
fi

DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN:-}"
DUCKDNS_TOKEN="${DUCKDNS_TOKEN:-}"

if [ -z "$DUCKDNS_DOMAIN" ] || [ -z "$DUCKDNS_TOKEN" ]; then
    echo "ОШИБКА: DUCKDNS_DOMAIN и DUCKDNS_TOKEN должны быть заданы в .env" >&2
    echo "Пример:" >&2
    echo "  DUCKDNS_DOMAIN=videohub25.duckdns.org" >&2
    echo "  DUCKDNS_TOKEN=a1b2c3d4-e5f6-..." >&2
    exit 1
fi

echo "=========================================================="
echo " Выпуск Wildcard SSL для *.$DUCKDNS_DOMAIN"
echo "=========================================================="

# Проверка и установка зависимостей
command -v curl >/dev/null 2>&1 || { apt-get update && apt-get install -y curl; }
command -v socat >/dev/null 2>&1 || { apt-get update && apt-get install -y socat; }

# Установка acme.sh при необходимости
ACME="$HOME/.acme.sh/acme.sh"
if [ ! -f "$ACME" ]; then
    echo "[1/4] Установка утилиты acme.sh..."
    curl -sSL https://get.acme.sh | sh -s email="admin@${DUCKDNS_DOMAIN}"
    # shellcheck disable=SC1090
    [ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"
fi

if [ ! -f "$ACME" ]; then
    echo "ОШИБКА: acme.sh не найден по пути $ACME" >&2
    exit 1
fi

echo "[2/4] Настройка провайдера Let's Encrypt..."
"$ACME" --set-default-ca --server letsencrypt

echo "[3/4] Запрос Wildcard-сертификата через DuckDNS API..."
export DuckDNS_Token="$DUCKDNS_TOKEN"

# Выпуск сертификата на основной домен и wildcard (*.домен)
"$ACME" --issue --dns dns_duckdns \
    -d "$DUCKDNS_DOMAIN" \
    -d "*.$DUCKDNS_DOMAIN" \
    --force

echo "[4/4] Копирование сертификатов в $SSL_DIR..."
"$ACME" --install-cert -d "$DUCKDNS_DOMAIN" \
    --key-file "$SSL_DIR/privkey.pem" \
    --fullchain-file "$SSL_DIR/fullchain.pem" \
    --reloadcmd "if command -v docker >/dev/null 2>&1; then docker restart smart-dns-adguard 2>/dev/null || true; fi"

chmod 644 "$SSL_DIR/fullchain.pem"
chmod 600 "$SSL_DIR/privkey.pem"

echo ""
echo "✅ Сертификат успешно выпущен и установлен:"
echo "   Ключ:        $SSL_DIR/privkey.pem"
echo "   Сертификат:  $SSL_DIR/fullchain.pem"
echo "   Автопродление настроено в acme.sh по cron каждые 60 дней."
