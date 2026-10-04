#!/bin/sh
# /etc/share.sh — монтирование 9p-шары с хостом.
#
# 9p-транспорт virtio поднимается не мгновенно, поэтому пробуем
# несколько раз с паузой. Если 9p не поддерживается — не падаем:
# система должна грузиться и без общей папки.
#
# Здесь же выравниваем время и часовой пояс по хосту: только тут /shared
# доступна. В /etc/rc.local (он выполняется как bootcmd) шары ещё нет,
# поэтому время там выставлять бесполезно.
BB=/bin/busybox
TAG=${TAG:-host}
MOUNT=${MOUNT:-/shared}

# cache=none — не косметика, а вынужденная мера.
#
# В этом ядре CACHE_SC_LOOSE = 0b1111, то есть «loose» = FILE|META|
# WRITEBACK|LOOSE (fs/9p/v9fs.h). С write-back кэшем шары под QEMU/TCG
# гость через несколько секунд перестаёт выполняться ВООБЩЕ: QEMU
# уходит в 0% CPU, оба vCPU стоят в hlt. Проверено так — одинаковый цикл
# из 3000 итераций:
#   cache=loose -> 316 итераций, зависание на ~18-й секунде uptime
#   cache=none  -> 3000 итераций за 1.5 с, нормальная работа
# Симптом был ловушкой: зависало всё (включая sleep), и казалось, что
# сломан таймер ядра. На деле писало в шару зависшее «tee».
#
# Минус: каждое чтение идёт к серверу, кэш данных не используется.
# Для /shared/repo это незаметно — там крупные файлы, а не тысячи мелких.
OPTS="trans=virtio,version=9p2000.L,msize=1048576,cache=none"

# Запасной вариант на случай, если конкретное ядро не примет параметр.
OPTS_FALLBACK="trans=virtio,cache=none"

# dinit отдаёт сервису свой stdout, а не консоль, поэтому сообщения
# сервиса до пользователя не доходят. Пишем в /dev/console явно.
[ -c /dev/console ] && exec >/dev/console 2>&1

# --- время и часовой пояс ---------------------------------------------------
# У QEMU нет RTC, который пережил бы suspend хоста: гость может проснуться
# со временем прошлого запуска. Хост пишет share/.hosttime (epoch) и
# share/.hosttz (POSIX-строка, потому что базы zoneinfo в гостю нет).
sync_time() {
    [ -r "$MOUNT/.hosttz" ] || return 0
    tz=$(cat "$MOUNT/.hosttz" 2>/dev/null)
    case "$tz" in
        ''|*[!A-Za-z0-9_+:-]*) echo "TZ: мусор в .hosttz, пропускаю" >&2; return 0 ;;
    esac
    printf '%s\n' "$tz" > /etc/tz || return 0
    TZ=$tz; export TZ

    [ -r "$MOUNT/.hosttime" ] || return 0
    t=$(cat "$MOUNT/.hosttime" 2>/dev/null)
    case "$t" in
        ''|*[!0-9]*) return 0 ;;
    esac
    # epoch переводим в UTC-строку, и выставляем её тоже как UTC.
    # Иначе date -s истолкует её в местном времени и часы уедут на
    # величину смещения назад — ровно тот баг, который тут был.
    stamp=$(TZ=UTC $BB date -d "@$t" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    if [ -z "$stamp" ]; then
        echo "время: не смог разобрать epoch $t" >&2
        return 0
    fi
    # busybox date -s возвращает 0 даже при отказе, поэтому сверяемся
    # с результатом: если не совпало — значит, не выставилось.
    TZ=UTC $BB date -s "$stamp" >/dev/null 2>&1
    got=$($BB date -u '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    if [ "$got" = "$stamp" ]; then
        echo "время выровнено по хосту: $($BB date)"
    else
        echo "время: выставить не удалось (хотел $stamp UTC, получил ${got:-?})" >&2
    fi
}

mkdir -p "$MOUNT" 2>/dev/null

# Уже смонтировано?
if $BB mount 2>/dev/null | grep -q "on $MOUNT type 9p"; then
    echo "9p: $MOUNT уже смонтирована"
    sync_time
    exit 0
fi

mount_try() {
    o=$1
    n=$2
    i=0
    while [ "$i" -lt "$n" ]; do
        if $BB mount -t 9p -o "$o" "$TAG" "$MOUNT" 2>/dev/null; then
            echo "9p: $MOUNT примонтирована [$o] (попытка $((i+1)))"
            return 0
        fi
        i=$((i+1))
        sleep 0.2
    done
    return 1
}

# Сначала полный набор параметров, потом урезанный: транспорт 9p поднимается
# не мгновенно, а лишний параметр может не поддерживаться ядром.
mount_try "$OPTS" 20 || mount_try "$OPTS_FALLBACK" 5
if $BB mount 2>/dev/null | grep -q " on $MOUNT type 9p "; then
    sync_time
    exit 0
fi

echo "9p: не удалось примонтировать $MOUNT" >&2
echo "9p: продолжаю работу без общей папки" >&2
exit 0