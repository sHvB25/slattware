#!/bin/sh
# install.sh — установщик slattware, по главам, как в Linux From Scratch.
#
# Замысел: результат не важен — важно, чтобы ты сам увидел каждый шаг и
# понял, что произошло. Поэтому здесь НЕТ одной кнопки «сделать всё»:
# каждая глава сначала объясняет, что будет сделано и зачем, потом
# спрашивает подтверждение, и только потом делает. Можно ответить «n» —
# и посмотреть, что будет, не выполняя.
#
#   ./install.sh            установить с нуля, глава за главой
#   ./install.sh --list     показать главы и ничего не делать
#   ./install.sh 3          начать с главы 3
#   ./install.sh --yes      без вопросов (для повторов и CI)
#
# В отличие от build.sh (который молча пересобирает) здесь каждый шаг
# виден и его можно отменить.

cd "$(dirname "$0")" || exit 1

ROOTFS=$PWD/rootfs
DISK=$PWD/disk.img
DATA=$PWD/data.img
KERNEL=$PWD/kernel/7.2.8/arch/x86/boot/bzImage
INITRD=$PWD/initramfs.cpio.gz
MNT=${MNT:-/tmp/slattware-install}
DATA_MNT=${DATA_MNT:-/tmp/slattware-home}
DISK_SIZE=${DISK_SIZE:-512M}
DATA_SIZE=${DATA_SIZE:-256M}
STATE=$PWD/.install-step

YES=0
START=1

# busybox ash не умеет $'...' (ANSI-C quoting), поэтому цвета задаём
# литералами. Читать их неудобно, зато работает в любом POSIX shell.
ESC=$(printf '\033')
C_C=$ESC'[36m'; C_B=$ESC'[1m'; C_R=$ESC'[31m'
C_G=$ESC'[32m'; C_Y=$ESC'[33m'; C_0=$ESC'[0m'

say()  { printf '%s==>%s %s\n' "$C_C" "$C_0" "$*"; }
warn() { printf '%swarn:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sошибка:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

as_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas "$@"
    else
        die "нужны права root (doas/sudo)"
    fi
}

# skip_ok(): сначала объяснение, потом вопрос. Возвращает 1, если
# пользователь ответил "n" — вызывающая функция на этом return.
#
# Именно return из ВЫЗЫВАЮЩЕЙ функции, а не отсюда: тело главы живёт в
# cap_*, и ранний return отсюда его не отменял. Поэтому "пропустить главу"
# печатал "пропущено" и тут же всё равно выполнял её.
skip_ok() {
    _n=$1; _title=$2; _why=$3
    printf '\n%s%s%s─── глава %s: %s %s\n' \
        "$C_B" "$C_C" "$C_0" "$_n" "$_title" "$C_0"
    printf '%s%s%s\n\n' "$_why" "$C_B" "$C_0"

    if [ "$YES" = 0 ]; then
        printf 'Выполнить? [Y/n/q] '
        read -r _a || _a=n
        case $_a in
            n|N)  say "пропущено, идём дальше"; return 1 ;;
            q|Q)  say "остановлено"; exit 0 ;;
        esac
    fi
    return 0
}

list_chapters() {
    cat <<'EOF'
Главы установки slattware:

  1  Проверки        что нужно на хосте, ничего не меняем
  2  Ядро            bzImage: ядро, с которым система загрузится
  3  initramfs       первый процесс: монтирует корень и передаёт
                     управление системе
  4  Образ диска     создаём пустой диск и форматируем в ext4
  5  Раскладка       копируем rootfs/ в образ, ставим владельцев
  6  Домашний каталог data.img: то, что переживает пересборку
  7  Проверка        читаем то, что получилось, ДО загрузки
  8  Первый запуск   грузим систему и смотрим, что она живая

Каждая глава объясняет себя перед тем, как что-то сделает.
EOF
}

# ---------------------------------------------------------------------------
cap_check() {
    skip_ok 1 "Проверки" \
"Прежде чем что-то создавать, убеждаемся, что на хосте есть всё нужное.
Ничего не меняется — только читаем."
    [ $? -eq 0 ] || return 0

    for t in cpio gzip mkfs.ext4 qemu-system-x86_64 tar dd; do
        if command -v "$t" >/dev/null 2>&1; then
            printf '  %sесть%s   %s\n' "$C_G" "$C_0" "$t"
        else
            printf '  %sНЕТ%s    %s\n' "$C_R" "$C_0" "$t"
            die "не хватает $t"
        fi
    done
    if command -v doas >/dev/null 2>&1; then
        printf '  %sесть%s   doas (поднимет права без пароля)\n' "$C_G" "$C_0"
    else
        warn "doas нет — для mkfs/mount нужны права root иным способом"
    fi

    if [ ! -d "$ROOTFS" ]; then
        die "нет каталога rootfs/ — это поломанная копия, а не установка"
    fi
    say "проверки пройдены, можно идти дальше"
}

cap_kernel() {
    skip_ok 2 "Ядро" \
"Ядро нужно системе, чтобы вообще включиться. Мы НЕ собираем его заново:
в kernel/ лежит уже собранный bzImage. Проверяем, что он на месте и
ненулевой — иначе загрузка не начнётся."
    [ $? -eq 0 ] || return 0

    [ -f "$KERNEL" ] || die "нет $KERNEL — ядро не собрано"
    say "нашлось: $(du -h "$KERNEL" | cut -f1)"
    say "версия: $(file -b "$KERNEL" 2>/dev/null | cut -c1-60)"
}

cap_initramfs() {
    skip_ok 3 "initramfs" \
"Это первый процесс в системе, самый ранний. Он делает ровно три вещи:
монтирует настоящий корень с диска, поднимает /proc и /sys, и передаёт
управление через switch_root. Вся остальная система живёт уже после него.

Собираем его из каталога initramfs/ в сжатый архив cpio."
    [ $? -eq 0 ] || return 0

    [ -d initramfs ] || die "нет каталога initramfs/"
    [ -x initramfs/bin/busybox ] || die "в initramfs/ нет busybox"

    say "упаковываю $(find initramfs | wc -l | tr -d ' ') файлов"
    (cd initramfs && find . | sort | cpio -o -H newc 2>/dev/null) \
        | gzip -9 > "$INITRD" \
        || die "не собрать initramfs (нужен cpio и gzip)"

    say "initramfs готов: $(du -h "$INITRD" | cut -f1)"
    say "внутри: $(gzip -dc "$INITRD" | cpio -t 2>/dev/null | wc -l | tr -d ' ') записей"
}

cap_disk() {
    skip_ok 4 "Образ диска" \
"Диск.img — это файл, который QEMU покажет гостю как настоящий жёсткий
диск. Создаём пустой файл нужного размера и форматируем в ext4: система
при загрузке делает switch_root именно в /dev/vda, то есть первый диск.

ВНИМАНИЕ: если disk.img уже есть, он будет ПЕРЕЗАПИСАН, и всё, что
стояло через bdd (а это /usr/local, /var, /root), пропадёт."
    [ $? -eq 0 ] || return 0

    if [ -f "$DISK" ] && [ "$YES" = 0 ]; then
        printf '  %s%s%s\n' "$C_Y" "$DISK уже существует — перезаписать?" "$C_0"
        printf 'Перезаписать? [y/N] '
        read -r _a || _a=n
        case $_a in
            y|Y) : ;;
            *) say "оставляю как есть, тогда образ не обновится"; return 0 ;;
        esac
    fi

    say "создаю $DISK ($DISK_SIZE)"
    rm -f "$DISK"
    dd if=/dev/zero of="$DISK" bs=1M count=$((${DISK_SIZE%M})) 2>/dev/null \
        || die "не создать $DISK"
    say "форматирую ext4"
    as_root mkfs.ext4 -q -F -L mydistro "$DISK" 2>/dev/null \
        || die "не отформатировать (нужны права root)"
    say "диск готов: $(du -h "$DISK" | cut -f1)"
}

cap_rootfs() {
    skip_ok 5 "Раскладка системы" \
"Копируем содержимое rootfs/ в свежий образ и выставляем права.

Отдельно про владельцев: файлы из tar сохраняют ТВОЕГО uid, а системные
файлы должны принадлежать root. Иначе setuid-бит у sud не даст прав, и
удалить пакет будет нечем. Поэтому после копирования мы делаем chown."
    [ $? -eq 0 ] || return 0

    as_root mkdir -p "$MNT" 2>/dev/null || :
    as_root mount -o loop "$DISK" "$MNT" \
        || die "не примонтировать $DISK (нужны права root)"

    say "копирую $(find "$ROOTFS" | wc -l | tr -d ' ') объектов из rootfs/"
    (cd "$ROOTFS" && tar -cf - .) | as_root tar -xf - -C "$MNT" \
        || { as_root umount "$MNT"; die "не скопировать rootfs"; }

    say "выставляю владельца root на системные каталоги"
    for d in bin sbin lib lib64 etc init usr var root; do
        as_root chown -R 0:0 "$MNT/$d" 2>/dev/null || :
    done

    say "создаю ссылки busybox в /bin"
    as_root chroot "$MNT" /bin/busybox --install -s /bin 2>/dev/null || :
    as_root chown -R 0:0 "$MNT/bin" 2>/dev/null || :

    if [ -f "$ROOTFS/usr/local/bin/sud" ]; then
        say "ставлю setuid на sud — иначе он не сможет стать root"
        as_root chmod 4755 "$MNT/usr/local/bin/sud" 2>/dev/null \
            || warn "не поставил setuid"
    fi
    as_root chmod 1777 "$MNT/tmp" "$MNT/var/tmp" 2>/dev/null || :

    as_root sync
    as_root umount "$MNT" || die "не размонтировать"
    as_root rmdir "$MNT" 2>/dev/null || :
    say "образ обновлён: $(du -h "$DISK" | cut -f1)"
}

cap_home() {
    skip_ok 6 "Домашний каталог" \
"Домашний каталог лежит в отдельном образе data.img и монтируется в
/home. Отдельный файл нужен, чтобы он ПЕРЕЖИВАЛ пересборку системы: ставишь
новые пакеты, меняешь систему — твои файлы остаются.

Каталог /home/slat создаётся именно здесь: в rootfs/ его нет, потому что
всё содержимое /home приходит с этого образа."
    [ $? -eq 0 ] || return 0

    if [ ! -f "$DATA" ]; then
        say "создаю $DATA ($DATA_SIZE)"
        dd if=/dev/zero of="$DATA" bs=1M count=$((${DATA_SIZE%M})) 2>/dev/null \
            || die "не создать $DATA"
        as_root mkfs.ext4 -q -F -L mydata "$DATA" 2>/dev/null \
            || die "не отформатировать data.img"
    else
        say "$DATA есть, данные сохраняю"
    fi

    as_root mkdir -p "$DATA_MNT" 2>/dev/null || :
    as_root umount "$DATA_MNT" 2>/dev/null || :
    as_root mount -o loop "$DATA" "$DATA_MNT" \
        || die "не примонтировать $DATA"
    say "готовлю домашний каталог"
    as_root mkdir -p "$DATA_MNT/slat"
    for sub in Documents Downloads Projects .config; do
        as_root mkdir -p "$DATA_MNT/slat/$sub"
    done
    as_root chown -R 1000:1000 "$DATA_MNT/slat"
    as_root chmod 755 "$DATA_MNT/slat"
    as_root umount "$DATA_MNT" || die "не размонтировать data.img"
    as_root rmdir "$DATA_MNT" 2>/dev/null || :
    say "домашний каталог готов"
}

cap_verify() {
    skip_ok 7 "Проверка до загрузки" \
"Прежде чем запускать виртуальную машину, смотрим на образ глазами.
Это дешевле, чем ловить ошибку в загрузке: тут мы видим, что файлы на
месте и права выставлены."
    [ $? -eq 0 ] || return 0

    as_root mkdir -p "$MNT" 2>/dev/null || :
    as_root mount -o loop,ro "$DISK" "$MNT" \
        || die "образ не монтируется — он побит"

    printf '\n  ключевые файлы:\n'
    for f in /init /bin/busybox /etc/dinit.conf /usr/local/bin/bdd \
             /usr/local/bin/sud /usr/local/bin/doas; do
        if [ -e "$MNT$f" ] || [ -L "$MNT$f" ]; then
            printf '    %sесть%s  %s\n' "$C_G" "$C_0" "$f"
        else
            printf '    %sНЕТ%s   %s\n' "$C_Y" "$C_0" "$f"
        fi
    done
    printf '\n  права:\n'
    as_root ls -la "$MNT/usr/local/bin/sud" 2>/dev/null | sed 's/^/    /'
    printf '\n  размер: %s\n' "$(du -sh "$MNT" 2>/dev/null | cut -f1)"
    as_root umount "$MNT" 2>/dev/null || :
    as_root rmdir "$MNT" 2>/dev/null || :

    say "если что-то выше помечено НЕТ — это может быть нормально"
    say "(например, doas: он появится, когда переименуем sudo)"
}

cap_boot() {
    skip_ok 8 "Первый запуск" \
"Запускаем QEMU. Система должна дойти до приглашения входа и сама войти
под пользователем slat.

Это единственный шаг, где мы не можем предугадать результат: если что-то
пойдёт не так, ты увидишь это на экране."
    [ $? -eq 0 ] || return 0

    say "запускаю ./run.sh"
    echo
    printf '  Управление QEMU: Ctrl+A затем X — выход.\n\n'
    ./run.sh
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --list) list_chapters; exit 0 ;;
            --yes|-y) YES=1; shift ;;
            [0-9]*) START=$1; shift ;;
            -h|--help) list_chapters; exit 0 ;;
            *) die "неизвестный аргумент: $1 (--list, --yes или номер главы)" ;;
        esac
    done

    [ "$YES" = 0 ] && { printf '\n'; list_chapters; printf '\n'; }

    printf '%s%s%s' "$C_B" "Установка slattware. Буду объяснять каждый шаг." "$C_0"
    printf 'Ctrl+C в любой момент — остановиться, ничего не испортится.\n'

    # Каждая глава выполняется, только если её номер не меньше START.
    # Раньше здесь стояли конструкции вида `[ "$START" -le 1 ] || :` ПОСЛЕ
    # вызова главы: они ничего не отменяли, и `./install.sh 3` честно
    # выполнял главы 1 и 2 тоже. Вот так — работает.
    run_cap() {
        [ "$1" -ge "$START" ] || { say "главу $1 пропускаю (начали с $START)"; return 0; }
        "cap_$2"
    }

    run_cap 1 check
    run_cap 2 kernel
    run_cap 3 initramfs
    run_cap 4 disk
    run_cap 5 rootfs
    run_cap 6 home
    run_cap 7 verify
    run_cap 8 boot

    printf '\n%sГотово.%s Запускай сколько угодно: ./run.sh\n' "$C_G" "$C_0"
}

main