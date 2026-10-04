#!/bin/sh
# build.sh — сборка mydistro: initramfs + образ корневой ФС.
#
#   ./build.sh            обновить initramfs и СИНХРОНИЗИРОВАТЬ rootfs в disk.img
#   ./build.sh --clean    полностью пересоздать disk.img с нуля
#   ./build.sh --initramfs-only   только initramfs
#   ./build.sh --disk-only        только образ диска
#
# Важно: по умолчанию образ НЕ пересоздаётся. Всё, что поставлено через bdd
# (а это /usr/local, /var, /root) переживает пересборку. Полный сброс — --clean.

set -e
cd "$(dirname "$0")"

ROOTFS=$PWD/rootfs
DISK=disk.img
DATA=data.img
MNT=${MNT:-/tmp/mydistro-mnt}
DATA_MNT=${DATA_MNT:-/tmp/mydistro-data}

# Размеры образов
DISK_SIZE=${DISK_SIZE:-512M}
DATA_SIZE=${DATA_SIZE:-256M}

CLEAN=0
WHAT=all

for a in "$@"; do
    case "$a" in
        --clean)  CLEAN=1 ;;
        --initramfs-only) WHAT=initramfs ;;
        --disk-only)      WHAT=disk ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "неизвестный аргумент: $a" >&2; exit 1 ;;
    esac
done

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31mошибка:\033[0m %s\n' "$*" >&2; exit 1; }

as_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas "$@"
    else
        die "нужны права root (doas/sudo)"
    fi
}

# --------------------------------------------------------------------------
# 1. initramfs
# --------------------------------------------------------------------------
build_initramfs() {
    say "собираю initramfs"
    [ -d initramfs ] || die "нет каталога initramfs"
    [ -x initramfs/bin/busybox ] || die "initramfs/bin/busybox не найден или не исполняем"

    # Порядок файлов фиксируем, чтобы образ был воспроизводимым
    (cd initramfs && find . | sort | cpio -o -H newc 2>/dev/null) \
        | gzip -9 > "$INITRD"
    say "initramfs: $(du -h "$INITRD" | cut -f1)"
}

# --------------------------------------------------------------------------
# 2. образ корневой ФС
# --------------------------------------------------------------------------
fresh_disk() {
    say "создаю $DISK ($DISK_SIZE)"
    rm -f "$DISK"
    dd if=/dev/zero of="$DISK" bs=1M count=$((${DISK_SIZE%M})) 2>/dev/null \
        || die "не создать $DISK"
    mkfs.ext4 -q -F -L mydistro "$DISK" 2>/dev/null \
        || die "не отформатировать $DISK (ext4 нужен root-доступ или mkfs.ext4)"
}

sync_disk() {
    say "синхронизирую rootfs/ в $DISK (сохраняя /usr/local, /var, /root)"
    as_root mkdir -p "$MNT"
    as_root umount "$MNT" 2>/dev/null || :
    as_root mount -o loop "$DISK" "$MNT" || die "не примонтировать $DISK"

    # Копируем всё, кроме тех мест, которые переживают пересборку
    (cd "$ROOTFS" && tar -cf - .) | as_root tar -xf - -C "$MNT"

    # Восстанавливаем владельца на системных файлах. В /usr/local и /var
    # тоже: там живут пакеты bdd, и файлы, поставленные пакетом, должны
    # принадлежать root (иначе setuid-бит бесполезен, а удалить их
    # нечем). Владелец из tar не выставляем — он был бы твоим uid.
    as_root chown -R 0:0 "$MNT"/bin "$MNT"/sbin "$MNT"/lib "$MNT"/lib64 2>/dev/null || :
    as_root chown -R 0:0 "$MNT"/etc "$MNT"/init 2>/dev/null || :
    as_root chown -R 0:0 "$MNT"/usr 2>/dev/null || :
    as_root chown -R 0:0 "$MNT"/var 2>/dev/null || :
    as_root chown -R 0:0 "$MNT"/root 2>/dev/null || :

    # Синхронизировать busybox-ссылки в /bin
    say "обновляю ссылки busybox в /bin"
    as_root chroot "$MNT" /bin/busybox --install -s /bin 2>/dev/null || :
    as_root chown -R 0:0 "$MNT"/bin 2>/dev/null || :

    # setuid-бит на sud — иначе он не сможет стать root.
    # chown выше уже сделал его владельцем root.
    if [ -f "$ROOTFS/usr/local/bin/sud" ]; then
        as_root chmod 4755 "$MNT/usr/local/bin/sud" 2>/dev/null \
            || warn "не поставил setuid на sud"
    fi

    # Права на /tmp и /var/tmp должны быть 1777 (липкая, доступная всем)
    as_root chmod 1777 "$MNT/tmp" "$MNT/var/tmp" 2>/dev/null || :

    as_root sync
    as_root umount "$MNT"
    as_root rmdir "$MNT" 2>/dev/null || :
    say "образ обновлён: $(du -h "$DISK" | cut -f1)"
}

build_disk() {
    if [ "$CLEAN" = 1 ] || [ ! -f "$DISK" ]; then
        fresh_disk
    else
        # Проверяем, что образ вообще монтируется. Если нет — пересоздаём.
        as_root mkdir -p "$MNT" 2>/dev/null || :
        if as_root mount -o loop,ro "$DISK" "$MNT" 2>/dev/null; then
            as_root umount "$MNT"
            say "$DISK читается, обновляю поверх"
        else
            warn "$DISK не читается, пересоздаю"
            as_root umount "$MNT" 2>/dev/null || :
            fresh_disk
        fi
    fi
    sync_disk
}

# --------------------------------------------------------------------------
# 3. data.img — постоянное хранилище, монтируется в /home
# --------------------------------------------------------------------------
build_data() {
    if [ ! -f "$DATA" ] || [ "$CLEAN" = 1 ]; then
        say "создаю $DATA ($DATA_SIZE, ext4, LABEL=mydata)"
        rm -f "$DATA"
        dd if=/dev/zero of="$DATA" bs=1M count=$((${DATA_SIZE%M})) 2>/dev/null \
            || die "не создать $DATA"
        mkfs.ext4 -q -F -L mydata "$DATA" 2>/dev/null \
            || die "не отформатировать $DATA"
    else
        say "$DATA существует, данные сохраняю"
    fi
    ensure_home
}

# Домашний каталог пользователя внутри data.img.
#
# /home целиком приходит с data.img, поэтому каталога /home/slat в образе
# нет — он живёт именно здесь. Если data.img создан до того, как мы это
# придумали (или его кто-то подчистил), создаём заново, иначе пользователь
# получает «Permission denied» на mkdir и не может работать у себя дома.
ensure_home() {
    as_root mkdir -p "$DATA_MNT"
    # Если предыдущий запуск упал посреди работы, точка может остаться
    # занятой — сначала снимаем старое монтирование, иначе получим ro.
    as_root umount "$DATA_MNT" 2>/dev/null || :
    as_root umount "$DATA_MNT" 2>/dev/null || :
    as_root mount -o loop "$DATA" "$DATA_MNT" || die "не примонтировать $DATA"
    if [ ! -d "$DATA_MNT/slat" ]; then
        say "создаю /home/slat в $DATA"
        as_root mkdir -p "$DATA_MNT/slat"
    fi
    as_root mkdir -p "$DATA_MNT"/slat/Documents "$DATA_MNT"/slat/Downloads \
                      "$DATA_MNT"/slat/Projects "$DATA_MNT"/slat/.config
    # 1000 — uid slat в /etc/passwd
    as_root chown -R 1000:1000 "$DATA_MNT"/slat
    as_root chmod 755 "$DATA_MNT/slat"
    as_root umount "$DATA_MNT"
    as_root rmdir "$DATA_MNT" 2>/dev/null || :
}

# --------------------------------------------------------------------------
# 4. проверки: скрипты без +x ломают загрузку молча
# --------------------------------------------------------------------------
lint_rootfs() {
    bad=$(find "$ROOTFS" -type f \
        \( -name '*.sh' -o -path '*/dinit.d/*' -o -name 'bdd' \
           -o -name 'sudo' -o -name 'poweroff' -o -name 'reboot' \) \
        ! -perm -u+x 2>/dev/null)
    if [ -n "$bad" ]; then
        warn "эти файлы не исполняемые, dinit не сможет их запустить:"
        printf '%s\n' "$bad" | sed 's|^|    |'
    fi

    # Скрипты без shebang
    for f in $(find "$ROOTFS/etc" "$ROOTFS/usr/local/bin" -type f \
                 \( -name '*.sh' -o -name 'bdd' -o -name 'sudo' \
                    -o -name 'poweroff' -o -name 'reboot' \) 2>/dev/null); do
        head -c2 "$f" | grep -q '#!' || warn "нет shebang: $f"
    done
}

# --------------------------------------------------------------------------
main() {
    INITRD=initramfs.cpio.gz
    export INITRD

    lint_rootfs

    case "$WHAT" in
        initramfs) build_initramfs ;;
        disk)      build_disk; build_data ;;
        *)         build_initramfs; build_disk; build_data ;;
    esac

    echo
    echo "Готово:"
    [ -f "$INITRD" ] && printf '  %-24s %s\n' "$INITRD" "$(du -h "$INITRD" | cut -f1)"
    [ -f "$DISK" ]   && printf '  %-24s %s\n' "$DISK"   "$(du -h "$DISK" | cut -f1)"
    [ -f "$DATA" ]   && printf '  %-24s %s\n' "$DATA"   "$(du -h "$DATA" | cut -f1)"
    echo
    echo "Запуск:  ./run.sh"
    echo "Полный сброс: ./build.sh --clean && ./run.sh"
}

main
