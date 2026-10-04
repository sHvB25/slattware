#!/bin/sh
# run.sh — запуск mydistro в QEMU.
#
#   ./run.sh                 запустить (без пересборки, если образ свежий)
#   ./run.sh --rebuild       пересобрать initramfs + образ, потом запустить
#   ./run.sh --clean         полный сброс образов, потом запустить
#   ./run.sh --gui           с окном (нужен дисплей)
#   ./run.sh --extra "..."   дописать параметры ядра
#   ./run.sh --append-only   ничего не пересобирать и не запускать, только показать cmdline
#
# Данные не теряются: /home живёт на data.img, а образ обновляется поверх.

set -e
cd "$(dirname "$0")"

KERNEL=kernel/7.2.8/arch/x86/boot/bzImage
INITRD=initramfs.cpio.gz
DISK=disk.img
DATA=data.img

REBUILD=0
CLEAN=0
GUI=0
EXTRA=""
MEM=1024
SMP=2
APPEND_EXTRA=""

while [ $# -gt 0 ]; do
    case "$1" in
        --rebuild)  REBUILD=1; shift ;;
        --clean)    CLEAN=1; REBUILD=1; shift ;;
        --gui)      GUI=1; shift ;;
        --extra)    EXTRA="$2"; shift 2 ;;
        --append-only) APPEND_ONLY=1; shift ;;
        --mem)      MEM="$2"; shift 2 ;;
        --smp)      SMP="$2"; shift 2 ;;
        -h|--help)  sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
done

[ -f "$KERNEL" ] || { echo "нет ядра: $KERNEL" >&2; exit 1; }

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

# --- сборка ----------------------------------------------------------------
if [ "$REBUILD" = 1 ]; then
    if [ "$CLEAN" = 1 ]; then
        ./build.sh --clean
    else
        ./build.sh
    fi
else
    # Собираем, только если initramfs новее исходников или образа
    needs=0
    [ ! -f "$INITRD" ] && needs=1
    [ ! -f "$DISK" ] && needs=1
    if [ "$needs" = 0 ]; then
        newer=$(find initramfs -newer "$INITRD" 2>/dev/null | head -n1)
        [ -n "$newer" ] && needs=1
        newer=$(find rootfs -newer "$DISK" 2>/dev/null | head -n1)
        [ -n "$newer" ] && needs=1
    fi
    if [ "$needs" = 1 ]; then
        echo "==> образ устарел, пересобираю"
        ./build.sh
    fi
fi

# --- параметры ядра --------------------------------------------------------
# nohz=off обязателен: ядро собрано с CONFIG_NO_HZ_IDLE=y, и под TCG
# гость, ушедший в idle в ожидании ответа 9p, больше не просыпается —
# висят оба vCPU, QEMU ест 0% CPU, запись в /shared не возвращается.
APPEND="console=ttyS0 root=/dev/vda rootfstype=ext4 rw quiet loglevel=4 nohz=off"
APPEND="$APPEND $APPEND_EXTRA"

if [ -n "${APPEND_ONLY:-}" ]; then
    echo "kernel: $KERNEL"
    echo "initrd: $INITRD"
    echo "append: $APPEND"
    exit 0
fi

# --- запуск ----------------------------------------------------------------
QEMU="qemu-system-x86_64 \
  -kernel $KERNEL \
  -initrd $INITRD \
  -append '$APPEND' \
  -m $MEM \
  -smp $SMP \
  -drive file=$DISK,if=virtio,format=raw \
  -drive file=$DATA,if=virtio,format=raw \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -fsdev local,id=fs0,path=$PWD/share,security_model=none \
  -device virtio-9p-pci,fsdev=fs0,mount_tag=host"

if [ "$GUI" = 1 ]; then
    QEMU="$QEMU -display gtk -serial stdio"
else
    QEMU="$QEMU -nographic"
fi

[ -n "$EXTRA" ] && QEMU="$QEMU $EXTRA"

# Передать гостю время и часовой пояс хоста: без RTC в QEMU после suspend
# гость может проснуться со старым временем, а базы zoneinfo у него нет.
./tools/hostinfo.sh || warn "не удалось записать share/.hosttime"

echo "==> Запуск. Выход: Ctrl+A затем X"
echo "==> Вход автоматический (пользователь slat, пароля нет)"
echo

exec $QEMU
