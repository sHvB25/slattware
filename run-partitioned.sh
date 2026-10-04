#!/bin/sh
# run-partitioned.sh — запустить систему с РАЗДЕЛЁННОГО диска.
#
# Отличие от run.sh: образ разбит на разделы, поэтому:
#   - initramfs ищет корень как /dev/vda1 (а не /dev/vda);
#   - /home лежит на втором разделе того же диска, а не в отдельном data.img;
#   - никакого 9p-обмена с хостом и никаких разделов на 512p.
#
#   ./run-partitioned.sh              обычный запуск
#   ./run-partitioned.sh --append-only  показать параметры ядра и выйти

cd "$(dirname "$0")" || exit 1

KERNEL=kernel/7.2.8/arch/x86/boot/bzImage
INITRD=initramfs.cpio.gz
DISK=partitioned.img

MEM=${MEM:-1024}
SMP=${SMP:-2}
APPEND_ONLY=""
for a in "$@"; do
    case "$a" in --append-only) APPEND_ONLY=1 ;; esac
done

[ -f "$KERNEL" ] || { echo "нет ядра: $KERNEL" >&2; exit 1; }
[ -f "$DISK" ]   || { echo "нет образа: $DISK (сначала ./partition.sh && ./build-partitioned.sh)" >&2; exit 1; }
[ -f "$INITRD" ] || { echo "нет initramfs" >&2; exit 1; }

# root=/dev/vda1 — раздел системы. nohz=off обязателен: при CONFIG_NO_HZ_IDLE
# гость, уснувший в ожидании ответа 9p, не просыпается (см. TODO, B49).
APPEND="console=ttyS0 root=/dev/vda1 rootfstype=ext4 rw loglevel=4 nohz=off"

if [ -n "$APPEND_ONLY" ]; then
    echo "kernel: $KERNEL"
    echo "initrd: $INITRD"
    echo "диск:   $DISK (разделы: vda1=/, vda2=/home)"
    echo "append: $APPEND"
    exit 0
fi

echo "==> Запуск. Выход: Ctrl+A затем X"
echo "==> Диск разбит: vda1=/ (система), vda2=/home"
echo

exec qemu-system-x86_64 \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -append "$APPEND" \
  -m "$MEM" \
  -smp "$SMP" \
  -drive file="$DISK",if=virtio,format=raw \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -nographic -no-reboot