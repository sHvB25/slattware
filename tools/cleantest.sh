#!/bin/sh
# cleantest.sh — прогнать полный сбой и запуск с нуля, не потеряв данные.
#
#   ./tools/cleantest.sh
#
# Что делает:
#   1. сохраняет содержимое data.img (домашний каталог) во временную папку
#   2. ./build.sh --clean
#   3. кладёт сохранённые файлы обратно в data.img
#   4. запускает сценарий из госта через tools/vmsh.sh
set -e
cd "$(dirname "$0")/.."

SCRIPT=${1:-tools/guest-fresh-test.sh}
KEEP=${TMPDIR:-/tmp}/cleantest.$$
MOUNT=${TMPDIR:-/tmp}/cleantest-mnt.$$

as_root() { doas "$@"; }

cleanup() {
    as_root umount "$MOUNT" 2>/dev/null || :
    rmdir "$MOUNT" 2>/dev/null || :
    # файлы в $KEEP скопированы с сохранением владельца и прав,
    # поэтому rm от обычного пользователя может не справиться
    as_root rm -rf "$KEEP" 2>/dev/null || rm -rf "$KEEP" 2>/dev/null || :
}
trap cleanup EXIT INT TERM

mkdir -p "$KEEP" "$MOUNT"
printf '==> сохраняю домашний каталог\n'
as_root mount -o loop data.img "$MOUNT"
as_root cp -a "$MOUNT"/. "$KEEP" 2>/dev/null || :
as_root umount "$MOUNT"

printf '==> build.sh --clean\n'
./build.sh --clean

printf '==> возвращаю домашний каталог\n'
as_root mount -o loop data.img "$MOUNT"
as_root cp -a "$KEEP"/. "$MOUNT"/ 2>/dev/null || :
as_root sync
as_root umount "$MOUNT"

printf '==> запуск гостя со сценарием %s\n' "$SCRIPT"
./tools/vmsh.sh -s "$SCRIPT" -t 120