#!/bin/sh
# partition.sh — разбить образ диска на разделы, как ты делаешь руками в Arch.
#
# В Arch второй шаг установки: ты сам решаешь, сколько мегабайт отдать под
# систему, сколько под файлы. Здесь то же самое, только числами.
#
#   ./partition.sh                    спросит размеры и разметит disk.img
#   ./partition.sh --system 400       без вопросов: 400 МБ под систему
#   ./partition.sh --home 600         сколько под /home (остаток)
#   ./partition.sh --show             только показать текущую разметку
#
# Схема: MBR (msdos), два раздела, без выравнивания «на всякий случай» —
# ровно как parted mkpart в Arch.
#
#   sda1  →  /      ext4   ← системные файлы, ядро, загрузчик
#   sda2  →  /home  ext4   ← твои файлы, переживает пересборку
#
# ВНИМАНИЕ: разметка ПЕРЕЗАПИСЫВАЕТ образ. Сначала сделай копию.

set -e
cd "$(dirname "$0")"

DISK=${DISK:-partitioned.img}
SYS_MB=""
HOME_MB=""
SHOW=0

while [ $# -gt 0 ]; do
    case "$1" in
        --system) SYS_MB=$2; shift 2 ;;
        --home)   HOME_MB=$2; shift 2 ;;
        --show)   SHOW=1; shift ;;
        --disk)   DISK=$2; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
done

ESC=$(printf '\033')
C_C=$ESC'[36m'; C_B=$ESC'[1m'; C_G=$ESC'[32m'; C_R=$ESC'[31m'
C_Y=$ESC'[33m'; C_0=$ESC'[0m'

say()  { printf '%s==>%s %s\n' "$C_C" "$C_0" "$*"; }
warn() { printf '%swarn:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sошибка:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"
    elif command -v doas >/dev/null 2>&1; then doas "$@"
    else die "нужны права root"; fi
}

# --- показать -------------------------------------------------------------
show_table() {
    say "разметка $DISK:"
    sfdisk -l "$DISK" 2>&1 | sed 's/^/    /'
    echo
    say "таблица разделов:"
    sfdisk -d "$DISK" 2>&1 | sed 's/^/    /'
}

if [ "$SHOW" = 1 ]; then
    [ -f "$DISK" ] || die "нет файла $DISK (создай: fallocate -l 1G $DISK)"
    show_table
    exit 0
fi

# --- спросить размеры -----------------------------------------------------
TOTAL_MB=${TOTAL_MB:-1024}

echo "${C_B}Разбиваем диск на разделы.${C_0}"
echo "Всего: ${TOTAL_MB} МБ"
echo
echo "  ${C_B}1${C_0} — раздел системы  (/)      ext4, сюда ляжет сама ОС"
echo "  ${C_B}2${C_0} — домашний каталог (/home)  ext4, твои файлы"
echo
echo "В Arch ты бы сейчас набрал числа parted'ом. Здесь — то же самое."
echo

if [ -z "$SYS_MB" ]; then
    printf 'Сколько МБ отдать под систему? [384] '
    read -r _a || _a=384
    SYS_MB=${_a:-384}
fi
if [ -z "$HOME_MB" ]; then
    _rest=$((TOTAL_MB - SYS_MB))
    printf 'Сколько МБ под /home? [%s] ' "$_rest"
    read -r _a || _a=$_rest
    HOME_MB=${_a:-$_rest}
fi

case "$SYS_MB$HOME_MB" in
    ''|*[!0-9]*) die "размеры должны быть числами" ;;
esac
[ "$SYS_MB" -gt 0 ] || die "под систему должно быть больше нуля"
[ "$HOME_MB" -gt 0 ] || die "под /home должно быть больше нуля"

USED=$((SYS_MB + HOME_MB))
LEFT=$((TOTAL_MB - USED))

echo
say "система: ${SYS_MB} МБ, /home: ${HOME_MB} МБ"
if [ "$LEFT" -gt 0 ]; then
    say "остаётся неиспользованным: ${LEFT} МБ"
elif [ "$LEFT" -lt 0 ]; then
    die "сумма (${USED} МБ) больше диска (${TOTAL_MB} МБ)"
fi

# --- создать образ --------------------------------------------------------
if [ ! -f "$DISK" ]; then
    say "создаю образ на ${TOTAL_MB} МБ: $DISK"
    rm -f "$DISK"
    fallocate -l "${TOTAL_MB}M" "$DISK" 2>/dev/null \
        || dd if=/dev/zero of="$DISK" bs=1M count="$TOTAL_MB" 2>/dev/null \
        || die "не создать $DISK"
fi
say "образ: $(du -h "$DISK" | cut -f1)"

printf 'Разметить? [y/N] '
read -r _a || _a=n
case $_a in y|Y) : ;; *) say "отмена"; exit 0 ;; esac

# --- разметить ------------------------------------------------------------
# sfdisk в скриптовом режиме: читает разметку с stdin. Это воспроизводимо:
# тот же вход — та же разметка.
say "пишу таблицу разделов (MBR, msdos)"
sfdisk "$DISK" >/dev/null 2>&1 <<EOF
label: dos
unit: sectors

${DISK}1 : start=2048, size=$((SYS_MB * 2048)), type=83, bootable
${DISK}2 : start=$((2048 + SYS_MB * 2048)), size=$((HOME_MB * 2048)), type=83
EOF

# --- форматирование -------------------------------------------------------
# ВАЖНО: `losetup -f "$DISK"` только ПЕЧАТАЕТ имя свободного устройства и
# ничего не подключает. После этого losetup -j пуст, и скрипт цеплялся к
# loop, оставшемуся от прошлого прогона: раздел p1 форматировался, а p2
# оставался без ФС, и в г��сте давал "Invalid argument".
LOOP=$(as_root losetup --show -f "$DISK" 2>/dev/null | head -1)
[ -n "$LOOP" ] || die "не подключить $DISK как loop"

# `losetup --show -f` уже отдаёт готовое имя вида /dev/loop0 —
# нормализовывать больше нечего (раньше здесь был лишний префикс loop).
say "loop-устройство: $LOOP"

# partprobe на файле образа молчит, а разделы нужны как /dev/loopNpN,
# иначе mkfs не на что наткнуться. partx -a создаёт их явно.
partprobe "$DISK" 2>/dev/null || true
as_root partx -a "$LOOP" 2>/dev/null || true
sleep 1

# Раздел мог уже существовать: тогда partx ругается, а /dev/...p1 есть.
[ -b "${LOOP}p1" ] || as_root partx -a "$LOOP" 2>/dev/null || true
[ -b "${LOOP}p1" ] || die "ядро не показало разделы ${LOOP}p1 (partprobe/partx не сработали)"

echo
say "форматирую sda1 (система)"
as_root mkfs.ext4 -q -F -L mydistro "${LOOP}p1" 2>/dev/null \
    || as_root mkfs.ext4 -q -F -L mydistro "${LOOP}1" 2>/dev/null \
    || die "не отформатировать раздел системы"

# Метка mydata — не опечатка: /etc/fstab ждёт LABEL=mydata для домашней
# ФС, и data.img в обычной схеме помечен так же. Раздел и отдельный
# диск должны выглядеть для системы одинаково.
say "форматирую sda2 (/home)"
as_root mkfs.ext4 -q -F -L mydata "${LOOP}p2" 2>/dev/null \
    || as_root mkfs.ext4 -q -F -L mydata "${LOOP}2" 2>/dev/null \
    || die "не отформатировать /home"

echo
say "${C_G}готово${C_0}"
show_table
echo
echo "Что дальше: ./build.sh --partitioned   (разложить систему по разделам)"