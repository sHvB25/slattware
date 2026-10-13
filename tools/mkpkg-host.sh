#!/bin/sh
# mkpkg-host.sh — собрать пакет bdd из бинарей, уже готовых на хосте.
#
#   ./tools/mkpkg-host.sh <имя-пакета> <бинарь> [бинарь...]
#
# Копирует бинари в bin/, а ВСЕ их разделяемые библиотеки — в lib/,
# вместе с симлинками и целями.
#
# ЗАЧЕМ ЭТОТ СКРИПТ. Первая версия пакета util-linux собиралась
# перечислением библиотек руками, и libeconf.so.0 была забыта.
# Пакет ставился, bdd рапортовал «✓ установлен util-linux 1.0», и
# только запуск cfdisk в chroot показал:
#
#     Error loading shared library libeconf.so.0: No such file
#     Error relocating /usr/lib/libblkid.so.1: econf_getStringValue
#
# Три из четырёх библиотек на месте, ошибка внятная — но обнаружилась
# только запуском, а не установкой. Закрываем это замыканием по ldd,
# и повторяем до упора, пока новые библиотеки не перестанут появляться:
# libblkid тянет libeconf, а та — что-то ещё, и это «что-то ещё» без
# рекурсии не найти.
set -e
cd "$(dirname "$0")/.."

NAME=$1; shift
[ -n "$NAME" ] || { echo "usage: mkpkg-host.sh <имя> <бинарь>..." >&2; exit 1; }
[ $# -ge 1 ] || { echo "нужен хоть один бинарь" >&2; exit 1; }

SRC=share/repo/src/$NAME
rm -rf "$SRC"
mkdir -p "$SRC/bin" "$SRC/lib"

# --- бинари -----------------------------------------------------------------
for b in "$@"; do
    p=$(command -v "$b" 2>/dev/null) || { echo "нет на хосте: $b" >&2; exit 1; }
    cp -L "$p" "$SRC/bin/$b"          # -L: симлинки разворачиваем
    chmod 755 "$SRC/bin/$b"
done

# --- библиотеки: замыкание по ldd -----------------------------------------
# Работаем на КОПИЯХ в bin/, а не на оригиналах: ldd нужен на файлах,
# которые мы действительно кладём в пакет. Иначе замыкание посчитается
# по одному набору библиотек, а в пакет попадёт другой.
todo=$(ls "$SRC/bin")
seen=
while [ -n "$todo" ]; do
    added=
    for f in $todo; do
        # Регулярка берёт путь ЦЕЛИКОМ, до пробела.
        #
        # Раньше здесь было `/[^ ]+\.so\.[0-9]+`, и она обрезала
        # libdevmapper.so.1.02 до libdevmapper.so.1 — которого на хосте
        # нет, есть только .1.02. Дальше [ -e "$l" ] срабатывал, и
        # сборка падала с «библиотека пропала» на файле, который
        # прекрасно лежит на месте.
        #
        # Двухуровневые версии (libfoo.so.1.02, libbar.so.2.4) обычное
        # дело, и молча ломать их — значит ломать пакет целиком.
        for l in $(doas -n ldd "$SRC/bin/$f" 2>/dev/null \
                   | grep -oE '/[^ ]+\.so[^ ]*'); do
            case " $seen " in *" $l "*) continue ;; esac
            seen="$seen $l"
            # Динамический загрузчик исключаем ВСЕГДА.
            #
            # ld-musl-x86_64.so.1 — это не библиотека, а интерпретатор
            # из PT_INTERP, и он уже лежит в пакете musl. Если положить
            # второй экземпляр в /usr/lib, бинари будут грузить не тот, и
            # сломанная загрузка выглядит не как «пакет сломан», а как
            # «сломан kernel» — потому что ядро не может запустить /bin/sh.
            case "$l" in
                */ld-musl-*|*/ld-linux-*) continue ;;
            esac
            [ -e "$l" ] || { echo "библиотека пропала: $l" >&2; exit 1; }
            # Симлинк и его цель: обе нужны, иначе бинарь стартует
            # с «cannot open shared object file» при наличии .so.N.
            cp -P "$l" "$SRC/lib/" 2>/dev/null || cp "$l" "$SRC/lib/"
            real=$(readlink -f "$l")
            base=$(basename "$real")
            [ "$base" = "$(basename "$l")" ] || cp "$real" "$SRC/lib/"
            added="$added $(basename "$l")"
        done
    done
    [ -n "$added" ] || break
    todo=$added        # новые библиотеки сами могут что-то тянуть
done

printf '%s\n' "$NAME"
printf '  бинарей:    %s (%s)\n' "$(ls "$SRC/bin" | wc -l | tr -d ' ')" "$*"
printf '  библиотек:  %s (%s)\n' "$(ls "$SRC/lib" | wc -l | tr -d ' ')" \
       "$(ls "$SRC/lib" | tr '\n' ' ')"
echo
echo "  Дальше: добавь bdd.meta с depends: и install:, затем"
echo "          ./tools/mkrepo.sh $NAME"