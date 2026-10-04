#!/bin/sh
echo "### время ###"
date
date +%Z
echo "TZ=[$TZ]"
cat /etc/tz 2>&1
echo "### /shared ###"
ls -la /shared/.hosttime /shared/.hosttz 2>&1
cat /shared/.hosttz 2>&1
echo "### home ###"
ls -la /home/ /home/slat/ 2>&1
touch /home/slat/Проверка.txt && echo "запись в домашний каталог: ок"
rm -f /home/slat/Проверка.txt
echo "### окружение ###"
echo "PATH=$PATH"
id
echo "### сеть ###"
# Сеть проверяем явно и по пунктам. Она уже молча ломалась дважды:
# сервис net был type = internal (команда не запускалась вовсе), а потом
# не добавлялся маршрут по умолчанию из-за того, что busybox игнорирует
# фильтр `default` в `ip route show`. Оба раза dinit показывал STARTED.
# Здесь проверяем то, что реально нужно для репозитория в облаке:
# адрес, маршрут по умолчанию, DNS и выход наружу.
ip addr show eth0 2>&1 | grep -E 'inet ' || echo "ПЛОХО: нет адреса на eth0"
ip route 2>&1 | grep -q '^default ' && echo "маршрут по умолчанию: есть" \
    || echo "ПЛОХО: нет маршрута по умолчанию"
echo "DNS: $(cat /etc/resolv.conf 2>&1 | tr '\n' ' ')"
busybox nslookup example.com >/dev/null 2>&1 \
    && echo "резолв имён: ок" || echo "ПЛОХО: DNS не отвечает"
# Выход наружу проверяем с двумя попытками: через slirp ответ иногда
# приходит медленнее, чем таймаут. Это справочная проверка, а не условие
# прохождения теста — репозиторий может лежать и на локальной сети.
net_ok=no
for _ in 1 2; do
    busybox wget -q -O /dev/null -T 10 http://example.com/ 2>/dev/null \
        && { net_ok=yes; break; }
done
[ "$net_ok" = yes ] \
    && echo "выход в интернет: ок" \
    || echo "выход в интернет: недоступен (справочно, тест не заваливается)"
echo "### tcc ###"
which tcc; tcc -v 2>&1 | head -2