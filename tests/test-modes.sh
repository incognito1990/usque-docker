#!/usr/bin/env bash
# Проверка того, что entrypoint собирает корректные аргументы для каждого режима.
#
# Запускается В КОНТЕЙНЕРЕ (см. make test-modes). Конфиг — тестовый, endpoint
# 127.0.0.1: наружу ничего не уходит, ничего не регистрируется.
# Если в ядре нет драйвера tun, проверка TUN пропускается (это не ошибка
# контейнера) — ядро видно по /proc/misc.
set -uo pipefail

fails=0
ok()  { printf '  OK   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }
note(){ printf '  --   %s\n' "$*"; }

ENV_COMMON="USQUE_REGISTER=never USQUE_FORWARD_LOCAL=localhost:8080:100.96.0.2:8080"
TUN_OK=1
grep -qw tun /proc/misc 2>/dev/null || TUN_OK=0

check_mode() {
    local mode="$1" port="${2:-}" marker="${3:-}"
    echo
    echo "=== режим: ${mode} ==="

    local out cmdline
    out=$(env $ENV_COMMON USQUE_MODE="$mode" USQUE_DRYRUN=1 /usr/local/bin/entrypoint.sh 2>&1)
    cmdline=$(printf '%s\n' "$out" | grep '^usque ' | head -1)
    if [ -z "$cmdline" ]; then
        bad "dry-run не выдал команду"
        printf '%s\n' "$out" | sed 's/^/      /'
        return
    fi
    echo "  команда: ${cmdline}"

    ( eval "timeout 8 ${cmdline}" ) >/tmp/run.log 2>&1 &
    local runpid=$!
    sleep 3

    if grep -qiE 'unknown flag|unknown shorthand' /tmp/run.log; then
        bad "usque не принял флаги"
        grep -iE 'unknown flag|unknown shorthand' /tmp/run.log | sed 's/^/      /'
    else
        ok "флаги приняты парсером usque"
    fi

    if [ -n "$marker" ]; then
        if grep -q "$marker" /tmp/run.log; then
            ok "признак работы: ${marker}"
        elif case "$mode" in tun|nativetun) [ "$TUN_OK" -eq 0 ] ;; *) false ;; esac; then
            note "tun недоступен: в ядре нет драйвера (см. /proc/misc) — проверка пропущена"
        else
            bad "не дождался '${marker}'"
        fi
    fi

    if [ -n "$port" ]; then
        if ss -ltn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
            ok "порт ${port} слушается"
        else
            bad "порт ${port} не слушается"
        fi
    fi

    if kill -0 "$runpid" 2>/dev/null; then
        ok "процесс жив"
    elif case "$mode" in tun|nativetun) [ "$TUN_OK" -eq 0 ] ;; *) false ;; esac; then
        note "процесс завершился: нет TUN в ядре — ожидаемо здесь"
    else
        bad "процесс завершился раньше времени"
    fi

    echo "  --- вывод (последние 6 строк) ---"
    tail -6 /tmp/run.log | sed 's/^/      /'

    kill "$runpid" 2>/dev/null || true
    pkill -x usque 2>/dev/null || true
    sleep 1
}

if [ "$TUN_OK" -eq 1 ]; then
    note "драйвер tun в ядре есть — проверяю и tun-режим"
else
    note "драйвера tun в ядре нет — tun-режим проверяется только по аргументам"
fi

check_mode tun           ""    "Created TUN device"
check_mode socks         1080  ""
check_mode http-proxy    8000  ""
check_mode l4-socks      1080  ""
check_mode l4-http-proxy 8000  ""
check_mode portfw        ""    ""

echo
echo "=== несколько режимов сразу: tun + socks ==="
out=$(env $ENV_COMMON USQUE_MODE=tun EXTRA_SOCKS_PORT=1080 USQUE_DRYRUN=1 /usr/local/bin/entrypoint.sh 2>&1)
n=$(printf '%s\n' "$out" | grep -c '^usque ')
if [ "$n" -eq 2 ]; then ok "dry-run собрал 2 команды"; else bad "ожидал 2 команды, получил ${n}"; fi
printf '%s\n' "$out" | grep '^usque ' | sed 's/^/      /'

( eval "timeout 8 $(printf '%s\n' "$out" | grep '^usque ' | head -1)" ) >/tmp/run1.log 2>&1 &
p1=$!
( eval "timeout 8 $(printf '%s\n' "$out" | grep '^usque ' | tail -1)" ) >/tmp/run2.log 2>&1 &
p2=$!
sleep 3
if ss -ltn 2>/dev/null | grep -qE '[:.]1080[[:space:]]'; then
    ok "socks из второго режима слушает 1080"
else
    bad "socks из второго режима не слушает"
fi
kill "$p1" "$p2" 2>/dev/null || true
pkill -x usque 2>/dev/null || true

echo
echo "=== Zero Trust: подстановка SNI ==="
out=$(env $ENV_COMMON USQUE_MODE=socks USQUE_JWT=dummy.jwt.token USQUE_DRYRUN=1 /usr/local/bin/entrypoint.sh 2>&1)
if printf '%s' "$out" | grep -q 'zt-masque.cloudflareclient.com'; then
    ok "при USQUE_JWT SNI переключается на zt-masque"
else
    bad "SNI Zero Trust не подставился"
fi
if printf '%s' "$out" | grep -q '\.zerotrust'; then
    note "маркер .zerotrust упоминается в выводе"
fi

echo
echo "=== l4-*: неподдерживаемые флаги не передаются ==="
out=$(env $ENV_COMMON USQUE_MODE=l4-socks USQUE_SNI=example.com USQUE_HTTP2=1 USQUE_MTU=1400 USQUE_DRYRUN=1 /usr/local/bin/entrypoint.sh 2>&1)
cmdline=$(printf '%s\n' "$out" | grep '^usque ' | head -1)
if printf '%s' "$cmdline" | grep -qE '\-\-http2|-m 1400|-s example.com'; then
    bad "l4-* получил флаги, которых у него нет"
    printf '%s\n' "$cmdline" | sed 's/^/      /'
else
    ok "лишние флаги отфильтрованы"
fi
printf '%s\n' "$out" | grep -- 'l4-\*' | sed 's/^/      /'

echo
if [ "$fails" -eq 0 ]; then echo "ИТОГО: все проверки пройдены"; exit 0; fi
echo "ИТОГО: провалов ${fails}"
exit 1
