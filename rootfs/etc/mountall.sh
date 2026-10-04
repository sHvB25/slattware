#!/bin/sh
# /etc/mountall.sh — монтирование по /etc/fstab с понятным выводом.
#
# Отдельный скрипт вместо «mount -a», потому что хочется видеть, что именно
# не примонтировалось. dinit показывает в логе только код возврата.
BB=/bin/busybox

# dinit отдаёт сервису свой stdout, а не консоль: сообщения о монтировании
# иначе никто не увидит. Пишем в /dev/console явно.
[ -c /dev/console ] && exec >/dev/console 2>&1

mkdir -p /proc /sys /tmp /run /home /shared 2>/dev/null

if $BB mount -a 2>&1; then
    :
else
    echo "mount -a вернул ошибку, монтирую по одной строке:" >&2
fi

# Проверяем, что всё важное на месте. /proc критичен: без него
# не работают ps, mount, dmesg и большинство утилит.
rc=0
check() {
    if ! $BB mount 2>/dev/null | grep -q " on $1 "; then
        echo "НЕ Смонтировано: $1" >&2
        rc=1
    fi
}

check /proc
check /sys
check /home

# /proc — самое важное, монтируем принудительно
if ! $BB mount 2>/dev/null | grep -q " on /proc "; then
    echo "монтирую /proc принудительно" >&2
    $BB mount -t proc proc /proc 2>&1 || :
    $BB mount 2>/dev/null | grep -q " on /proc " || {
        echo "КРИТИЧНО: /proc не смонтирован, система работает криво" >&2
        rc=1
    }
fi

# Показываем итог
echo "монтировано:"
$BB mount 2>/dev/null | sed 's/^/  /'

exit $rc
