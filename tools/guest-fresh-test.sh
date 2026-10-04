#!/bin/sh
# Тест «с нуля»: система собрана --clean, ставим пакеты с нуля.
step() { echo; echo "### $* ###"; }

step "версия системы"
cat /etc/os-release
bdd --version
myfetch --version 2>/dev/null || true

step "документация"
ls /usr/share/doc/slattware/
head -3 /usr/share/doc/slattware/cheatsheet

step "состояние пакетов (должно быть пусто)"
bdd list
ls -la /var/lib/bdd/db | head

step "ставлю пакет из репозитория"
bdd update; echo "код без sudo=$?"
bdd search hello
bdd info hello | head -3
bdd repos
sudo bdd update
sudo bdd install hello
hello

step "ставлю все остальные пакеты по очереди"
sudo bdd install myfetch
sudo bdd install sud
bdd list

step "setuid на sud после установки пакета"
ls -la /usr/local/bin/sud
sudo -n sync && echo "sudo работает: ок"

step "upgrade"
sudo bdd upgrade

step "чистка кэша"
bdd clean

step "удаляю всё обратно"
sudo bdd remove hello myfetch
bdd list
ls /usr/local/bin/

step "служебный пакет удалить нельзя"
sudo bdd remove sud; echo "код=$?"
sudo bdd remove bdd; echo "код=$?"
sudo -n sync && echo "sudo на месте: ок"

step "пользовательские файлы пережили пересборку"
ls -la ~/ /home/
echo "--- тест.txt ---"; cat /home/тест.txt
echo "--- файл.txt ---"; cat /home/файл.txt
echo "--- Projects ---"; ls -la ~/Projects/