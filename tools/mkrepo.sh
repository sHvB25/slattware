#!/bin/sh
# mkrepo.sh — собрать локальный репозиторий bdd на хосте.
#
#   ./tools/mkrepo.sh            пересобрать все пакеты и индекс
#   ./tools/mksrepo.sh hello     собрать только пакет hello
#   ./tools/mkrepo.sh clean      удалить пакеты и индекс
#
# Раскладка исходника пакета (важно, она же используется в bdd create):
#
#   bdd.meta          метаданные; необязательная строка build: — команда сборки
#   bin/*             → /usr/local/bin/
#   lib/*             → /usr/local/lib/<имя>/
#   share/*           → /usr/local/share/<имя>/
#   doc/*             → /usr/share/doc/<имя>/
#   *.c *.h *.mk …    → /usr/share/doc/<имя>/   (исходники кладём в доки)
#   прочее на верхнем уровне → ошибка, чтобы ничего не потерялось молча
#
# Сборка идёт tcc из rootfs: хостовый tcc сломан (нет libtcc1.a).
set -e
cd "$(dirname "$0")/.."
REPO=$PWD/share/repo
TCC="$PWD/rootfs/usr/bin/tcc -B $PWD/rootfs/usr/lib/tcc"


mkdir -p "$REPO"

meta_get() {
    [ -f "$1" ] || return 1
    sed -n "s/^$2:[[:space:]]*//p" "$1" | head -n1
}

# Строки ключа install: — пары "каталог-источник  абсолютный-путь".
# Нужны, чтобы пакет мог положить файлы ТАМ, где их ищет загрузчик:
# библиотеки обязаны лежать в /usr/lib, а bdd по умолчанию кладёт
# lib/ в /usr/local/lib/<имя>/, куда ld-musl не заглядывает. Без этого
# в репозиторий нельзя положить ни одну готовую программу (cfdisk и
# подобные требуют libblkid, libsmartcols, libfdisk и т.п.).
meta_install_lines() {
    [ -f "$1" ] || return 1
    sed -n '/^install:[[:space:]]*$/,/^[^[:space:]#]/{
        s/^[[:space:]]*//
        /^[a-z_][a-z_0-9]*:/d
        p
    }' "$1"
}

# Разложить содержимое исходника пакета в $1/data.
# Исходник раскладывается заранее во временную папку, чтобы сборка
# не оставляла мусор в репозитории.
layout() {
    _src=$1        # подготовленная копия исходника
    _data=$2       # куда складывать data/
    _name=$3
    SKIPED=

    mkdir -p "$_data"

    if [ -d "$_src/bin" ]; then
        mkdir -p "$_data/usr/local/bin"
        copy_tree "$_src/bin" "$_data/usr/local/bin"
    fi
    # Каталоги, перекрытые install:, обычным циклом НЕ раскладываем:
    # иначе lib/ уедет и в /usr/local/lib/<имя>/, и по назначенному
    # абсолютному пути — в системе окажется две копии, и непонятно,
    # какую возьмёт загрузчик.
    for pair in ${INSTALL_PAIRS:-}; do
        _p=${pair%%|*}
        SKIPED="$SKIPED $_p"
        # Если указано "lib/x86_64-linux-gnu", обычный расклад всё равно
        # тронет каталог "lib" — а он уже весь перекрыт. Поэтому снимаем
        # и первый компонент пути.
        case "$_p" in
            */*) SKIPED="$SKIPED ${_p%%/*}" ;;
        esac
    done

    for sub in lib share doc; do
        [ -d "$_src/$sub" ] || continue
        case " ${SKIPED} " in
            *" $sub "*) continue ;;
        esac
        case $sub in
            lib)   dst="$_data/usr/local/lib/$_name" ;;
            share) dst="$_data/usr/local/share/$_name" ;;
            doc)   dst="$_data/usr/share/doc/$_name" ;;
        esac
        mkdir -p "$dst"
        copy_tree "$_src/$sub" "$dst"
    done

    # install: — раскладка по абсолютным путям, минуя обычные bin/lib/.
    # Вызывающий передаёт список пар через переменную INSTALL_PAIRS.
    for _pair in ${INSTALL_PAIRS:-}; do
        _from=${_pair%%|*}
        _to=${_pair#*|}
        [ "$_from" = "$_to" ] && continue
        [ -d "$_src/$_from" ] || {
            printf 'install: нет каталога %s в исходнике\n' "$_from" >&2
            return 1
        }
        case "$_to" in
            /*) : ;;
            *)  printf 'install: путь "%s" не абсолютный\n' "$_to" >&2
                return 1 ;;
        esac
        mkdir -p "$_data$_to"
        copy_tree "$_src/$_from" "$_data$_to"
    done

    # одиночные файлы верхнего уровня.
    #   без расширения → скрипты, их хотим в /usr/local/bin
    #   исходники и сборочные файлы → в /usr/share/doc/<имя>/
    mkdir -p "$_data/usr/share/doc/$_name" "$_data/usr/local/bin"
    for f in "$_src"/*; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        case "$b" in
            bdd.meta) continue ;;
            Makefile|makefile|GNUmakefile|*.mk|CMakeLists.txt|meson.build) ;;
            *.c|*.h|*.S|*.ld|*.pc|*.in|*.txt|*.md|LICENSE|COPYING|README*|INSTALL) ;;
            *.*) printf 'непонятный файл в пакете: %s\n' "$b" >&2
                printf '  положи его в bin/, lib/, share/, doc/ или убери\n' >&2
                return 1 ;;
            *)  cp -p "$f" "$_data/usr/local/bin/$b"
                chmod 755 "$_data/usr/local/bin/$b"
                continue ;;
        esac
        cp -p "$f" "$_data/usr/share/doc/$_name/$b"
    done
}

copy_tree() {
    (cd "$1" && tar -cf - .) | (cd "$2" && tar -xf -)
}

# Собрать один пакет из исходника в .bddpkg
build_one() {
    src=$1
    name=$(basename "$src")
    ver=0.1
    desc="пакет $name"
    maint="aetherria"
    deps=""
    build=""
    setuid=""
    essential=""
    if [ -f "$src/bdd.meta" ]; then
        v=$(meta_get "$src/bdd.meta" version);    [ -n "$v" ]  && ver=$v
        d=$(meta_get "$src/bdd.meta" description); [ -n "$d" ]  && desc=$d
        m=$(meta_get "$src/bdd.meta" maintainer);  [ -n "$m" ]  && maint=$m
        dp=$(meta_get "$src/bdd.meta" depends);    [ -n "$dp" ] && deps=$dp
        b=$(meta_get "$src/bdd.meta" build);       [ -n "$b" ]  && build=$b
        s=$(meta_get "$src/bdd.meta" setuid);      [ -n "$s" ]  && setuid=$s
        e=$(meta_get "$src/bdd.meta" essential);   [ -n "$e" ]  && essential=$e

        # Ключи, которые мы не читаем, — это опечатка, а не «лишнее».
        # Молча выкидывать нельзя: так потерялось бы, например,
        # essential, и пакет удалили бы вместе с системой.
        for k in $(sed -n 's/^\([a-z_][a-z_0-9]*\):.*/\1/p' "$src/bdd.meta" \
                   | sort -u); do
            case "$k" in
                version|description|maintainer|depends|build|setuid|essential|install) ;;
                *) printf 'в %s/bdd.meta незнакомый ключ: %s:\n' \
                       "$name" "$k" >&2 ;;
            esac
        done
    fi

    out=$REPO/$name-$ver.bddpkg
    work=$(mktemp -d)
    src_copy=$work/src
    stage=$work/stage
    mkdir -p "$src_copy" "$stage"
    copy_tree "$src" "$src_copy"
    rm -f "$src_copy/bdd.meta"

    # сборка
    if [ -n "$build" ]; then
        printf '  сборка %s: %s\n' "$name" "$build"
        ( cd "$src_copy" && TCC="$TCC" \
            sh -c "$build" ) || { rm -rf "$work"; printf 'сборка %s не удалась\n' "$name" >&2; return 1; }
        chmod -R u+rwX,go+rX "$src_copy"
        find "$src_copy" -type f -name '*' -exec sh -c '
            for f do case "$f" in */bin/*) chmod 755 "$f";; esac; done' sh {} +
    fi

    # Пары install: в виде "откуда|куда". Разбираем позиционными
    # параметрами, а не `while read` по heredoc: вложенный heredoc внутри
    # функции так и не отдавал строки, INSTALL_PAIRS выходил пустым, а
    # пакет молча уезжал по старой раскладке.
    INSTALL_PAIRS=
    set -- $(meta_install_lines "$src/bdd.meta" 2>/dev/null)
    while [ $# -ge 2 ]; do
        INSTALL_PAIRS="$INSTALL_PAIRS $1|$2"
        shift 2
    done

    layout "$src_copy" "$stage/data" "$name"

    # installed_size — в байтах, сумма по всем файлам пакета
    isz=$(find "$stage/data" -type f -exec wc -c {} + 2>/dev/null \
          | awk 'END{print $1+0}')
    nfiles=$(find "$stage/data" \( -type f -o -type l \) | wc -l | tr -d ' ')
    {
        printf 'name: %s\n'         "$name"
        printf 'version: %s\n'      "$ver"
        printf 'description: %s\n'  "$desc"
        printf 'maintainer: %s\n'   "$maint"
        printf 'depends:%s\n'     "${deps:+ $deps}"
        printf 'installed_size: %s\n' "$isz"
        printf 'file_count: %s\n'   "$nfiles"
        [ -n "$setuid" ] && printf 'setuid: %s\n' "$setuid"
        # essential: yes — bdd remove не удалит такой пакет без --force
        [ -n "$essential" ] && printf 'essential: %s\n' "$essential"
        printf 'arch: x86_64\n'
        printf 'built_at: %s\n'     "$(date '+%F %T')"
    } > "$stage/meta"

    rm -f "$out"
    (cd "$stage" && tar -czf "$out" meta data)
    rm -rf "$work"
    printf '  собрал %s-%s.bddpkg (%s файлов, %s байт)\n' \
        "$name" "$ver" "$nfiles" "$isz"
}

# Пересобрать индекс bdd.db
build_index() {
    idx=$REPO/bdd.db
    : > "$idx.tmp"
    for pkg in "$REPO"/*.bddpkg; do
        [ -f "$pkg" ] || continue
        f=$(basename "$pkg")
        sha=$(sha256sum "$pkg" | cut -d' ' -f1)
        sz=$(wc -c < "$pkg" | tr -d ' ')
        # метаданные достаём из архива
        meta=$(mktemp)
        tar -xzOf "$pkg" meta 2>/dev/null > "$meta" || { rm -f "$meta"; continue; }
        name=$(meta_get "$meta" name)
        [ -n "$name" ] || name=${f%%-*}
        ver=$(meta_get "$meta" version);   ver=${ver:-0.1}
        desc=$(meta_get "$meta" description)
        rm -f "$meta"
        printf '%s|%s|%s|%s|%s|%s\n' \
            "$name" "$ver" "$sha" "$sz" "$f" "$desc" >> "$idx.tmp"
    done
    sort -t'|' -k1,1 "$idx.tmp" -o "$idx.tmp"
    mv -f "$idx.tmp" "$idx"
    n=$(wc -l < "$idx")
    printf 'индекс: %s (%s пакетов)\n' "$idx" "$n"
}

case "${1:-all}" in
    all)
        for d in "$REPO"/src/*/; do
            [ -d "$d" ] || continue
            build_one "$d"
        done
        build_index
        ;;
    clean)
        rm -f "$REPO"/*.bddpkg "$REPO"/bdd.db
        printf 'репозиторий очищен\n'
        ;;
    *)
        if [ ! -d "$REPO/src/$1" ]; then
            echo "нет исходника share/repo/src/$1" >&2
            exit 1
        fi
        build_one "$REPO/src/$1"
        build_index
        ;;
esac