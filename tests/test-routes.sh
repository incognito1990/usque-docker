#!/usr/bin/env bash
# Проверка хука маршрутизации в изолированном netns контейнера.
# Ничего снаружи не меняет: тестируем только таблицы маршрутизации этого netns.
set -uo pipefail

HOOK=/hook.sh
IFACE=usque-tun
EP=162.159.198.1:443
GW="$(ip route show default | awk '/^default/ {print $3; exit}')"
UPIF="$(ip route show default | awk '/^default/ {print $5; exit}')"

fails=0
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }
have() { ip "$@" 2>/dev/null; }

echo "исходно: gw=${GW} if=${UPIF}"
ip route show | sed 's/^/    /'

setup_iface() {
    ip link add "$IFACE" type dummy 2>/dev/null || true
    ip link set "$IFACE" up
    ip addr add 172.16.0.2/32 dev "$IFACE" 2>/dev/null || true
}

reset_routes() {
    ip route del default dev "$IFACE" 2>/dev/null || true
    ip route flush table 100 2>/dev/null || true
    ip rule del lookup 100 2>/dev/null || true
    ip route replace default via "$GW" dev "$UPIF" 2>/dev/null || true
}

setup_iface
reset_routes

echo
echo "=== 1. ROUTE_MODE=main: connect ==="
ROUTE_MODE=main USQUE_EVENT=connect USQUE_MODE=nativetun USQUE_IFACE="$IFACE" \
    USQUE_ENDPOINT="$EP" UPSTREAM_GW="$GW" UPSTREAM_IF="$UPIF" \
    bash "$HOOK"

ip route show | sed 's/^/    /'
if ip route show | grep -q "162.159.198.1 via ${GW} dev ${UPIF}"; then
    ok "эндпоинт обойдён (via ${GW} dev ${UPIF})"
else
    bad "нет обходного маршрута до эндпоинта — была бы петля"
fi
if ip route show | grep -q "default dev ${IFACE}"; then
    ok "default ушёл в ${IFACE}"
else
    bad "default не переключился на ${IFACE}"
fi
# порядок применения: обходной маршрут должен быть специфичнее, чем default
if ip route get 162.159.198.1 2>/dev/null | grep -q "dev ${UPIF}"; then
    ok "пакет до эндпоинта выбирает ${UPIF}, а не туннель"
else
    bad "пакет до эндпоинта уходит не туда"
fi
if ip route get 1.1.1.1 2>/dev/null | grep -q "dev ${IFACE}"; then
    ok "произвольный трафик уходит в туннель"
else
    bad "произвольный трафик НЕ уходит в туннель"
fi

echo
echo "=== 2. ROUTE_MODE=main: disconnect (возврат) ==="
ROUTE_MODE=main USQUE_EVENT=disconnect USQUE_MODE=nativetun USQUE_IFACE="$IFACE" \
    USQUE_ENDPOINT="$EP" UPSTREAM_GW="$GW" UPSTREAM_IF="$UPIF" \
    bash "$HOOK"
ip route show | sed 's/^/    /'
if ip route show | grep -q "default via ${GW} dev ${UPIF}"; then
    ok "default вернулся на ${UPIF}"
else
    bad "default не восстановлен"
fi

echo
echo "=== 3. ROUTE_MODE=table (таблица 100) ==="
reset_routes
ROUTE_MODE=table ROUTE_TABLE=100 ROUTE_RULE_PRIO=1000 \
    USQUE_EVENT=connect USQUE_MODE=nativetun USQUE_IFACE="$IFACE" \
    USQUE_ENDPOINT="$EP" UPSTREAM_GW="$GW" UPSTREAM_IF="$UPIF" \
    bash "$HOOK"

echo "  --- main ---";  ip route show | sed 's/^/    /'
echo "  --- table 100 ---"; ip route show table 100 | sed 's/^/    /'
echo "  --- rules ---"; ip rule show | sed 's/^/    /'

if ip route show table 100 | grep -q "default dev ${IFACE}"; then
    ok "в таблице 100 есть default dev ${IFACE}"
else
    bad "в таблице 100 нет default"
fi
if ip route show table 100 | grep -q "162.159.198.1 via ${GW}"; then
    ok "в таблице 100 есть обход эндпоинта"
else
    bad "в таблице 100 нет обхода эндпоинта — петля"
fi
if ip rule show | grep -q "lookup 100"; then
    ok "правило ip rule добавлено"
else
    bad "правило ip rule не добавлено"
fi
if ip route show | grep -q "default via ${GW} dev ${UPIF}"; then
    ok "основная таблица не тронута"
else
    bad "основная таблица изменена (не должна была)"
fi
if ip route get 1.1.1.1 2>/dev/null | grep -q "dev ${IFACE}"; then
    ok "трафик уходит в туннель через правило"
else
    bad "правило не заворачивает трафик (ip route get)"
fi
if ip route get 162.159.198.1 2>/dev/null | grep -q "dev ${UPIF}"; then
    ok "эндпоинт по-прежнему идёт мимо туннеля"
else
    bad "эндпоинт уходит в туннель — петля"
fi
if ip route get "${GW}" 2>/dev/null | grep -q "dev ${UPIF}"; then
    ok "локальная сеть доступна (fallback в main)"
else
    bad "локальная сеть стала недоступна"
fi

echo
echo "=== 4. ROUTE_MODE=table: повторный connect (идемпотентность) ==="
ROUTE_MODE=table ROUTE_TABLE=100 USQUE_EVENT=connect USQUE_MODE=nativetun USQUE_IFACE="$IFACE" \
    USQUE_ENDPOINT="$EP" UPSTREAM_GW="$GW" UPSTREAM_IF="$UPIF" bash "$HOOK"
rules=$(ip rule show | grep -c "lookup 100")
if [ "$rules" -eq 1 ]; then
    ok "правило не задублировалось"
else
    bad "правил lookup 100: ${rules} (ожидалось 1)"
fi

echo
echo "=== 5. ROUTE_MODE=none: ничего не делаем ==="
reset_routes
ROUTE_MODE=none USQUE_EVENT=connect USQUE_MODE=nativetun USQUE_IFACE="$IFACE" \
    USQUE_ENDPOINT="$EP" UPSTREAM_GW="$GW" UPSTREAM_IF="$UPIF" bash "$HOOK"
if ip route show | grep -q "default via ${GW} dev ${UPIF}" && ! ip route show | grep -q "dev ${IFACE}"; then
    ok "маршруты не тронуты"
else
    bad "при ROUTE_MODE=none маршруты изменились"
fi

echo
echo "=== 6. Неверные входные данные ==="
out=$(ROUTE_MODE=table USQUE_EVENT=connect USQUE_MODE=socks USQUE_IFACE="$IFACE" bash "$HOOK" 2>&1)
if [ -z "$out" ]; then ok "режим socks: хук молча выходит"; else bad "режим socks: лишний вывод: $out"; fi
out=$(ROUTE_MODE=table USQUE_EVENT=connect USQUE_MODE=nativetun USQUE_IFACE="" bash "$HOOK" 2>&1)
if printf '%s' "$out" | grep -q "USQUE_IFACE пуст"; then ok "пустой iface: понятная ошибка"; else bad "нет предупреждения о пустом iface"; fi

echo
if [ "$fails" -eq 0 ]; then
    echo "ИТОГО: все проверки пройдены"
    exit 0
fi
echo "ИТОГО: провалов ${fails}"
exit 1
