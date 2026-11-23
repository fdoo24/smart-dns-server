#!/usr/bin/env bash
# ==============================================================================
# install.sh — Полное автоматическое развертывание Smart DNS на сервере
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "ОШИБКА: Этот скрипт должен быть запущен с правами root (sudo $0)" >&2
    exit 1
fi

echo "=========================================================="
echo "   Установка Smart DNS Server (AdGuard Home + SNIProxy)   "
echo "=========================================================="

cd "$BASE_DIR"

# 1. Проверка и установка системных пакетов (Docker, curl, cron)
echo "[1/6] Проверка системных компонентов..."
apt-get update -qq
apt-get install -y -qq curl socat cron ca-certificates

if ! command -v docker >/dev/null 2>&1; then
    echo "Установка Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

# 2. Настройка конфигурационного файла .env
echo "[2/6] Настройка переменных окружения (.env)..."
if [ ! -f "$BASE_DIR/.env" ]; then
    DETECTED_IP="$(curl -s --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')"

    if [ -t 0 ]; then
        echo ""
        echo "Введите параметры настройки сервера:"
        read -rp "Внешний IP сервера [$DETECTED_IP]: " INPUT_IP
        SERVER_IP="${INPUT_IP:-$DETECTED_IP}"

        read -rp "Домен DuckDNS (например, mysmartdns.duckdns.org): " DUCKDNS_DOMAIN
        read -rp "Токен DuckDNS (UUID со страницы duckdns.org): " DUCKDNS_TOKEN

        DEFAULT_GIST="https://gist.githubusercontent.com/fd25-cyber/06084693e9c14ed6accc0c8e165c2fbf/raw/domains.txt"
        read -rp "URL списка доменов Gist [$DEFAULT_GIST]: " INPUT_GIST
        GIST_URL="${INPUT_GIST:-$DEFAULT_GIST}"

        cat << EOF > "$BASE_DIR/.env"
SERVER_IP=$SERVER_IP
DUCKDNS_DOMAIN=$DUCKDNS_DOMAIN
DUCKDNS_TOKEN=$DUCKDNS_TOKEN
GIST_URL=$GIST_URL
AG_WEB_PORT=3000
EOF
    else
        echo "Файл .env не найден! Скопируйте .env.example в .env и заполните параметры." >&2
        exit 1
    fi
fi

# shellcheck disable=SC1091
source "$BASE_DIR/.env"

# 3. Создание необходимых директорий
echo "[3/6] Подготовка рабочих каталогов..."
mkdir -p "$BASE_DIR/ssl"
mkdir -p "$BASE_DIR/configs"
mkdir -p "$BASE_DIR/data/ag-work"
mkdir -p "$BASE_DIR/data/ag-conf"

# 4. Выпуск Wildcard SSL-сертификата
echo "[4/6] Выпуск SSL сертификата для *.$DUCKDNS_DOMAIN..."
chmod +x "$BASE_DIR/scripts/setup_ssl.sh"
"$BASE_DIR/scripts/setup_ssl.sh"

# 5. Синхронизация доменов для SNIProxy
echo "[5/6] Первичная синхронизация доменов Gist..."
chmod +x "$BASE_DIR/scripts/sync_gist.sh"
"$BASE_DIR/scripts/sync_gist.sh"

# Настройка cron для ежечасного обновления доменов
CRON_FILE="/etc/cron.d/smart-dns-sync"
cat << EOF > "$CRON_FILE"
# Ежечасная автосинхронизация доменов Smart DNS из Gist
0 * * * * root $BASE_DIR/scripts/sync_gist.sh >> /var/log/smart-dns-sync.log 2>&1
EOF
chmod 644 "$CRON_FILE"
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true

# 6. Запуск Docker контейнеров
echo "[6/6] Запуск контейнеров через Docker Compose..."
if docker compose version >/dev/null 2>&1; then
    docker compose up -d
else
    docker-compose up -d
fi

echo ""
echo "=========================================================="
echo "🎉 Smart DNS Server успешно запущен!"
echo "=========================================================="
echo ""
echo "Параметры доступа:"
echo "  • Веб-интерфейс AdGuard Home: http://${SERVER_IP}:${AG_WEB_PORT:-3000}"
echo "  • Домен сервера:             ${DUCKDNS_DOMAIN}"
echo "  • Статус SNIProxy:            Порт 443 (активен)"
echo "  • Статус DNS/DoT:             Порты 53 и 853 (активны)"
echo ""
echo "Первичная настройка AdGuard Home (в браузере):"
echo "  1. Откройте http://${SERVER_IP}:${AG_WEB_PORT:-3000}"
echo "  2. Пройдите мастер начальной настройки (укажите логин/пароль администратора)."
echo "  3. В меню 'Настройки' -> 'Настройки шифрования':"
echo "     - Включите шифрование (HTTPS/DoT/DoQ)"
echo "     - Имя сервера: ${DUCKDNS_DOMAIN}"
echo "     - Путь к цепочке сертификатов: /opt/adguardhome/ssl/fullchain.pem"
echo "     - Путь к приватному ключу:      /opt/adguardhome/ssl/privkey.pem"
echo "  4. В меню 'Фильтры' -> 'Блокировки DNS' -> 'Добавить черный список':"
echo "     - Имя: Smart DNS Rules"
echo "     - URL: ${GIST_URL}"
echo ""
echo "Как подключать клиентов:"
echo "  • В AdGuard Home: 'Настройки' -> 'Клиенты' -> 'Добавить клиента'"
echo "  • В поле 'Идентификаторы' укажите уникальный префикс (например: user1)"
echo "  • Пользователь на смартфоне/ПК указывает адрес DoT:"
echo "    tls://user1.${DUCKDNS_DOMAIN}:853"
echo "=========================================================="
