#!/bin/sh
# Полный тест bdd в госте. Запускается через tools/vmsh.sh.

step() { echo; echo "### $* ###"; }

step "версия и помощь"
bdd --version
bdd help | head -30

step "репозитории и update"
bdd repos
bdd update

step "поиск"
bdd search hello
bdd search sud

step "install hello (собирается tcc прямо в госте)"
sudo bdd install hello

step "список установленных"
bdd list

step "файлы пакета"
bdd files hello
bdd owns /usr/local/bin/hello
bdd owns usr/local/bin/hello

step "info"
bdd info hello
bdd info sud

step "зависимости"
bdd deps hello
bdd deps sud

step "программа работает"
hello

step "счётчик пакетов в myfetch"
myfetch | tail -5

step "собираем свой пакет прямо в гостю"
mkdir -p /home/slat/Projects/greeter
cd /home/slat/Projects/greeter
cat > greeter.c <<'EOF'
#include <stdio.h>
int main(void) { printf("привет из пакета greeter\n"); return 0; }
EOF
cat > bdd.meta <<'EOF'
version: 0.3
description: Пакет, собранный прямо в гостю
maintainer: slat
depends:
build: mkdir -p bin && tcc -o bin/greeter greeter.c
EOF
bdd create greeter /home/slat/Projects/greeter

step "ставлю собранный пакет напрямую из файла"
sudo bdd install /home/slat/Projects/greeter/greeter-0.3.bddpkg

step "greeter работает?"
greeter 2>&1 || echo "НЕ РАБОТАЕТ"

step "bdd list / files / owns"
bdd list
bdd files greeter
bdd owns /usr/local/bin/greeter

step "remove greeter и hello"
sudo bdd remove greeter hello
bdd list
ls /usr/local/bin/

step "ошибки"
sudo bdd install nosuchpkg; echo "код=$?"
sudo bdd remove hello; echo "код=$?"
bdd; echo "код без команды=$?"

step "upgrade"
pwd
sudo bdd upgrade; echo "код=$?"
bdd list
echo "ФИНИШ ТЕСТА"