#!/bin/busybox sh
# Установка компилятора tcc внутрь mydistro.
# Все пути абсолютные — можно запускать из любой папки.
set -e

PROJ=/home/aetherria/Downloads/mydistro
TCC_SRC="$PROJ/src/tcc"
ROOTFS="$PROJ/rootfs"
TCC_URL=https://download.savannah.gnu.org/releases/tinycc/tcc-0.9.27.tar.bz2

echo "=== 1/6  Собираю tcc из исходников ==="
# чистим возможный мусор от прошлых попыток
rm -rf "$TCC_SRC" "$ROOTFS/lib/tcc"
mkdir -p "$TCC_SRC"
cd "$TCC_SRC"
curl -sLO "$TCC_URL"
tar -xjf tcc-0.9.27.tar.bz2 --strip-components=1
./configure
# CONFIG_musl=yes обязателен: без него собирается bcheck.o, который есть только в glibc
make CONFIG_musl=yes
test -x "$TCC_SRC/tcc" || { echo "ОШИБКА: tcc не собрался"; exit 1; }
test -f "$TCC_SRC/libtcc1.a" || { echo "ОШИБКА: нет libtcc1.a"; exit 1; }

echo "=== 2/6  Компилятор и его библиотека ==="
mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/usr/lib/tcc/include" \
         "$ROOTFS/usr/local/lib" "$ROOTFS/tmp" "$ROOTFS/usr/include" "$ROOTFS/lib"
cp "$TCC_SRC/tcc"         "$ROOTFS/usr/bin/tcc"
cp "$TCC_SRC/libtcc1.a"   "$ROOTFS/usr/lib/tcc/"
cp "$TCC_SRC"/include/*.h "$ROOTFS/usr/lib/tcc/include/"
chmod 755 "$ROOTFS/usr/bin/tcc"

echo "=== 3/6  musl: загрузчик, libc и стартовые объекты ==="
# в musl загрузчик и libc — это один и тот же файл
cp /lib/ld-musl-x86_64.so.1  "$ROOTFS/lib/"
# ВАЖНО: tcc ищет crt-объекты и libc.so в /usr/lib, а не в /usr/lib/tcc.
# Проверить можно командой: tcc -print-search-dirs
cp /usr/lib/crt1.o "$ROOTFS/usr/lib/"
cp /usr/lib/crti.o "$ROOTFS/usr/lib/"
cp /usr/lib/crtn.o "$ROOTFS/usr/lib/"
ln -sf /lib/ld-musl-x86_64.so.1 "$ROOTFS/usr/lib/libc.so"
# libtcc1.a tcc ищет по адресу /usr/local/lib/tcc — делаем симлинк
ln -sfn /usr/lib/tcc "$ROOTFS/usr/local/lib/tcc"

echo "=== 4/6  Заголовки musl ==="
# из /usr/include копируем только musl, а не всё подряд (там 125 МБ чужих заголовков)
cd /usr/include
cp *.h "$ROOTFS/usr/include/"
for d in bits sys arpa netinet net rpc; do
    if [ -d "$d" ]; then
        cp -r "$d" "$ROOTFS/usr/include/"
    fi
done

echo "=== 5/6  Патч заголовка: __builtin_va_list ==="
# в musl: typedef __builtin_va_list va_list;
# __builtin_va_list — встроенный тип gcc, tcc такого не знает.
# Подменяем на настоящую структуру va_list для x86_64.
sed -i 's|typedef __builtin_va_list va_list;|typedef struct { unsigned gp_offset, fp_offset; void *overflow_arg_area, *reg_save_area; } __builtin_va_list[1];|' \
    "$ROOTFS/usr/include/bits/alltypes.h"
grep -q gp_offset "$ROOTFS/usr/include/bits/alltypes.h" || {
    echo "ОШИБКА: патч не применился, строка не найдена"; exit 1; }

echo "=== 6/6  Проверяю результат ==="
ls -la "$ROOTFS/usr/bin/tcc"
ls -la "$ROOTFS/usr/lib/tcc/"
ls -la "$ROOTFS/usr/lib/" | grep -E "crt|libc"
ls -la "$ROOTFS/lib/ld-musl-x86_64.so.1"
echo "--- размер тулчейна:"
du -sh "$ROOTFS/usr"

echo
echo "Готово. Дальше: ./build.sh && ./run.sh"
echo "В системе: /usr/bin/tcc hello.c -o hello"
