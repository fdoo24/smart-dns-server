#!/usr/bin/env bash
# ==============================================================================
# sync_gist.sh — Автоматическая синхронизация доменов из GitHub Gist в SNIProxy
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$BASE_DIR/configs/sniproxy.conf"
CACHE_DOMAINS="$BASE_DIR/configs/domains.txt"

# Загрузка переменных окружения
if [ -f "$BASE_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$BASE_DIR/.env"
fi

DEFAULT_GIST_URL="https://gist.githubusercontent.com/fd25-cyber/06084693e9c14ed6accc0c8e165c2fbf/raw/domains.txt"
GIST_URL="${GIST_URL:-$DEFAULT_GIST_URL}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TMP_RAW="$TMP_DIR/raw_domains.txt"
TMP_CONF="$TMP_DIR/sniproxy.conf.new"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Запрос доменов из: $GIST_URL"

# Скачивание списка доменов
if ! curl -fsSL --max-time 15 "$GIST_URL" -o "$TMP_RAW"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ОШИБКА: Не удалось скачать файл доменов с Gist" >&2
    exit 1
fi

# Проверка на валидность (размер и отсутствие HTML)
if [ ! -s "$TMP_RAW" ] || grep -q -i "<html" "$TMP_RAW"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ОШИБКА: Скачанный файл пустой или содержит HTML-ошибку" >&2
    exit 1
fi

# Проверка наличия правил AdGuard
if ! grep -q '\$dnsrewrite=' "$TMP_RAW"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ОШИБКА: В файле не найдено правил \$dnsrewrite=" >&2
    exit 1
fi

# Формирование нового sniproxy.conf
cat << 'EOF' > "$TMP_CONF"
user daemon
pidfile /var/run/sniproxy.pid

resolver {
    nameserver 8.8.8.8
    nameserver 1.1.1.1
    mode ipv4_only
}

listen 0.0.0.0:443 {
    proto tls
    table https_hosts
}

table https_hosts {
EOF

# Парсинг правил: ||domain.com^$dnsrewrite=... -> .*domain\.com$ *
DOMAIN_COUNT=0
while IFS= read -r line || [ -n "$line" ]; do
    # Пропуск комментариев и пустых строк
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    if [[ "$line" =~ \|\|([^|^]+)\^\$dnsrewrite= ]]; then
        DOMAIN="${BASH_REMATCH[1]}"
        # Экранирование точек для регулярного выражения sniproxy
        ESCAPED_DOMAIN="${DOMAIN//./\\.}"
        echo "    .*${ESCAPED_DOMAIN}\$ *" >> "$TMP_CONF"
        DOMAIN_COUNT=$((DOMAIN_COUNT + 1))
    fi
done < "$TMP_RAW"

echo "}" >> "$TMP_CONF"

# Проверка изменений
if [ -f "$CONFIG_FILE" ] && cmp -s "$CONFIG_FILE" "$TMP_CONF"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Изменений нет (активно доменов: $DOMAIN_COUNT). Перезапуск не требуется."
    exit 0
fi

# Сохранение обновленного конфига
cp "$TMP_CONF" "$CONFIG_FILE"
cp "$TMP_RAW" "$CACHE_DOMAINS"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Конфигурация обновлена (правил: $DOMAIN_COUNT)."

# Перезапуск контейнера SNIProxy
if command -v docker >/dev/null 2>&1; then
    if docker ps -q -f name=smart-dns-sniproxy | grep -q .; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Перезапуск контейнера smart-dns-sniproxy..."
        docker restart smart-dns-sniproxy >/dev/null
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SNIProxy успешно перезапущен с новыми правилами."
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Контейнер smart-dns-sniproxy не запущен, пропуск перезапуска."
    fi
fi
