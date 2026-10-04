#!/bin/sh
# build-partitioned.sh — разложить систему по РАЗДЕЛАМ, созданным partition.sh.
#
# Обычный build.sh кладёт всё в один файл без разделов, и QEMU видит его
# как /dev/vda. Здесь же образ разбит на два раздела (partition.sh), и
# система раскладывается в раздел 1, а /home — в раздел 2. Это уже
# «настоящая» разметка, как в Arch после parted.
#
#   ./partition.sh                 спросит размеры и разметит
#   ./build-partitioned.sh         разложит систему по разделам
#
# Загрузчик (GRUB) ставится отдельным шагом — grub.sh.

set -e
cd "$(dirname "$0")"

DISK=${DISK:-partitioned.img}
MNT=${MNT:-/tmp/slattware-part}
HOME_MNT=${HOME_MNT:-/tmp/slattware-home-part}
ROOTFS=$PWD/rootfs
INITRD=$PWD/initramfs.cpio.gz

ESC=$(printf '\033')
C_C=$ESC'[36m'; C_G=$ESC'[32m'; C_R=$ESC'[31m'; C_Y=$ESC'[33m'; C_0=$ESC'[0m'
say()  { printf '%s==>%s %s\n' "$C_C" "$C_0" "$*"; }
warn() { printf '%swarn:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sошибка:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"
    elif command -v doas >/dev/null 2>&1; then doas "$@"
    else die "нужны права root"; fi
}

[ -f "$DISK" ] || die "нет $DISK — сначала ./partition.sh"
[ -d "$ROOTFS" ] || die "нет rootfs/"

cleanup() {
    as_root umount "$HOME_MNT" 2>/dev/null || :
    as_root umount "$MNT" 2>/dev/null || :
    as_root losetup -d "$LOOP" 2>/dev/null || :
    as_root rmdir "$MNT" "$HOME_MNT" 2>/dev/null || :
}
trap cleanup EXIT INT TERM

# --- разделы --------------------------------------------------------------
# Сначала отсоединяем ВСЕ loop-устройства, оставшиеся на этом файле.
# Иначе к образу цепляется второй loop, разделы появляются на нём, а мы
# форматируем первый — и получаем «wrong fs type», хотя всё «сделано».
for _l in $(as_root losetup -j "$DISK" 2>/dev/null | cut -d: -f1); do
    say "отсоединяю оставшийся loop: $_l"
    as_root losetup -d "$_l" 2>/dev/null || :
done

# `losetup -f` только печатает имя, но не подключает файл — нужен --show.
LOOP=$(as_root losetup --show -f "$DISK" 2>/dev/null | head -1)
[ -n "$LOOP" ] || die "не подключить $DISK как loop"
partprobe "$DISK" 2>/dev/null || :
as_root partx -a "$LOOP" 2>/dev/null || :
sleep 1

SYS_PART="${LOOP}p1"
HOME_PART="${LOOP}p2"
[ -b "$SYS_PART" ]  || die "нет раздела системы $SYS_PART"
[ -b "$HOME_PART" ] || die "нет раздела /home $HOME_PART"

say "система:  $SYS_PART  $(doas blkid -s LABEL -o value "$SYS_PART" 2>/dev/null)"
say "/home:    $HOME_PART  $(doas blkid -s LABEL -o value "$HOME_PART" 2>/dev/null)"

# --- initramfs ------------------------------------------------------------
say "собираю initramfs"
(cd initramfs && find . | sort | cpio -o -H newc 2>/dev/null) | gzip -9 > "$INITRD" \
    || die "не собрать initramfs"

# --- система --------------------------------------------------------------
as_root mkdir -p "$MNT"
as_root mount "$SYS_PART" "$MNT" || die "не примонтировать раздел системы"

say "копирую rootfs/ в раздел системы"
(cd "$ROOTFS" && tar -cf - .) | as_root tar -xf - -C "$MNT" \
    || die "не скопировать rootfs"

say "ставлю владельца root"
for d in bin sbin lib lib64 etc init usr var root boot; do
    as_root chown -R 0:0 "$MNT/$d" 2>/dev/null || :
done
as_root mkdir -p "$MNT/boot"
say "ссылки busybox"
as_root chroot "$MNT" /bin/busybox --install -s /bin 2>/dev/null || :
as_root chown -R 0:0 "$MNT/bin" 2>/dev/null || :
if [ -f "$ROOTFS/usr/local/bin/sud" ]; then
    say "setuid на sud"
    as_root chmod 4755 "$MNT/usr/local/bin/sud" 2>/dev/null || :
fi
as_root chmod 1777 "$MNT/tmp" "$MNT/var/tmp" 2>/dev/null || :

say "кладу ядро и initramfs в /boot раздела"
as_root cp kernel/7.2.8/arch/x86/boot/bzImage "$MNT/boot/vmlinuz"
as_root cp "$INITRD" "$MNT/boot/initrd.img"
as_root chown 0:0 "$MNT/boot/vmlinuz" "$MNT/boot/initrd.img"

as_root sync
as_root umount "$MNT" || die "не размонтировать системный раздел"

# --- домашний каталог -----------------------------------------------------
as_root mkdir -p "$HOME_MNT"
as_root mount "$HOME_PART" "$HOME_MNT" || die "не примонтировать /home"
say "готовлю /home/slat"
as_root mkdir -p "$HOME_MNT/slat"
for sub in Documents Downloads Projects .config; do
    as_root mkdir -p "$HOME_MNT/slat/$sub"
done
as_root chown -R 1000:1000 "$HOME_MNT/slat"
as_root chmod 755 "$HOME_MNT/slat"
as_root sync
as_root umount "$HOME_MNT" || die "не размонтировать /home"

printf '\n%sГотово.%s\n' "$C_G" "$C_0"
echo "  $DISK разбит на два раздела, система в первом, /home во втором."
echo
echo "Дальше — поставить загрузчик:  ./grub.sh"
echo "Или проверить руками:         ./run-partitioned.sh"