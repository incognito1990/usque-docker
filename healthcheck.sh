#!/usr/bin/env bash
# healthcheck.sh — проверка живости контейнера.
#
#   tun  — интерфейс существует, поднят и на нём есть адрес из конфига;
#          опционально (HEALTHCHECK_TUNNEL=1) — реальная проверка туннеля
#          через cloudflare trace (warp=on).
#   socks/http-proxy/l4-* — порт слушается.
#   portfw — достаточно живого процесса usque.

set -uo pipefail

is_true() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on|y) return 0 ;;
        *)               return 1 ;;
    esac
}

MODE_RAW="${USQUE_MODE:-tun}"
case "$(printf '%s' "$MODE_RAW" | tr '[:upper:]' '[:lower:]')" in
    tun|native|nativetun|vpn)         MODE=nativetun ;;
    socks|socks5)                     MODE=socks;          PORT="${USQUE_SOCKS_PORT:-1080}" ;;
    http|http-proxy|http_proxy|proxy) MODE=http-proxy;     PORT="${USQUE_HTTP_PORT:-8000}" ;;
    l4-socks|l4socks)                 MODE=l4-socks;       PORT="${USQUE_SOCKS_PORT:-1080}" ;;
    l4-http|l4-http-proxy)            MODE=l4-http-proxy;  PORT="${USQUE_HTTP_PORT:-8000}" ;;
    portfw|port-forward|forward)      MODE=portfw ;;
    *)                                MODE=nativetun ;;
esac

IFACE="${USQUE_IFACE:-usque-tun}"

# процесс usque жив, иначе всё остальное неважно
if ! pgrep -x usque >/dev/null 2>&1; then
    echo "usque не запущен"
    exit 1
fi

if [ "$MODE" = "nativetun" ]; then
    if ! ip link show dev "$IFACE" >/dev/null 2>&1; then
        echo "интерфейс ${IFACE} не найден"
        exit 1
    fi
    if ! ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q 'inet '; then
        echo "на ${IFACE} нет IPv4-адреса"
        exit 1
    fi
    if is_true "${HEALTHCHECK_TUNNEL:-0}"; then
        if ! curl -fsS -m 8 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -q '^warp=on'; then
            echo "туннель не отвечает (warp != on)"
            exit 1
        fi
    fi
    echo "ok: ${IFACE} поднят"
    exit 0
fi

if [ "$MODE" = "portfw" ]; then
    echo "ok: portfw работает"
    exit 0
fi

if ! ss -ltn 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"; then
    echo "порт ${PORT} не слушается"
    exit 1
fi

echo "ok: ${MODE} слушает ${PORT}"
exit 0
