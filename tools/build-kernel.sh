#!/bin/sh
# build-kernel.sh — собрать ядро для slattware воспроизводимо.
#
# Не «зашёл в menuconfig и нащёл», а: взять штатный defconfig, наложить
# config/linux.config, собрать. Конфигурация в git, а не в памяти.
#
#   ./tools/build-kernel.sh              обычная сборка
#   ./tools/build-kernel.sh clean        снести и собрать с нуля
#   ./tools/build-kernel.sh jobs         сколько параллельных сборок

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VER=$(cat "$ROOT/config/KERNEL_VERSION")
TREE="$ROOT/kernel/$VER"
FRAG="$ROOT/config/linux.config"
JOBS=$(nproc 2>/dev/null || echo 4)

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mсборка ядра:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$1" = clean ] && shift && JOBS_ARG=$1 || JOBS_ARG=
[ -n "$JOBS_ARG" ] && JOBS=$JOBS_ARG

[ -d "$TREE" ] || die "нет исходников ядра: $TREE
  Ядро — это чужой upstream и в git не лежит (2.7 ГБ).
  Скачай его так:
      mkdir -p $ROOT/kernel
      curl -LO https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$VER.tar.xz
      tar -C $ROOT/kernel -xf linux-$VER.tar.xz
      mv $ROOT/kernel/linux-$VER $TREE
  Либо просто возьми уже распакованное дерево."

[ -f "$FRAG" ] || die "нет конфигурации: $FRAG"

if [ "${1:-}" = clean ]; then
    say "чищу дерево сборки"
    ( cd "$TREE" && make mrproper ) || :
fi

# --- 1. базовая конфигурация ------------------------------------------------
# x86_64_defconfig — то, что собирает сам разработчик ядра для проверки.
# Наша задача не «сделать хорошо», а получить рабочий старт, который
# дальше правится нашим фрагментом.
say "defconfig"
( cd "$TREE" && make x86_64_defconfig ) >/dev/null

# --- 2. наш фрагмент поверх ------------------------------------------------
# merge_config.sh спросит про новые символы и оставит их пустыми —
# поэтому отвечаем заранее, иначе он зависнет на stdin.
say "накладываю config/linux.config"
( cd "$TREE" && \
  yes "" | ./scripts/kconfig/merge_config.sh -m -O . "$FRAG" .config \
) >/dev/null 2>&1 || true

# merge_config пересобирает .config только через make oldconfig. Без
# явного oldconfig символы, которых не было в defconfig, просто не
# появятся — и мы получим ядро без AMDGPU, молча.
say "oldconfig"
( cd "$TREE" && yes "" | make oldconfig ) >/dev/null

# --- 3. проверяем, что критичное реально включилось -------------------------
# Шаг не параноидальный. merge_config на несуществующее имя молча
# выдаёт предупреждение, которое тонет в выводе make, и ядро собирается
# без AMDGPU — а выясняется это потом, на чёрном экране.
#
# Сначала сверяем весь фрагмент с настоящими Kconfig: символ, которого
# нет в дереве, — это опечатка, а не «опция не применилась».
say "проверяю символы фрагмента по Kconfig"
# Ложные срабатывания дают menu-символы (ATA, NLS, CRYPTO, CGROUPS,
# NETFILTER, INPUT_*): объявляются как menu, в .config есть, называются
# в Kconfig иначе. Их не ловим.
bogus=
for c in $(grep -oE '^CONFIG_[A-Z_0-9]+' "$FRAG" | sort -u); do
    # Отступ обязателен: config внутри menu идёт с ведущим пробелом
    # (drivers/ata/Kconfig — «config ATA_PIIX»), а config верхнего
    # уровня — без него. Без учёта отступа ATA_PIIX и BLK_DEV_SD
    # выглядят несуществующими.
    find "$TREE" -name Kconfig -exec \
        grep -qE "^[[:space:]]*config ${c#CONFIG_}\$" {} + 2>/dev/null \
        || bogus="$bogus $c"
done
if [ -n "$bogus" ]; then
    warn "в config/linux.config есть символы, которых нет в дереве ядра:"
    printf '     %s\n' $bogus
    warn "merge_config их молча выкинет. Исправь или удали."
    die "сначала почини фрагмент — иначе соберём ядро без них"
fi
ok "все символы фрагмента существуют в дереве"

say "проверяю, что критичное реально включилось"
missing=
for opt in CONFIG_DRM_AMDGPU CONFIG_OVERLAY_FS CONFIG_EXT4_FS \
           CONFIG_VIRTIO_BLK CONFIG_EFI_STUB; do
    grep -q "^$opt=y" "$TREE/.config" || missing="$missing $opt"
done
[ -z "$missing" ] || die "в .config нет:$missing
  Символ не применился (имя неверное, либо зависимость не включена)."

# --- 4. сборка -------------------------------------------------------------
say "собираю bzImage, $JOBS потоков"
( cd "$TREE" && make -j"$JOBS" bzImage modules )

say "готово"
printf '\n  ядро:   %s\n' "$TREE/arch/x86/boot/bzImage"
printf '  модулей: %s\n\n' "$(find "$TREE" -name '*.ko' | wc -l | tr -d ' ')"
printf '  Дальше: ./tools/mklinux-pkg.sh — сделать из этого пакет bdd.\n\n'