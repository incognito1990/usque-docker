#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh — контейнер usque (MASQUE-клиент Cloudflare WARP)
#
# Задачи:
#   1. найти/подготовить конфиг (WARP consumer или Zero Trust);
#   2. собрать команду usque под выбранный режим (tun / socks / http-proxy / ...);
#   3. запомнить исходный маршрут по умолчанию — он нужен хуку маршрутизации;
#   4. запустить один или несколько режимов одновременно.
#
# Все переменные описаны в .env.example и README.md.
# =============================================================================

set -Eeuo pipefail

ts()   { date -u +%H:%M:%S; }
log()  { printf '%s [init] %s\n' "$(ts)" "$*" >&2; }
warn() { printf '%s [init] %s\n' "$(ts)" "$*" >&2; }
die()  { printf '%s [init] FATAL: %s\n' "$(ts)" "$*" >&2; exit 1; }

is_true() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on|y) return 0 ;;
        *)               return 1 ;;
    esac
}

# ------------------------------------------------------------------ настройки
CONFIG="${USQUE_CONFIG:-/etc/usque/config.json}"
CONFIG_DIR="$(dirname "$CONFIG")"
HOOK="${USQUE_HOOK:-/usr/local/share/usque/hooks/route-hook.sh}"
ZT_MARKER="${CONFIG_DIR}/.zerotrust"

MODE_RAW="${USQUE_MODE:-tun}"
IFACE="${USQUE_IFACE:-usque-tun}"
BIND="${USQUE_BIND:-0.0.0.0}"
ROUTE_MODE="${ROUTE_MODE:-main}"
REGISTER_MODE="${USQUE_REGISTER:-auto}"
ENROLL_ON_START="${USQUE_ENROLL_ON_START:-0}"

# Приводим режим к каноническому имени подкоманды usque.
case "$(printf '%s' "$MODE_RAW" | tr '[:upper:]' '[:lower:]')" in
    tun|native|nativetun|vpn)         MODE=nativetun ;;
    socks|socks5)                     MODE=socks ;;
    http|http-proxy|http_proxy|proxy) MODE=http-proxy ;;
    l4-socks|l4socks)                 MODE=l4-socks ;;
    l4-http|l4-http-proxy)            MODE=l4-http-proxy ;;
    portfw|port-forward|forward)      MODE=portfw ;;
    register)                         MODE=register ;;
    enroll)                           MODE=enroll ;;
    *) die "неизвестный USQUE_MODE='${MODE_RAW}' — ожидаю tun|socks|http-proxy|l4-socks|l4-http-proxy|portfw|register|enroll" ;;
esac

log "usque $(usque version 2>/dev/null || echo '(версия неизвестна)') | режим=${MODE} | роутинг=${ROUTE_MODE}"

# --------------------------------------------------------------- /dev/net/tun
ensure_tun_node() {
    [ "$MODE" = "nativetun" ] || return 0
    [ -c /dev/net/tun ] && return 0

    log "/dev/net/tun отсутствует — пробую создать (нужны cap NET_ADMIN + MKNOD)"
    mkdir -p /dev/net
    if mknod /dev/net/tun c 10 200 2>/dev/null; then
        chmod 0666 /dev/net/tun
        log "создан узел /dev/net/tun"
    else
        die "не удалось создать /dev/net/tun.
   На хосте: modprobe tun. Либо пробросьте узел в compose:
   devices: [\"/dev/net/tun:/dev/net/tun\"]"
    fi
}

ensure_tun_node

# ------------------------------------------------------------ имя TUN-устройства
if [ "$MODE" = "nativetun" ]; then
    case "$IFACE" in
        ""|*" "*|*/*) die "некорректное USQUE_IFACE='${IFACE}'" ;;
    esac
    if [ "${#IFACE}" -gt 15 ]; then
        die "USQUE_IFACE='${IFACE}' длиннее 15 символов — ядро обрежет имя"
    fi
fi

# ------------------------------------------------------------------ SNI
# Zero Trust ходит на другой SNI: zt-masque.cloudflareclient.com.
# Если SNI не задан явно, определяем по маркеру/наличию JWT.
if [ -z "${USQUE_SNI:-}" ]; then
    if [ -n "${USQUE_JWT:-}" ] || [ -f "$ZT_MARKER" ]; then
        SNI="zt-masque.cloudflareclient.com"
        log "похоже на Zero Trust → SNI=${SNI} (переопределяется USQUE_SNI)"
    else
        SNI=""
    fi
else
    SNI="$USQUE_SNI"
fi

# ------------------------------------------------------------------ конфиг
config_usable() {
    [ -s "$CONFIG" ] || return 1
    jq -e '(.private_key|type=="string" and length>0)
       and (.endpoint_pub_key|type=="string" and length>0)
       and (.ipv4|type=="string" and length>0)' "$CONFIG" >/dev/null 2>&1
}

do_register() {
    local args=(-c "$CONFIG" register -a)
    [ -n "${USQUE_DEVICE_NAME:-}" ] && args+=(-n "$USQUE_DEVICE_NAME")
    [ -n "${USQUE_JWT:-}" ]         && args+=(--jwt "$USQUE_JWT")
    [ -n "${USQUE_LOCALE:-}" ]      && args+=(-l "$USQUE_LOCALE")
    [ -n "${USQUE_MODEL:-}" ]       && args+=(-m "$USQUE_MODEL")

    if [ -n "${USQUE_JWT:-}" ]; then
        log "регистрация в Cloudflare Zero Trust по team-token (JWT)"
    else
        log "регистрация обычного (consumer) WARP-аккаунта"
    fi

    # register спрашивает подтверждение, если конфиг уже существует, а stdin
    # в контейнере неинтерактивный → убираем старый файл.
    if [ -e "$CONFIG" ]; then
        local bak="${CONFIG}.bak.$(date -u +%Y%m%d%H%M%S)"
        mv "$CONFIG" "$bak"
        log "старый конфиг сохранён как ${bak}"
    fi

    usque "${args[@]}" || die "регистрация не удалась (нужен доступ к api.cloudflareclient.com)"
    config_usable || die "после регистрации конфиг ${CONFIG} неполный"

    if [ -n "${USQUE_JWT:-}" ]; then
        : > "$ZT_MARKER"        # запоминаем, что это Zero Trust → верный SNI на следующих стартах
    else
        rm -f "$ZT_MARKER"
    fi
    log "конфиг создан: ${CONFIG}"
}

mkdir -p "$CONFIG_DIR"

case "$REGISTER_MODE" in
    force|1|true|yes) do_register ;;
    never|0|false|no) config_usable || die "конфиг ${CONFIG} отсутствует/не заполнен, а USQUE_REGISTER=never" ;;
    auto|*)           config_usable || do_register ;;
esac

# Одноразовые служебные режимы: docker compose run --rm usque  (USQUE_MODE=register|enroll)
if [ "$MODE" = "register" ]; then
    do_register
    exit 0
fi

if [ "$MODE" = "enroll" ]; then
    log "переобучение ключа (usque enroll)..."
    enroll_args=(-c "$CONFIG" enroll)
    [ -n "${USQUE_DEVICE_NAME:-}" ] && enroll_args+=(-n "$USQUE_DEVICE_NAME")
    is_true "${USQUE_REGEN_KEY:-0}" && enroll_args+=(-r)
    exec usque "${enroll_args[@]}"
fi

# enroll при старте: у Zero Trust адреса и токены живут недолго — полезно освежить.
if is_true "$ENROLL_ON_START"; then
    log "USQUE_ENROLL_ON_START=1 → освежаю ключ перед запуском"
    if usque -c "$CONFIG" enroll; then
        log "enroll выполнен"
    elif is_true "${USQUE_ENROLL_STRICT:-0}"; then
        die "enroll не удался, а USQUE_ENROLL_STRICT=1"
    else
        warn "enroll не удался — продолжаю с текущим конфигом"
    fi
fi

# ------------------------------------------- снимок исходной маршрутизации
# Нужен хуку: по нему восстанавливается default и строится обход эндпоинта.
UPSTREAM_IF="$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
UPSTREAM_GW="$(ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"
UPSTREAM_GW6="$(ip -6 route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"
[ "$UPSTREAM_GW" = "dev" ] && UPSTREAM_GW=""

export UPSTREAM_IF UPSTREAM_GW UPSTREAM_GW6

mkdir -p /run/usque
cat > /run/usque/upstream.env <<EOF
# Снимок маршрутизации, сделанный entrypoint до запуска usque.
UPSTREAM_IF=${UPSTREAM_IF}
UPSTREAM_GW=${UPSTREAM_GW}
UPSTREAM_GW6=${UPSTREAM_GW6}
EOF

if [ -n "$UPSTREAM_IF" ]; then
    log "внешний интерфейс=${UPSTREAM_IF} шлюз=${UPSTREAM_GW:-нет} шлюз6=${UPSTREAM_GW6:-нет}"
else
    warn "маршрут по умолчанию не найден (network_mode: host?)"
    if [ "$ROUTE_MODE" = "main" ]; then
        warn "ROUTE_MODE=main в этом случае сломает сеть — используйте ROUTE_MODE=none или table"
    fi
fi

# ------------------------------------------------------------------- команды
# Набор флагов у подкоманд usque РАЗНЫЙ, поэтому собираем их по «семейству»:
#   tun    — nativetun:      нет -d
#   proxy  — socks/http-proxy: всё
#   l4     — l4-socks/l4-http-proxy: нет -s, --http2, -m, -r, -F/-S
#            (SNI жёстко зашит как consumer-masque-proxy.cloudflareclient.com,
#             и режим работает только поверх QUIC/H3)
#   portfw — нет -l/--system-dns/-t
family_of() {
    case "$1" in
        nativetun)              printf 'tun' ;;
        socks|http-proxy)       printf 'proxy' ;;
        l4-socks|l4-http-proxy) printf 'l4' ;;
        portfw)                 printf 'portfw' ;;
        *)                      printf 'tun' ;;
    esac
}

add_common_flags() {
    local fam="$1" d

    if [ "$fam" = "l4" ]; then
        [ -n "$SNI" ] && warn "l4-* не поддерживает -s: SNI зашит как consumer-masque-proxy.cloudflareclient.com — SNI игнорирую"
        is_true "${USQUE_HTTP2:-0}" && warn "l4-* работает только поверх QUIC/H3 — --http2 игнорирую"
        if is_true "${USQUE_NO_TUNNEL_IPV4:-0}" || is_true "${USQUE_NO_TUNNEL_IPV6:-0}"; then
            warn "l4-* не поддерживает -F/-S — игнорирую"
        fi
    else
        [ -n "$SNI" ] && ARGS+=(-s "$SNI")
    fi

    is_true "${USQUE_IPV6_ENDPOINT:-0}"    && ARGS+=(-6)
    is_true "${USQUE_INSECURE:-0}"         && ARGS+=(--insecure)
    [ -n "${USQUE_CONNECT_PORT:-}" ]        && ARGS+=(-P "$USQUE_CONNECT_PORT")
    [ -n "${USQUE_KEEPALIVE:-}" ]           && ARGS+=(-k "$USQUE_KEEPALIVE")
    [ -n "${USQUE_INITIAL_PACKET_SIZE:-}" ] && ARGS+=(-i "$USQUE_INITIAL_PACKET_SIZE")

    case "$fam" in
        tun|proxy|portfw)
            is_true "${USQUE_HTTP2:-0}"            && ARGS+=(--http2)
            is_true "${USQUE_NO_TUNNEL_IPV4:-0}"   && ARGS+=(-F)
            is_true "${USQUE_NO_TUNNEL_IPV6:-0}"   && ARGS+=(-S)
            is_true "${USQUE_ALWAYS_RECONNECT:-0}" && ARGS+=(--always-reconnect)
            [ -n "${USQUE_MTU:-}" ]                 && ARGS+=(-m "$USQUE_MTU")
            [ -n "${USQUE_RECONNECT_DELAY:-}" ]     && ARGS+=(-r "$USQUE_RECONNECT_DELAY")
            ;;
    esac

    case "$fam" in
        proxy|l4|portfw)
            if [ -n "${USQUE_DNS:-}" ]; then
                for d in $USQUE_DNS; do ARGS+=(-d "$d"); done
            fi
            ;;
    esac

    case "$fam" in
        proxy|l4)
            [ -n "${USQUE_DNS_TIMEOUT:-}" ]        && ARGS+=(-t "$USQUE_DNS_TIMEOUT")
            is_true "${USQUE_PROXY_LOCAL_DNS:-0}"  && ARGS+=(-l)
            is_true "${USQUE_PROXY_SYSTEM_DNS:-0}" && ARGS+=(--system-dns)
            ;;
    esac

    if [ "$fam" = "portfw" ] && is_true "${USQUE_DONT_ALWAYS_RECONNECT:-0}"; then
        ARGS+=(--dont-always-reconnect)
    fi

    # Хуки маршрутизации имеют смысл только в native tun.
    if [ "$fam" = "tun" ] && [ "$ROUTE_MODE" != "none" ]; then
        ARGS+=(--on-connect "$HOOK" --on-disconnect "$HOOK")
    fi
    [ -n "${USQUE_ON_CONNECT:-}" ]    && ARGS+=(--on-connect "$USQUE_ON_CONNECT")
    [ -n "${USQUE_ON_DISCONNECT:-}" ] && ARGS+=(--on-disconnect "$USQUE_ON_DISCONNECT")

    # Произвольные пользовательские аргументы (пробелы = разделители).
    if [ -n "${USQUE_EXTRA_ARGS:-}" ]; then
        # shellcheck disable=SC2206
        ARGS+=(${USQUE_EXTRA_ARGS})
    fi
    return 0
}

default_port() {
    case "$1" in
        socks|l4-socks)           printf '%s' "${USQUE_SOCKS_PORT:-1080}" ;;
        http-proxy|l4-http-proxy) printf '%s' "${USQUE_HTTP_PORT:-8000}" ;;
        *)                        printf '' ;;
    esac
}

# build_args <mode> [port]
build_args() {
    local mode="$1" port="${2:-}"

    ARGS=(-c "$CONFIG")
    [ -z "$port" ] && port="$(default_port "$mode")"

    case "$mode" in
        nativetun)
            ARGS+=(nativetun --interface-name "$IFACE")
            is_true "${USQUE_TUN_PERSIST:-0}" && ARGS+=(--persist)
            is_true "${USQUE_NO_IPROUTE2:-0}" && ARGS+=(-I)
            ;;
        socks|l4-socks|http-proxy|l4-http-proxy)
            ARGS+=("$mode" -b "$BIND" -p "$port")
            [ -n "${USQUE_PROXY_USER:-}" ] && ARGS+=(-u "$USQUE_PROXY_USER")
            [ -n "${USQUE_PROXY_PASS:-}" ] && ARGS+=(-w "$USQUE_PROXY_PASS")
            is_true "${USQUE_PROXY_LOCAL_DNS:-0}"  && ARGS+=(-l)
            is_true "${USQUE_PROXY_SYSTEM_DNS:-0}" && ARGS+=(--system-dns)
            ;;
        portfw)
            ARGS+=(portfw)
            if [ -n "${USQUE_FORWARD_LOCAL:-}" ]; then
                for p in $USQUE_FORWARD_LOCAL; do ARGS+=(-L "$p"); done
            fi
            if [ -n "${USQUE_FORWARD_REMOTE:-}" ]; then
                for p in $USQUE_FORWARD_REMOTE; do ARGS+=(-R "$p"); done
            fi
            ;;
    esac

    add_common_flags "$(family_of "$mode")"
    return 0
}

# Список задач: основной режим + дополнительные слушатели (формат "mode|port").
declare -a JOBS=()
append_job() {
    local m="$1" p="${2:-}" j
    for j in ${JOBS[@]+"${JOBS[@]}"}; do
        if [ "${j%%|*}" = "$m" ]; then
            warn "режим ${m} уже включён — пропускаю дубликат"
            return 0
        fi
    done
    JOBS+=("${m}|${p}")
    return 0
}

append_job "$MODE"

# Дополнительные режимы включаются заданием порта: tun + socks разом и т.п.
[ -n "${EXTRA_SOCKS_PORT:-}" ]    && append_job socks "$EXTRA_SOCKS_PORT"
[ -n "${EXTRA_HTTP_PORT:-}" ]     && append_job http-proxy "$EXTRA_HTTP_PORT"
[ -n "${EXTRA_L4_SOCKS_PORT:-}" ] && append_job l4-socks "$EXTRA_L4_SOCKS_PORT"
[ -n "${EXTRA_L4_HTTP_PORT:-}" ]  && append_job l4-http-proxy "$EXTRA_L4_HTTP_PORT"

# ------------------------------------------------------------------- dry-run
if is_true "${USQUE_DRYRUN:-0}"; then
    log "USQUE_DRYRUN=1 — только печатаю, ничего не запускаю"
    for job in "${JOBS[@]}"; do
        build_args "${job%%|*}" "${job#*|}"
        printf 'usque %s\n' "$(printf '%q ' "${ARGS[@]}")"
    done
    printf '# ROUTE_MODE=%s ROUTE_TABLE=%s ROUTE_EXCLUDE=%s ROUTE_IPV6=%s\n' \
        "$ROUTE_MODE" "${ROUTE_TABLE:-100}" "${ROUTE_EXCLUDE:-}" "${ROUTE_IPV6:-auto}"
    exit 0
fi

# ------------------------------------------------------------------- запуск
PIDS=()
stop_all() {
    local rc="${1:-0}"
    trap '' TERM INT
    for pid in ${PIDS[@]+"${PIDS[@]}"}; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    exit "$rc"
}

# Один режим — exec: сигналы от docker stop уходят прямо в usque.
if [ "${#JOBS[@]}" -eq 1 ]; then
    build_args "${JOBS[0]%%|*}" "${JOBS[0]#*|}"
    log "запуск: usque ${ARGS[*]}"
    exec usque "${ARGS[@]}"
fi

log "одновременно запускаю режимов: ${#JOBS[@]}"
trap 'stop_all 0' TERM INT

for job in "${JOBS[@]}"; do
    build_args "${job%%|*}" "${job#*|}"
    log "запуск [${job%%|*}]: usque ${ARGS[*]}"
    usque "${ARGS[@]}" &
    PIDS+=("$!")
done

# Ждём первого упавшего/завершившегося процесса, затем гасим остальные.
rc=0
while :; do
    set +e
    wait -n
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        warn "процесс usque завершился с кодом ${rc} — останавливаю контейнер"
        break
    fi
    alive=0
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then alive=$((alive + 1)); fi
    done
    if [ "$alive" -eq 0 ]; then
        break
    fi
done

stop_all "$rc"
