#!/bin/sh
# guest-install-test.sh — поставить slattware на образ диска и загрузить.
#
#   ./tools/guest-install-test.sh          поставить и загрузить
#   ./tools/guest-install-test.sh install  только поставить, без загрузки
#   ./tools/guest-install-test.sh boot     только загрузить уже поставленное
#
# Это НЕ установщик. Тут ровно тот путь, который проходит человек на
# Live CD руками, только автоматизированный:
#
#   lsblk
#   cfdisk /dev/vda           ← тут человек нажимает кнопки, мы ставим sfdisk
#   mkfs.ext4 /dev/vda1
#   mount /dev/vda1 /mnt
#   slattware-pacstrap /mnt
#   slattware-chroot /mnt
#       bdd install linux grub
#       slattware-grub-install /dev/vda
#   exit
#   umount -R /mnt
#   reboot
#
# Смысл: каждый шаг тут взят из настоящего инструмента, а не написан
# заново. Если установка ломается, видно где — и правка идёт в тот
# инструмент, которым пользуется человек, а не сюда.
set -e
cd "$(dirname "$0")/.."
ROOT=$PWD

LIVE_BIN=/usr/local/bin
IMG=/tmp/opencode/install-test.img
MNT=/tmp/opencode/instmnt
DISK=/dev/vda
WHAT=${1:-all}

as_root() { doas -n sh -c "$*"; }
say() { printf '==> %s\n' "$*"; }
die() { printf '!!! %s\n' "$*" >&2; exit 1; }

# Убрать развёрнутое живое окружение, даже если тест упал.
# Иначе в /usr/local/bin остаются наши скрипты и симлинк на bdd,
# и следующий запуск делает вид, что окружение уже готово, хотя
# оно осталось от прошлого прогона с другим состоянием репозитория.
cleanup() {
    # Порядок размонтирования важен: /home лежит ВНУТРИ $MNT, и обычный
    # `umount $MNT` отказывается (busy), если вложенное не снято.
    #
    # На этом тест и ломался, причём молча: уборка оставляла $MNT
    # смонтированным, следующий запуск доходил до `rm -rf $MNT` и
    # умирал на EBUSY без единого слова — выглядело как «тест завис».
    # Последние два запуска подряд так и выглядели.
    #
    # umount -R снимает всё рекурсивно, -l отвязывает даже если
    # кто-то держит файл открытым. Порядок: -R сначала, -l если не
    # вышло.
    as_root "rm -f $LIVE_BIN/slattware-pacstrap $LIVE_BIN/slattware-chroot \
             $LIVE_BIN/slattware-grub-install; \
             [ -L $LIVE_BIN/bdd ] && rm -f $LIVE_BIN/bdd; \
             umount -R $MNT 2>/dev/null || umount -R -l $MNT 2>/dev/null; \
             losetup -D 2>/dev/null" || :
}
trap cleanup EXIT INT TERM

# --- образ диска -----------------------------------------------------------
# 1 ГБ. Меньше нельзя: корень с системой и загрузчиком занимает ~700 МБ,
# и при 512 МБ QEMU начнёт падать на загрузке — а падение будет выглядеть
# как ошибка ядра, а не как нехватка места.
do_install() {
    say "образ 1 ГБ"
    rm -f "$IMG"
    dd if=/dev/zero of="$IMG" bs=1M count=1024 status=none
    chmod 666 "$IMG"

    say "разметка (её бы делал cfdisk руками)"
    # p1 — корень, p2 — отдельный /home.
    #
    # Именованная форма start=/size=/type=, а не позиционная
    # «,600M,8300». Позиционная на этой версии sfdisk не работает:
    #     t.img1: Failed to add #1 partition: Invalid argument
    # при том, что метка создаётся успешно, и выглядит это как «образ
    # битый», а не как «синтаксис не тот». Проверено на 64 МБ.
    #
    # Метка dos, а не gpt: QEMU грузит этот образ как BIOS, а на GPT для
    # BIOS-загрузчика нужен отдельный раздел bios_grub (ef02) — без него
    # grub-install отказывается работать. Тот случай закрыт в
    # slattware-grub-install отдельной внятной ошибкой, а не тестом.
    # Настоящий ноутбук — EFI и GPT, его разметка делается руками.
    printf 'label: dos\nstart=1MiB, size=600MiB, type=linux\nstart=601MiB, size=399MiB, type=linux\n' \
        | as_root "sfdisk --force $IMG >/dev/null"
    as_root "losetup -fP --show $IMG >/tmp/opencode/.loop"
    LOOP=$(cat /tmp/opencode/.loop)
    # Считаем разделы по строкам sfdisk -l, а не по числу строк с
    # заголовком: заголовок таблицы занимает две строки плюс пустая.
    _parts=$(as_root "sfdisk -l $IMG" | grep -cE '^'"$IMG"'[0-9]+')
    say "диск $LOOP: разделов $_parts"

    say "ФС ext4 на разделе корня"
    as_root "mkfs.ext4 -q -F -L slattware-root ${LOOP}p1"
    as_root "mkfs.ext4 -q -F -L slattware-home ${LOOP}p2"

    say "монтирую корень в $MNT"
    # Каталог мог остаться смонтированным с прошлого прогона. rm -rf по
    # смонтированному каталогу падает с EBUSY, и без проверки скрипт
    # умирает молча. Проверяем ЗАРАНЕЕ и говорим, что не так.
    if mountpoint -q "$MNT" 2>/dev/null; then
        as_root "umount -R $MNT" || as_root "umount -R -l $MNT" \
            || die "не могу размонтировать $MNT — прогони doas umount -R $MNT вручную"
    fi
    rm -rf "$MNT" || die "не удалось очистить $MNT"
    mkdir -p "$MNT"
    as_root "mount ${LOOP}p1 $MNT" || die "не смонтировал ${LOOP}p1"

say "разворачиваю живое окружение"
    # pacstrap ищет инструменты по АБСОЛЮТНОМУ пути /usr/local/bin/,
    # потому что на Live CD они там и лежат. На хосте исходники лежат в
    # rootfs/usr/local/bin/, и pacstrap их не видел — а копировал бы
    # пустоту, и slattware-grub-install не доехал бы до цели.
    #
    # Поэтому на время теста инструменты кладутся настоящим путём и
    # убираются в trap. Это ровно то, что делает ISO.
    LIVE_BIN=/usr/local/bin
    # /usr/local/bin на хосте принадлежит root, поэтому копируем через
    # doas — иначе cp молча не срабатывает (мы глотали ошибку через || :),
    # и первый же вызов даёт «No such file or directory».
    for _t in "$ROOT"/rootfs/usr/local/bin/slattware-*; do
        as_root "cp -a $_t $LIVE_BIN/" || :
    done
    as_root "ln -sf $ROOT/share/repo/src/bdd/bdd $LIVE_BIN/bdd" || :
    _missing=
    for _t in slattware-pacstrap slattware-chroot slattware-grub-install bdd; do
        [ -e "$LIVE_BIN/$_t" ] || _missing="$_missing $_t"
    done
    [ -z "$_missing" ] || die "не разложилось живое окружение, нет:$_missing"

    say "slattware-pacstrap $MNT"
    # Репозиторий для ПЕРВОЙ установки берётся у live-окружения, как и
    # положено: bdd здесь ещё не в chroot и видит файловую систему хоста.
    #
    # Порядок важен: репозиторий нельзя класть в цель ДО pacstrap —
    # тот требует пустой корень и отказывает на «внутри: opt». А нужен
    # он потом, когда chroot видит только свою файловую систему и
    # file:///home/... хоста в ней не существует.
    #
    # На stdin «y»: pacstrap спрашивает подтверждение и по замыслу НЕ
    # работает молча. На пустом stdin read получает EOF, скрипт выходит,
    # ничего не сделав, — выглядит как зависание.
    printf 'y\n' | as_root "NO_COLOR=1 PATH=$LIVE_BIN:\$PATH \
             REPO_URL=file://$ROOT/share/repo \
             sh $LIVE_BIN/slattware-pacstrap \
             -b 'busybox musl dinit bdd sud myfetch util-linux e2fsprogs' \
             $MNT"

    say "монтирую /home: ${LOOP}p2 → $MNT/home"
    # ПОСЛЕ pacstrap, не до. Порядок вынужденный: pacstrap требует
    # пустой корень и отказывает на «внутри: home». Так делает и Arch —
    # /home монтируют уже после pacstrap.
    #
    # Нужно, чтобы slattware-grub-install увидел раздел и написал строку
    # в fstab. Он запускается с --root снаружи и смотрит /proc/mounts
    # ХОСТА, поэтому ищет путь $MNT/home, а не /home.
    as_root "mkdir -p $MNT/home && mount ${LOOP}p2 $MNT/home" \
        || die "не смонтировал ${LOOP}p2 в /home"

    say "/etc системы: rootfs/etc (как на Live CD)"
    # pacstrap копирует /etc ЖИВОЙ системы. На настоящем Live CD живая
    # система собрана из rootfs/, то есть /etc там — это rootfs/etc, с
    # нашими сервисами dinit и нашими скриптами mountall.sh, net.sh.
    #
    # На хосте /etc — это Alpine. Отсюда каскад:
    #     dinit: boot: could not find service description
    #     dinit: share: execution failed: No such file or directory
    #     getty: can't execute '/etc/autologin.sh'
    # dinit запускался, но не находил ни сервисов, ни скриптов, которые
    # те сервисы запускают.
    #
    # Подменяем /etc цели на rootfs/etc — ровно то, что видит человек,
    # загрузившийся с Live CD. fstab и bdd/repos восстанавливаем после:
    # они описывают конкретную машину, и pacstrap их намеренно не тащит.
    as_root "cp -a $ROOT/rootfs/etc/. $MNT/etc/"
    as_root "echo 'file:///opt/repo' > $MNT/etc/bdd/repos"

    say "репозиторий внутрь цели: $MNT/opt/repo"
    # Ровно как на Live CD: у живой системы репозиторий по /opt/repo.
    as_root "mkdir -p $MNT/opt/repo && cp $ROOT/share/repo/*.bddpkg \
             $ROOT/share/repo/bdd.db $MNT/opt/repo/"
    as_root "echo 'file:///opt/repo' > $MNT/etc/bdd/repos"

    say "slattware-chroot: bdd install linux grub"
    # БЕЗ -n: chroot подмонтирует /dev, /proc, /sys.
    #
    # grub-install обязан видеть блочные устройства — иначе он не может
    # записать MBR, и скрипт падает на «нет такого блочного устройства».
    # Это же и делает arch-chroot: без смонтированного /dev установщик
    # загрузчика внутри chroot неработоспособен.
    as_root "$LIVE_BIN/slattware-chroot $MNT \
             /usr/local/bin/bdd install linux grub"

    say "slattware-grub-install --root $MNT ${LOOP}p1"
    # Запуск СНАРУЖИ chroot, с --root. Внутри grub-install не может
    # сопоставить устройство и встраивает в core.img неверный префикс:
    # grub-install рапортует «Installation finished. No error reported.»,
    # а машина не грузится с «file `/vmlinuz' not found».
    #
    # SLAT_EFI=0: хост загружен через EFI, образ для QEMU — BIOS.
    # С переменной окружения, поэтому здесь обычный запуск, не chroot.
    as_root "SLAT_EFI=0 SLAT_EXTRA_CONSOLE='console=ttyS0,115200n8' \
             $LIVE_BIN/slattware-grub-install --root $MNT ${LOOP}p1"

    say "размонтирую"
    # Именно -R: внутри $MNT смонтирован /home, и обычный umount $MNT
    # отказывается с «target is busy», оставляя образ в смонтированном
    # состоянии — и следующий запуск падает на rm -rf с EBUSY.
    as_root "umount -R $MNT" || as_root "umount -R -l $MNT" || :
    as_root "losetup -d $LOOP" || :
    say "поставлено: $IMG"
}

do_boot() {
    [ -f "$IMG" ] || die "нет образа $IMG — сначала install"
    say "загружаю поставленное"
    exec timeout "${T:-90}" qemu-system-x86_64 \
        -drive "file=$IMG,if=virtio,format=raw" \
        -m 2048 -smp 2 -nographic -no-reboot
}

case "$WHAT" in
    install) do_install ;;
    boot)    do_boot ;;
    all)     do_install; do_boot ;;
    *)       echo "usage: $0 [all|install|boot]" >&2; exit 1 ;;
esac