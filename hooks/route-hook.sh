#!/usr/bin/env bash
# route-hook.sh — устанавливает/снимает маршруты через TUN-интерфейс usque.
#
# Вызывается САМИМ usque (флаги --on-connect / --on-disconnect), без аргументов,
# событие приходит в переменной USQUE_EVENT. usque только склеивает env родителя
# с USQUE_* переменными, поэтому переменные из docker-compose/.env видны здесь.
#
# usque НЕ ставит маршруты сам — это его осознанное поведение, вся маршрутизация
# на этом хуке.
#
# ROUTE_MODE:
#   none   — ничего не делать (usque сам поднимает адреса и link up)
#   main   — маршрут по умолчанию через TUN в основной таблице (+ обходные
#            маршруты до эндпоинта в той же таблице)
#   table  — то же, но маршрут по умолчанию живёт в отдельной таблице,
#            а трафик туда заворачивается правилом ip rule. Основная таблица
#            не меняется.

set -uo pipefail

ROUTE_MODE="${ROUTE_MODE:-none}"
EVENT="${USQUE_EVENT:-connect}"
TABLE="${ROUTE_TABLE:-100}"
PRIO="${ROUTE_RULE_PRIO:-1000}"
IFACE="${USQUE_IFACE:-}"
EP="${USQUE_ENDPOINT:-}"
GW="${UPSTREAM_GW:-}"
UPIF="${UPSTREAM_IF:-}"
EXCLUDE="${ROUTE_EXCLUDE:-}"
ROUTE_IPV6="${ROUTE_IPV6:-auto}"

ts() { date -u +%H:%M:%S; }
log()  { printf '%s [route] %s\n' "$(ts)" "$*"; }
warn() { printf '%s [route] %s\n' "$(ts)" "$*" >&2; }

try() {
    local out
    if ! out=$("$@" 2>&1); then
        warn "не удалось: $* — ${out}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- проверки
[ "$ROUTE_MODE" = "none" ] && exit 0

case "${ROUTE_MODE}" in
    main|table) ;;
    *) warn "неизвестный ROUTE_MODE='${ROUTE_MODE}', ожидаю none|main|table — выхожу"; exit 0 ;;
esac

# Хук имеет смысл только для native tun: в socks/http-proxy маршруты не нужны.
if [ "${USQUE_MODE:-nativetun}" != "nativetun" ]; then
    exit 0
fi

if [ -z "$IFACE" ]; then
    warn "USQUE_IFACE пуст — не знаю, куда маршрутизировать, выхожу"
    exit 0
fi

if [ -z "$UPIF" ]; then
    warn "не известен внешний интерфейс (UPSTREAM_IF) — обходные маршруты не добавить"
fi

# ------------------------------------------------------- разбор USQUE_ENDPOINT
# Go печатает netip.AddrPort: "1.2.3.4:443" либо "[2606:4700::1]:443".
ep4=""
ep6=""
case "$EP" in
    \[*\]:*) ep6="${EP%%\]:*}"; ep6="${ep6#\[}" ;;
    \[*\])   ep6="${EP#\[}";    ep6="${ep6%\]}" ;;
    *:*)     ep4="${EP%%:*}" ;;
    "")      : ;;
    *)       ep4="$EP" ;;
esac

# "via ... dev ..." либо только "dev ..." (если шлюза нет)
nexthop() {
    if [ -n "$GW" ]; then
        printf 'via %s dev %s' "$GW" "$UPIF"
    elif [ -n "$UPIF" ]; then
        printf 'dev %s' "$UPIF"
    else
        printf ''
    fi
}

# Обходной маршрут в основной таблице: эндпоинт, до которого usque ходит сам,
# ОБЯЗАН ходить наружу напрямую, иначе пакеты уйдут в tun и получится петля.
bypass() {
    local fam="$1" dst="$2" nh
    nh=$(nexthop)
    [ -n "$nh" ] || return 0
    # shellcheck disable=SC2086
    try ip "-$fam" route replace "$dst" $nh
}

# ------------------------------------------------------------- IPv6: да или нет
ipv6_enabled() {
    case "${ROUTE_IPV6}" in
        1|true|yes|on)  return 0 ;;
        0|false|no|off) return 1 ;;
    esac
    # auto: включаем, только если в конфиге есть адрес в туннеле
    [ "${USQUE_NO_TUNNEL_IPV6:-0}" = "1" ] && return 1
    [ -n "${USQUE_IPV6:-}" ]
}

# -------------------------------------------------- rule для table-режима
rule_present() {
    local fam="$1"
    ip "-$fam" rule show 2>/dev/null | grep -qE "lookup[[:space:]]+${TABLE}([[:space:]]|$)"
}

ensure_rule() {
    local fam="$1"
    if rule_present "$fam"; then
        return 0
    fi
    try ip "-$fam" rule add lookup "$TABLE" priority "$PRIO"
}

# В отдельной таблице default перехватывает ВСЁ, включая шлюз Docker и локальные
# подсети: таблица не «дополняет» основную, а заменяет её для выбранного трафика.
# Поэтому копируем в неё маршруты напрямую подключённых сетей upstream-интерфейса —
# иначе отвалились бы ответы клиентам docker-сети (например, проброшенному socks).
copy_onlink_routes() {
    local fam="$1" cidr _
    [ -n "$UPIF" ] || return 0
    while read -r cidr _; do
        [ -n "$cidr" ] || continue
        try ip "-$fam" route replace "$cidr" dev "$UPIF" table "$TABLE"
    done < <(ip "-$fam" route show dev "$UPIF" scope link 2>/dev/null)
    return 0
}

# ============================================================== ПОДКЛЮЧЕНИЕ
do_connect() {
    log "подключение: iface=${IFACE} mode=${ROUTE_MODE} endpoint=${EP:-нет} gw=${GW:-нет}"

    # 1. Обход эндпоинта — СТРОГО до смены маршрута по умолчанию.
    for cidr in $(printf '%s' "$EXCLUDE"); do
        bypass 4 "$cidr"
    done
    [ -n "$ep4" ] && bypass 4 "$ep4/32"

    if ipv6_enabled; then
        [ -n "$ep6" ] && bypass 6 "$ep6/128"
    fi

    # 2. Маршрут по умолчанию через туннель.
    if [ "$ROUTE_MODE" = "table" ]; then
        # В таблицу кладём и обходные маршруты, иначе правило уведёт и сам эндпоинт.
        nh=$(nexthop)
        if [ -n "$nh" ]; then
            for cidr in $(printf '%s' "$EXCLUDE"); do
                # shellcheck disable=SC2086
                try ip -4 route replace "$cidr" $nh table "$TABLE"
            done
            [ -n "$ep4" ] && try ip -4 route replace "$ep4/32" $(nexthop) table "$TABLE"
        fi
        copy_onlink_routes 4
        try ip -4 route replace default dev "$IFACE" table "$TABLE"
        ensure_rule 4
        log "таблица ${TABLE}: default dev ${IFACE} + правило ip rule (prio ${PRIO})"

        if ipv6_enabled; then
            if [ -n "$ep6" ] && [ -n "$(nexthop)" ]; then
                # shellcheck disable=SC2086
                try ip -6 route replace "$ep6/128" $(nexthop) table "$TABLE"
            fi
            copy_onlink_routes 6
            try ip -6 route replace default dev "$IFACE" table "$TABLE"
            ensure_rule 6
            log "таблица ${TABLE}: default6 dev ${IFACE}"
        fi
    else
        try ip -4 route replace default dev "$IFACE"
        log "основная таблица: default dev ${IFACE}"
        if ipv6_enabled; then
            try ip -6 route replace default dev "$IFACE"
            log "основная таблица: default6 dev ${IFACE}"
        fi
    fi

    log "готово. Проверка: ip route show ${TABLE:+table $TABLE}"
}

# ============================================================== ОТКЛЮЧЕНИЕ
do_disconnect() {
    log "отключение: убираю маршрут по умолчанию через ${IFACE}"

    if [ "$ROUTE_MODE" = "table" ]; then
        # Правило оставляем: пустая таблица = прозрачный откат в основную.
        try ip -4 route del default dev "$IFACE" table "$TABLE" 2>/dev/null || true
        try ip -6 route del default dev "$IFACE" table "$TABLE" 2>/dev/null || true
    fi

    # Возвращаем исходный маршрут по умолчанию (в table-режиме — тоже на всякий
    # случай, основная таблица могла быть тронута вручную/предыдущим запуском).
    if [ -n "$GW" ]; then
        try ip -4 route replace default via "$GW" dev "$UPIF"
    else
        try ip -4 route del default dev "$IFACE"
    fi

    if [ -n "${UPSTREAM_GW6:-}" ] && [ -n "$UPIF" ]; then
        try ip -6 route replace default via "$UPSTREAM_GW6" dev "$UPIF"
    elif ipv6_enabled; then
        try ip -6 route del default dev "$IFACE"
    fi

    # Обходные маршруты до эндпоинта НЕ удаляем: они безвредны и защищают от
    # петли, если usque переподключится раньше, чем отработает хук.
    log "готово"
}

case "$EVENT" in
    connect)    do_connect ;;
    disconnect) do_disconnect ;;
    *)          log "неизвестное событие '${EVENT}', ничего не делаю" ;;
esac

exit 0
