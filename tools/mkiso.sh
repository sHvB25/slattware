#!/bin/sh
# mkiso.sh — собрать загрузочный ISO slattware.
#
# Это Live CD: то, с чего начинается ручная установка. Пользователь
# грузится с ISO, попадает в shell с готовым bdd, размечает диск сам,
# зовёт slattware-pacstrap, заходит через slattware-chroot.
#
# Главное решение по составу: Live-среда — это ТОТ ЖЕ корень, который
# даёт pacstrap. Никакого отдельного «live-профиля», который потом
# расходился бы с установленной системой. Разница одна: утилиты для
# разметки (util-linux, e2fsprogs) есть в live и не нужны в системе.
# Расхождение в том, что не установлено, гарантировано отсутствием
# этих пакетов в bdd — а не тем, что кто-то не забыл их вычеркнуть.
#
# Собирается так, как собирается настоящая система: bdd --root в
# каталог. Тот же код, что и у пользователя.

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VER=$(cat "$ROOT/config/KERNEL_VERSION" 2>/dev/null || echo 7.2.8)
OUT="$ROOT/build-iso"
ISO="$ROOT/slattware-live-$VER-x86_64.iso"

C_R=; C_G=; C_Y=; C_C=; C_RST=
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
    C_R=$(printf '\033[31m'); C_G=$(printf '\033[32m'); C_Y=$(printf '\033[33m')
    C_C=$(printf '\033[36m'); C_RST=$(printf '\033[0m')
fi
say()  { printf '%s==>%s %s\n' "$C_C" "$C_RST" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_G" "$C_RST" "$*"; }
warn() { printf '%s !%s %s\n'  "$C_Y" "$C_RST" "$*" >&2; }
die()  { printf '%smkiso:%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" = 0 ] || die "нужны права root: sudo ./tools/mkiso.sh"

# --------------------------------------------------------------- проверки
have xorriso || die "нет xorriso: apk add xorriso (или apt install xorriso)
  Без него ISO не собрать — это обязательный инструмент, а не опция."

# grub-mkrescue для создания EFI-образа зовёт mformat/mmd/mcopy из
# mtools. Без них он падает с «mformat invocation failed» — и это
# сообщение ни о чём не говорит, поэтому проверяем явно.
for t in mformat mmd; do
    have "$t" || die "нет $t: apk add mtools
  grub-mkrescue требует mtools, чтобы положить загрузчик на EFI-образ."
done

BZ="$ROOT/kernel/$VER/arch/x86/boot/bzImage"
[ -f "$BZ" ] || die "нет собранного ядра: $BZ
  Собери: ./tools/build-kernel.sh"

# Живая среда должна уметь работать на чужой машине, а значит —
# быть в состоянии boot-в-qemu с ядром, которое мы и кладём в ISO.
# Проверяем ровно то, на что упадём при загрузке.
grep -q '^CONFIG_AMDGPU=y\|^CONFIG_DRM_AMDGPU=y' "$ROOT/kernel/$VER/.config" 2>/dev/null \
    || warn "в ядре нет DRM_AMDGPU — Live CD загрузится, но без графики.
       На чужом ноутбуке будет чёрный экран. Пересобери с config/linux.config"

REPO="$ROOT/share/repo"

# Пакеты live-окружения.
#
# Первая группа — то, без чего ручная установка невозможна.
# Базовые пакеты Live CD.
#
# util-linux и e2fsprogs обязательны: без них с Live CD нельзя
# разметить диск и создать ФС, то есть Live CD не годится для
# установки. Это не «полезно иметь», а условие работоспособности.
LIVE_BASE="busybox musl dinit bdd sud myfetch util-linux e2fsprogs"
# Вторая — утилиты разметки и ФС. Их в системе нет, они нужны только
# пока ты на Live CD.
LIVE_TOOLS="util-linux e2fsprogs"

say "чищу $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"

# ------------------------------------------------------------- ядро + init
say "initramfs"
cp "$BZ" "$OUT/bzImage"

# ДВА архива, и разница между ними — суть всей затеи.
#
#   initramfs.cpio.gz   маленький. Только первый процесс: init,
#                       busybox, dev/console, точки монтирования.
#                       Работает одинаково в двух случаях: и при
#                       обычной загрузке с диска, и с Live CD.
#   live-root.cpio.gz   сама живая система: busybox, musl, dinit,
#                       bdd, sud, myfetch, pacstrap, chroot, репозиторий.
#
# Раньше был один архив, и Live CD отдавался в switch_root корень
# initramfs — то есть каталог из двух файлов. Там не было ни dinit,
# ни bdd, ни pacstrap, то есть ровно того, ради чего Live CD и нужен.
#
# Теперь init в режиме Live CD монтирует live-root как /newroot и
# передаёт ему управление. При обычной загрузке — так же, но корнем
# будет раздел диска.
# Права выставляем ЯВНО, а не полагаемся на то, что лежит на диске.
# init обязан быть исполняемым: без бита u+x ядро даёт
# «Failed to execute /init (error -13)» и паникует, а ISO при этом
# собирается без единого предупреждения.
#
# Как это произошло: init когда-то правили через sed -i, и перезапись
# сбросила режим в 644. Сборка проходила, init не запускался, и по
# логу это выглядело как «init молчит» — причина была не в коде
# скрипта, а в одном байте прав.
chmod 755 "$ROOT/initramfs/init" "$ROOT/initramfs/bin/busybox"

( cd "$ROOT/initramfs" && find . | sort | cpio -o -H newc 2>/dev/null ) \
    | gzip -9 > "$OUT/initramfs.cpio.gz"

# Проверяем то, без чего init не запустится вообще. Обе проверки
# стоили нескольких часов отладки, поэтому они в скрипте.
#
# Читаем через zcat: cpio сам gzip не понимает и на сжатом файле
# сыплет «Malformed number» — проверка выглядела бы как «всё потеряно».
listing=$(zcat "$OUT/initramfs.cpio.gz" | cpio -tv 2>/dev/null)

if ! printf '%s' "$listing" | grep -q 'dev/console'; then
    die "в initramfs нет dev/console — ядро не сможет открыть консоль.
  Узел создаётся mknod в initramfs/dev/. Если его нет, пересоздай:
      cd initramfs/dev && mknod console c 5 1 && chmod 600 console"
fi

# В листинге cpio -tv путь печатается БЕЗ ведущей ./ (просто «init»),
# хотя find его отдаёт как ./init. Поэтому регулярка допускает оба вида.
if ! printf '%s' "$listing" | grep -qE '^-rwxr-xr-x.*[[:space:]]\.?/?init$'; then
    die "init в архиве не исполняемый — ядро упадёт с error -13 (EACCES).
  Проверь права: ls -l initramfs/init, должно быть rwxr-xr-x.
  Сборщик выставляет их сам, но если init правили в обход него —
  chmod 755 initramfs/init"
fi
ok "initramfs $(du -h "$OUT/initramfs.cpio.gz" | cut -f1): dev/console и mode init в порядке"

# ------------------------------------------------------- корень live-среды
# Вот здесь главное: тот же pacstrap, тот же bdd, тот же базовый набор.
# Live-среда не собирается копированием файлов — она наполняется
# пакетами, как настоящая система. Иначе она рано или поздно разойдётся
# с тем, что ставит pacstrap.
say "корень live-среды"
bddroot="$OUT/root"
mkdir -p "$bddroot"

# bdd ищет пакет по имени через индекс репозитория. Индекс лежит в
# bdd.db, а он указывает на файлы по имени — и bdd.db в репозитории
# описывает пакеты по их ПУТИ, а не по имени-и-версии, поэтому поиск
# по имени из ISO не сработает: там нет /var/lib/bdd/index.
#
# Поэтому live-среда ставится по явным путям к .bddpkg — bdd так умеет
# ("принимает и путь к .bddpkg") и это не зависит от индекса.
# Это же снимает зависимость от сети: с ISO ставится офлайн.
pkgs=
for p in $LIVE_BASE; do
    f=$(ls "$REPO/$p"-*.bddpkg 2>/dev/null | head -1)
    [ -n "$f" ] || die "нет пакета $p в $REPO (собери: ./tools/mkrepo.sh all)"
    pkgs="$pkgs $f"
done

"$REPO/src/bdd/bdd" --root "$bddroot" install $pkgs

warn "утилиты разметки ($LIVE_TOOLS) не поставлены: их ещё нет в репозитории.
     Без них на Live CD не будет cfdisk/mkfs.ext4 — а это ровно то,
     ради чего Live CD и нужен. Сделай пакеты util-linux и e2fsprogs,
     либо пока размечай диск руками через busybox fdisk/mkfs."

# /etc живой системы: скелет для установки. slattware-pacstrap потом
# скопирует его в целевую систему, поэтому он должен быть тут полным.
cp -a "$ROOT/rootfs/etc" "$bddroot/etc"

# fstab для Live CD — НЕ копия системного.
#
# Системный fstab описывает /home как отдельный раздел с меткой mydata.
# На Live CD раздела нет: корень целиком в tmpfs, и /home уже создан.
# Если оставить строку с LABEL=mydata, mountall (сервис etc) упадёт,
# и в логе будет «Service etc terminated with exit code 1».
#
# Виртуальные ФС тоже монтировать не нужно: initramfs уже смонтировал
# proc, sys, dev, run и tmp до switch_root. Повторный mount -a поверх
# них — лишнее и лишняя точка отказа.
cat > "$bddroot/etc/fstab" <<'EOF'
# fstab для Live CD.
#
# Пусто не случайно: initramfs смонтировал /proc, /sys, /dev, /run и
# /tmp ДО switch_root, а корень лежит в tmpfs. Монтировать тут нечего.
#
# Строка с меткой mydata из системного fstab тут не работает: раздела
# /home на Live CD нет, и mountall упадёт с exit code 1.
EOF

# /init — симлинк на /bin/dinit. Его ищет initramfs при switch_root,
# поэтому без него живую систему не запустить.
#
# Раньше его создавал slattware-pacstrap, а этот скрипт наполняет корень
# напрямую через bdd и про pacstrap не знает. На выходе было 6 записей
# и ни одного /init: init доходил до проверки и останавливался.
ln -sfn /bin/dinit "$bddroot/init"

# Каталоги- точки монтирования. bdd раскладывает только файлы пакетов,
# а каркас системы — не его дело; init потом требует эти каталоги
# готовыми, иначе mount падает с ENOENT.
for d in dev proc sys run tmp boot root srv mnt media; do
    mkdir -p "$bddroot/$d"
done

# Домашний каталог пользователя. Без него login не пускает в сессию:
# «login: can't change directory to '/home/slat'».
#
# /home на настоящей установке — отдельный раздел, и pacstrap кладёт
# каталоги сам. На Live CD раздела нет, поэтому создаём минимальный
# HOME: системе он не нужен, нужен чтобы зайти.
mkdir -p "$bddroot/home/slat"
cp -a "$ROOT/rootfs/etc/skel/." "$bddroot/home/slat/" 2>/dev/null || :
ok "/init, точки монтирования и /home/slat на месте"

# Скрипты установки — то, ради чего всё затевалось.
mkdir -p "$bddroot/usr/local/bin"
cp "$ROOT/rootfs/usr/local/bin/slattware-pacstrap" "$bddroot/usr/local/bin/"
cp "$ROOT/rootfs/usr/local/bin/slattware-chroot"    "$bddroot/usr/local/bin/"
chmod 755 "$bddroot/usr/local/bin/"slattware-*
ok "pacstrap и chroot в образе"

# Репозиторий — целиком. Чтобы на Live CD можно было ставить пакеты
# без сети и без 9p-шары: mount/cp в busybox это умеет.
say "репозиторий в образ"
mkdir -p "$bddroot/opt/repo"
cp "$REPO"/*.bddpkg "$bddroot/opt/repo/" 2>/dev/null || :
cp "$REPO/bdd.db" "$bddroot/opt/repo/" 2>/dev/null || :
cat > "$bddroot/etc/bdd/repos" <<EOF
# Репозиторий лежит на самом Live CD: /opt/repo
# Работает без сети. Чтобы смотреть в интернет, добавь https://строку.
file:///opt/repo
EOF
ok "репозиторий: $(ls "$bddroot/opt/repo" | wc -l | tr -d ' ') файлов"

# Живая система как отдельный архив: его init монтирует как /newroot
# в режиме Live CD и передаёт ему /init.
#
# Узлы устройств (/dev/console) внутри тут не нужны и невозможны:
# devtmpfs монтируется уже поверх, а узлы в архиве были бы вторым
# источником правды.
#
# Каталоги ВКЛЮЧЕНЫ обязательно. При списке только -type f -o -type l
# пустые каталоги в архив не попадают: cpio создаёт каталог лишь когда
# внутри него что-то лежит. Так терялся /home/slat — он пуст, потому
# что /etc/skel тоже пуст — и login писал «can't change directory».
( cd "$bddroot" && find . -type d -o -type f -o -type l | sort \
    | cpio -o -H newc 2>/dev/null ) | gzip -1 > "$OUT/live-root.cpio.gz"
ok "live-root $(du -h "$OUT/live-root.cpio.gz" | cut -f1)"

# ----------------------------------------------------------- загрузчик EFI
say "загрузчик"
# Путь важен: grub-mkrescue кладёт свой префикс boot/, а свой grub.cfg
# GRUB ищет по /boot/grub/grub.cfg или /grub.cfg. Если положить его в
# $OUT/grub/grub/grub.cfg, он окажется на ISO как /grub/grub/grub.cfg,
# GRUB его не найдёт — и молча упадёт в приглашение, показав только
#Welcome to GRUB вместо меню. Именно так и случилось.
mkdir -p "$OUT/boot/grub"
# В grub 2.14 ключа append больше нет — параметры ядра идут прямо в
# строке linux. Старый синтаксис из примеров в сети падает с
# «can't find command `append'».
#
# Про консоли: ядро открывает ПЕРВУЮ указанную. При `-nographic` в QEMU
# графической консоли tty0 нет, и если она стоит первой, ядро падает с
# «unable to open an initial console». Поэтому ttyS0 идёт первым —
# он есть и в QEMU, и на живой машине через перенаправление, а tty0
# вторым для графической машины.
cat > "$OUT/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0

# root=/dev/ram0 — указание ядру, какой initrd считать корнем. В
# режиме Live CD init перехватывает управление и монтирует
# /liveroot.cpio.gz сам, поэтому ядру этот параметр не нужен для
# работы, но он снимает сообщение «VFS: Unable to mount root fs».
# Метка slattware-live идёт ПОСЛЕ init=/init, то есть аргументом самому
# init, а не параметром ядра. init читает свою команду строку через "$@",
# потому что /proc на момент его старта ещё не смонтирован и
# /proc/cmdline недоступен. root=/dev/ram0 убирает сообщение ядра
# «VFS: Unable to mount root fs» — init всё равно перехватывает управление.
menuentry "slattware (live)" {
    linux  /bzImage console=ttyS0 console=tty0 root=/dev/ram0 init=/init slattware-live quiet
    initrd /initramfs.cpio.gz
}

menuentry "slattware (live, отладка)" {
    linux  /bzImage console=ttyS0 console=tty0 root=/dev/ram0 init=/init slattware-live loglevel=7
    initrd /initramfs.cpio.gz
}
EOF
ok "boot/grub/grub.cfg"

# Живая система едет ВНУТРИ initramfs: initramfs/init находит её по
# пути /liveroot.cpio.gz. Отдельным initrd её класть нельзя — ядро
# берёт один, и второй просто проигнорирует.
cp "$OUT/live-root.cpio.gz" "$ROOT/initramfs/liveroot.cpio.gz"
chmod 755 "$ROOT/initramfs/init" "$ROOT/initramfs/bin/busybox"
( cd "$ROOT/initramfs" && find . | sort | cpio -o -H newc 2>/dev/null ) \
    | gzip -1 > "$OUT/initramfs.cpio.gz"
ok "initramfs с живой системой внутри: $(du -h "$OUT/initramfs.cpio.gz" | cut -f1)"
rm -f "$ROOT/initramfs/liveroot.cpio.gz"

# ---------------------------------------------------------- сам ISO
say "собираю ISO"
# Ошибку grub-mkrescue не подавляем: она молчаливый-не-видимый убийца
# всей сборки. Пусть вывод уйдёт в лог, а в сообщение попадёт хвост.
if ! grubmk_log=$(grub-mkrescue -o "$ISO" "$OUT" 2>&1); then
    printf '%s\n' "$grubmk_log" > "$ROOT/build-iso/grub-mkrescue.log"
    die "grub-mkrescue упал. Лог: build-iso/grub-mkrescue.log
  Последние строки:"
    printf '%s\n' "$grubmk_log" | tail -12 >&2
fi

printf '\n%sISO готов%s\n\n' "$C_G" "$C_RST"
printf '  %s\n' "$ISO"
printf '  размер: %s\n\n' "$(du -h "$ISO" | cut -f1)"

cat <<EOF
Проверить, не выходя из slattware:

  qemu-system-x86_64 -cdrom $ISO -m 2048 \\
    -drive file=disk.img,if=virtio,format=raw -nographic

В QEMU корнем станет /dev/vda — initramfs найдёт его сам, без вопросов.
На настоящем железе спросит раздел руками: это и есть конструктор.
EOF