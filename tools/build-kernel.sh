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
# ПОРЯДОК АРГУМЕНТОВ merge_config.sh:
#
#     merge_config.sh [флаги] БАЗА [ФРАГМЕНТ...]
#
#     INITFILE=$1 ; shift ; MERGE_LIST=$*
#
# ПЕРВЫЙ позиционный аргумент — это БАЗА, из которой берутся исходные
# значения; всё остальное — фрагменты, накладываемые поверх.
#
# На этом я ошибался ДВАЖДЫ, в обе стороны, и обе ошибки молчаливые:
#
#   * `merge_config.sh "$FRAG" .config` — фрагмент становился БАЗОЙ,
#     а .config уходил в список фрагментов. Итог: 111 строк вместо 5500,
#     и в них ровно наш фрагмент. PCI, DRM и всё, чего во фрагменте нет,
#     исчезли, и olddefconfig их уже не вернул.
#   * `merge_config.sh "$FRAG"` — фрагмент опять стал базой, список
#     фрагментов пуст, .config перезаписан целиком.
#
# Симптом в обоих случаях одинаковый и обманчивый: .config валидный, и
# AMDGPU в нём есть — «фрагмент применился». Но PCI и DRM отсутствуют,
# потому что базой был фрагмент, а не defconfig. Проверка шага 3 идёт
# по символам самого фрагмента и потому к потере базы слепа.
#
# yes "" нужен, потому что скрипт задаёт вопросы про новые символы
# и без ответа зависает на stdin.
say "накладываю config/linux.config"
( cd "$TREE" && \
  yes "" | ./scripts/kconfig/merge_config.sh -m -O . .config "$FRAG" \
) >/dev/null 2>&1 || true

# merge_config правит значения в .config, но не разрешает зависимости.
# olddefconfig делает это: для новых символов берёт значение по
# умолчанию. oldconfig вместо него задаёт вопросы и требует интерактива.
say "olddefconfig"
( cd "$TREE" && yes "" | make olddefconfig ) >/dev/null

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
    # grep -r, а НЕ find -exec grep {} +.
    #
    # Причина: grep -q завершается на первом совпадении и закрывает stdin.
    # find с -exec {} + скармливает файлы пачкой через pipe, и на закрытом
    # stdin find умирает от SIGPIPE — вся конструкция возвращает
    # не-nonzero СЛУЧАЙНО. На относительном пути попадало, на абсолютном
    # нет, и выглядело так, будто символов нет вообще. grep -r читает до
    # конца и гонок не создаёт.
    #
    # (menu)?config, а не просто config. Многие символы объявляются как
    # menuconfig — NLS, INPUT_KEYBOARD, ATA, CRYPTO, CGROUPS — и проверка
    # без menu выдавала их за выдуманные.
    #
    # Отступ обязателен: config внутри menu идёт с ведущим пробелом
    # (drivers/ata/Kconfig — «config ATA_PIIX»), а config верхнего
    # уровня — без него.
    grep -rqE "^[[:space:]]*(menu)?config ${c#CONFIG_}\$" --include=Kconfig "$TREE" \
        2>/dev/null || bogus="$bogus $c"
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

# Целостность БАЗЫ. Отдельная от проверки выше проверка, потому что
# жадный merge_config способен тихо съесть defconfig целиком, и проверка
# фрагмента этого не заметит: фрагмент в таком случае становится базой
# сам, и все его символы на месте.
#
# Символы намеренно выбраны те, которых НЕТ в config/linux.config —
# иначе проверка таялась бы на общих с фрагментом именах и повторила
# бы ту же слепоту. PCI и DRM обязаны прийти из x86_64_defconfig:
# без них не будет ни AMDGPU, ни чего-либо ещё с шиной PCIe, но AMDGPU
# в .config при этом есть, и всё выглядит рабочим.
say "проверяю, что база defconfig не потеряна"
base_missing=
for opt in CONFIG_PCI CONFIG_DRM CONFIG_MMU CONFIG_BINFMT_ELF CONFIG_SMP; do
    grep -qE "^$opt=(y|m)$" "$TREE/.config" || base_missing="$base_missing $opt"
done
[ -z "$base_missing" ] || die "в .config нет базовых символов:$base_missing
  merge_config съел defconfig. Проверь порядок аргументов:
  первый позиционный — БАЗА, дальше фрагменты."

# Размер как грубая страховка: defconfig даёт ~5500 строк, фрагмент
# поверх того же — ~5500. Сотня строк означает, что остался один фрагмент.
_cfg_lines=$(wc -l < "$TREE/.config" | tr -d ' ')
[ "$_cfg_lines" -gt 3000 ] || die "в .config всего $_cfg_lines строк — это не конфиг ядра.
  Похоже, записался только фрагмент, а не конфиг целиком."
ok "база на месте, $_cfg_lines строк в .config"

# --- 4. сборка -------------------------------------------------------------
say "собираю bzImage, $JOBS потоков"
( cd "$TREE" && make -j"$JOBS" bzImage modules )

say "готово"
printf '\n  ядро:   %s\n' "$TREE/arch/x86/boot/bzImage"
printf '  модулей: %s\n\n' "$(find "$TREE" -name '*.ko' | wc -l | tr -d ' ')"
printf '  Дальше: ./tools/mklinux-pkg.sh — сделать из этого пакет bdd.\n\n'