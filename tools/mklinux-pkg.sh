#!/bin/sh
# mklinux-pkg.sh — положить собранное ядро в пакет bdd.
#
#   ./tools/mklinux-pkg.sh            собрать пакет linux в share/repo
#   ./tools/mklinux-pkg.sh --stage D  только разложить файлы в D
#
# --stage зовёт build: из bdd.meta: он кладёт vmlinuz и initrd.img
# в каталог boot/ рядом с собой, а mkrepo.sh потом переносит его
# в /boot через install:.
#
# ЗАЧЕМ ЭТОТ СКРИПТ, А НЕ ПРОСТО cp В build-partitioned.sh
#
# Ядро — не файл, а пакет. Пока оно копировалось скриптом установки,
# поставленная система не получала ядро из bdd: pacstrap ставил
# musl, busybox, dinit — и всё. Чтобы система была описана одним
# списком пакетов и обновлялась через bdd, ядро должно быть пакетом.
#
# ПОЧЕМУ НЕ КОПИРУЕМ В РЕПОЗИТОРИЙ НАПРЯМУЮ
#
# bzImage — 20 МБ. Если он лежит в share/repo/src/linux/, он попадёт в
# git и раздует репозиторий на двадцать мегабайт на КАЖДОЕ обновление
# ядра, причём история этого не отпустит. Поэтому файлы появляются
# только на время сборки пакета (build:), а в git их нет.
set -e

if [ -n "$SLAT_ROOT" ]; then
    ROOT=$SLAT_ROOT
else
    ROOT=$(cd "$(dirname "$0")/.." && pwd)
fi

# Версию ядра берём из config/KERNEL_VERSION, а не вытаскиваем из
# имени каталога: имя может быть любым (linux-7.2.10, linux-7.3-rc1),
# а версия в пакете должна совпадать с тем, что показывает uname.
VER=$(cat "$ROOT/config/KERNEL_VERSION") || {
    echo "нет config/KERNEL_VERSION" >&2; exit 1; }
TREE=$ROOT/kernel/$VER
BZ=$TREE/arch/x86/boot/bzImage

if [ "${1:-}" = "--stage" ]; then
    # Каталог boot/ ВНУТРИ переданного: install: в bdd.meta переносит
    # именно его, а раскладывать файлы в корень пакета нельзя —
    # mkrepo.sh кладёт одиночные файлы верхнего уровня либо в
    # /usr/local/bin, либо в доку и ругается на незнакомое расширение:
    #     непонятный файл в пакете: initrd.img
    DEST=${2:?нужен каталог}/boot
else
    # Самостоятельный запуск: файлы раскладывает build: внутри
    # mkrepo.sh, в копии исходника. Если разложить их ещё и здесь, в
    # share/repo/src/linux/boot, они останутся лежать в рабочем дереве
    # после сборки — ровно то, ради чего они и вынесены в .gitignore.
    DEST=$ROOT/share/repo/src/linux/boot
    mkdir -p "$DEST"
    trap 'rm -rf "$DEST"' EXIT INT TERM
fi

mkdir -p "$DEST"

# --- vmlinuz ---------------------------------------------------------------
[ -f "$BZ" ] || {
    echo "нет собранного ядра: $BZ" >&2
    echo "собери сначала: ./tools/build-kernel.sh" >&2
    exit 1
}
# Имя vmlinuz, а не bzImage: загрузчик и GRUB знают это имя, и в
# /boot не должно лежать bzImage, которое никто не ищет.
cp -f "$BZ" "$DEST/vmlinuz"
chmod 644 "$DEST/vmlinuz"

# --- initramfs -------------------------------------------------------------
# Собираем ЗДЕСЬ, из initramfs/, а не берём готовый из build-iso/.
#
# Там лежит initramfs с ЖИВОЙ СИСТЕМОЙ внутри: 7.8 МБ, с bdd,
# pacstrap и репозиторием. Установленной системе всё это лишнее и
# вредное — она загрузилась бы в Live CD вместо себя.
#
# initramfs/ после mkiso.sh остаётся чистым: скрипт кладёт
# liveroot.cpio.gz на время сборки ISO и убирает за собой.
for stray in "$ROOT/initramfs/liveroot.cpio.gz"; do
    [ -e "$stray" ] && {
        echo "ВНИМАНИЕ: $stray не убран — в пакет ядра попадёт Live CD." >&2
        exit 1
    }
done

( cd "$ROOT/initramfs" && find . | sort | cpio -o -H newc 2>/dev/null ) \
    | gzip -9 > "$DEST/initrd.img"

# Проверки. Обе ловили бы ошибку только на загрузке.
[ -x "$ROOT/initramfs/init" ] || {
    echo "initramfs/init не исполняемый — ядро не дойдёт до switch_root" >&2
    exit 1
}
zcat "$DEST/initrd.img" | cpio -tv 2>/dev/null | grep -q 'dev/console' || {
    echo "в initramfs нет dev/console — ядро не откроет консоль" >&2
    exit 1
}

printf '  vmlinuz:    %s\n' "$(du -h "$DEST/vmlinuz" | cut -f1)"
printf '  initrd.img: %s\n' "$(du -h "$DEST/initrd.img" | cut -f1)"

if [ -n "$SLAT_ROOT" ]; then
    # Режим --stage из build:. дальше работает mkrepo.sh
    exit 0
fi

# --- синхронизация версии --------------------------------------------------
# mkrepo.sh читает version: из bdd.meta ДО запуска build:. То есть
# build: версию не обновит, сколько ни старайся, и после обновления ядра
# пакет назывался бы linux-7.2.8.bddpkg при bzImage из 7.2.10.
#
# Поэтому перед сборкой приводим строку в соответствие с
# config/KERNEL_VERSION — это единственное место, где версия
# записывается, и берётся она из одного файла.
META=$ROOT/share/repo/src/linux/bdd.meta
_cur=$(sed -n 's/^version:[[:space:]]*//p' "$META" | head -n1)
if [ "$_cur" != "$VER" ]; then
    printf '  версия пакета: %s → %s\n' "$_cur" "$VER"
    sed -i "s/^version:[[:space:]]*.*/version: $VER/" "$META"
fi

"$ROOT/tools/mkrepo.sh" linux