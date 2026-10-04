#!/bin/sh
# hostinfo.sh — передать гостю время и часовой пояс хоста.
#
# В QEMU без RTC гость просыпается со временем, оставшимся от прошлого
# запуска (а после suspend хоста — вообще в прошлом). Часовой пояс ядра
# тоже не знает: в гостевой ФС нет базы zoneinfo, поэтому передаём
# POSIX-строку TZ, её понимает любой libc.
#
#   ./tools/hostinfo.sh            записать share/.hosttime и share/.hosttz
#   ./tools/hostinfo.sh --print    только показать, что записалось

set -e
cd "$(dirname "$0")/.."
mkdir -p share

# Смещение в формате POSIX: MSK → MSK-3, UTC → UTC0.
host_tz() {
    off=$(date +%z 2>/dev/null)      # +0300
    case "$off" in
        ''|*[!0-9+-]*) printf 'UTC0'; return ;;
    esac
    sign=+; case "$off" in -*) sign=- ;; esac
    hh=$(printf '%s' "$off" | cut -c2-3)
    mm=$(printf '%s' "$off" | cut -c4-5)
    [ -n "$hh" ] || hh=0
    [ -n "$mm" ] || mm=0
    # POSIX-знак обратный: UTC+3 — это MSK-3
    case "$sign" in
        +) printf 'MSK-%s:%s' "$hh" "$mm" ;;
        -) printf 'MSK+%s:%s' "$hh" "$mm" ;;
    esac
}

date +%s > share/.hosttime
host_tz > share/.hosttz

if [ "${1:-}" = --print ]; then
    printf 'epoch:  %s\n' "$(cat share/.hosttime)"
    printf 'TZ:      %s\n' "$(cat share/.hosttz)"
    printf 'хост:    %s\n' "$(date)"
fi