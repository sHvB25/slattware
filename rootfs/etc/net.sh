#!/bin/sh
# /etc/net.sh — настройка сети. Запускается сервисом net в dinit.
#
# В QEMU с -netdev user шлюз всегда 10.0.2.2, DNS 10.0.2.3,
# а выданный адрес обычно 10.0.2.15. Поэтому настраиваем статически,
# но если адрес уже есть — не трогаем.

BB=/bin/busybox

case "$1" in
stop)
    $BB ip link set eth0 down 2>/dev/null
    exit 0
    ;;
esac

# Поднимаем интерфейс
$BB ip link set lo up 2>/dev/null
$BB ip link set eth0 up 2>/dev/null

# Проверяем, есть ли уже адрес
if ! $BB ip addr show eth0 2>/dev/null | grep -q 'inet '; then
    $BB ip addr add 10.0.2.15/24 dev eth0 2>/dev/null
fi

# Маршрут по умолчанию.
#
# Проверяем именно строку, начинающуюся с «default», а НЕ `ip route show
# default`: в этой сборке busybox фильтр `default` игнорирует и печатает
# ВСЕ маршруты, поэтому проверка всегда считала, что маршрут уже есть, и
# `route add` не выполнялся. Итог: адрес 10.0.2.15 был, а шлюза не было —
# внутри своей подсети сеть работала, наружу (в облако) уйти нельзя.
if ! $BB ip route show 2>/dev/null | grep -q '^default '; then
    $BB ip route add default via 10.0.2.2 dev eth0 2>/dev/null \
        || echo "warn: не удалось добавить маршрут по умолчанию через 10.0.2.2" >&2
fi

# DNS
if [ ! -s /etc/resolv.conf ] || ! grep -q nameserver /etc/resolv.conf 2>/dev/null; then
    printf 'nameserver 10.0.2.3\n' > /etc/resolv.conf
fi

# Проверка связи — одна попытка, не блокируем загрузку
sleep 1
if $BB ping -c1 -W1 10.0.2.2 >/dev/null 2>&1; then
    echo "сеть: 10.0.2.15/24, шлюз 10.0.2.2, DNS 10.0.2.3"
else
    echo "сеть: интерфейс поднят, но шлюз не отвечает" >&2
fi

exit 0
