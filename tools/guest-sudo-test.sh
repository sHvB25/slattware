#!/bin/sh
# Тест прав: sudo, установка и удаление пакетов, поведение при ошибках.
step() { echo; echo "### $* ###"; }

step "sudo -l (список разрешённых)"
sudo -l
sudo -n sudo -l 2>&1 | head -3

step "sudo с неизвестной опцией"
sudo -u root bdd list; echo "код=$?"

step "установка пакета от root (индекс скачается сам)"
sudo bdd install hello
hello
ls -la /usr/local/bin/hello
ls -la /usr/share/doc/hello/

step "владелец файлов пакета — root?"
ls -la /usr/local/bin/ | sed 's/^/  /'

step "setuid-пакет ставится только от root"
bdd install sud; echo "код без sudo=$?"
sudo bdd install sud
ls -la /usr/local/bin/sud
sudo -l >/dev/null && echo "sudo пережил установку пакета: ок"

step "bdd ставит сам себя (rename поверх работающего скрипта)"
sudo bdd install bdd; echo "код=$?"
bdd --version
sudo -n sync && echo "bdd после самопереустановки работает: ок"

step "служебный пакет удалять нельзя"
sudo bdd remove bdd; echo "код=$?"
bdd --version >/dev/null && echo "bdd на месте: ок"

step "установка пакета из локального файла"
cd /tmp && sudo bdd install /shared/repo/hello-0.1.bddpkg; echo "код=$?"

step "удаление"
bdd remove hello; echo "код без sudo=$?"
sudo bdd remove hello myfetch
bdd list
ls /usr/local/bin/

step "sudo пережил всё вышеперечисленное"
sudo -n sync && echo "sync через sud: ок"
sudo -l | head -2

step "upgrade"
sudo bdd upgrade
bdd list

step "bdd clean и итог"
sudo bdd clean
bdd list