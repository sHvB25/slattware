#!/bin/sh
# vmsh.sh — запустить slattware в QEMU и выполнить скрипт внутри гостя.
#
#   ./tools/vmsh.sh                    без скрипта: просто ждём ввода
#   ./tools/vmsh.sh -s test.sh         выполнить скрипт в госте
#   ./tools/vmsh.sh -s test.sh -v      то же + показать лог ядра целиком
#   ./tools/vmsh.sh -s test.sh -t 120  сколько ждать завершения скрипта, сек
#
# Скрипт кладётся в 9p-шару и запускается от пользователя сессии.
#
# Вывод скрипта пишется не в консоль, а в файл на шаре: stdout QEMU
# уходит в лог файлом и блокируется буфером, поэтому «последние строки
# не доехали» получалось именно из-за этого. Маркер завершения тоже
# ставится после того, как скрипт отработал, — так ничего не теряется.

set -e
cd "$(dirname "$0")/.."

KERNEL=kernel/7.2.8/arch/x86/boot/bzImage
INITRD=initramfs.cpio.gz
SCRIPT=
VERBOSE=0
BOOT_WAIT=${VMSH_BOOT_WAIT:-12}
TIMEOUT=120

# Ядро гостя — SMP PREEMPT_DYNAMIC, clocksource tsc. Под TCG у него
# через несколько секунд после старта перестаёт срабатывать nanosleep:
# гостевой sleep 1 зависает намертво (проверено — цикл без fork
# отрабатывает 60 итераций, 30 fork+exec проходят, на 4-м sleep
# всё встаёт). Пока это не выяснено, число процессоров и
# дополнительные флаги QEMU можно переопределить извне:
#   VMSH_SMP=1 ./tools/vmsh.sh -s test.sh
#   VMSH_EXTRA='-rtc base=localtime,clock=host' ./tools/vmsh.sh -s test.sh
SMP=${VMSH_SMP:-2}
EXTRA=${VMSH_EXTRA:-}
# nohz=off обязателен. Ядро собрано с CONFIG_NO_HZ_IDLE=y, и под TCG
# гость, ушедший в idle в ожидании ответа 9p, уже не просыпается: оба
# vCPU стоят в hlt, QEMU потребляет 0% CPU, запись в шару не
# возвращается. Наблюдалось и без всяких «таймерных» симптомов — просто
# зависание на любой записи в /shared. С nohz=off те же тесты проходят.
# Переопределить: VMSH_APPEND_EXTRA='...' ./tools/vmsh.sh -s test.sh
APPEND_EXTRA=${VMSH_APPEND_EXTRA:-nohz=off}

while [ $# -gt 0 ]; do
    case "$1" in
        -s) SCRIPT=$2; shift 2 ;;
        -v) VERBOSE=1; shift ;;
        -t) TIMEOUT=$2; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) shift ;;
    esac
done

[ -f "$KERNEL" ] || { echo "нет ядра: $KERNEL" >&2; exit 1; }

# Каталог обмена с гостем — внутри 9p-шары, его видит гость.
#
# Имя с ПИДом — не излишняя осторожность. Общий каталог означал, что
# cleanup одного прогона удаляет каталог УЖЕ ИДУЩЕГО прогона: гость
# получал «nonexistent directory» на редиректе, скрипт не запускался,
# харнесс молчал до таймаута. Два прогона не должны мешать друг другу.
STAGE=$PWD/share/.vmsh.$$
STAGE_GUEST=/shared/.vmsh.$$

# Лог и FIFO — на хосте, вне шары: гостю они не нужны, а убрать их
# случайно легко.
RUNDIR=${TMPDIR:-/tmp}/vmsh.$$
LOG=$RUNDIR/console.log
DONE=$STAGE/done

DONE_GUEST=$STAGE_GUEST/done

# Каталоги прошлых прогонов, чей процесс давно умер, убираем — иначе
# они копятся в шаре. Живые PID не трогаем: это может быть параллельный
# прогон.
for old in "$PWD"/share/.vmsh.*; do
    [ -d "$old" ] || continue
    oldpid=${old##*.}
    case "$oldpid" in
        ''|*[!0-9]*) rm -rf "$old" ;;
        *) kill -0 "$oldpid" 2>/dev/null || rm -rf "$old" ;;
    esac
done

rm -rf "$RUNDIR"
mkdir -p "$STAGE" "$RUNDIR"

# Маркер завершения пишем В КОНЕЦ САМОГО СКРИПТА, а не отдельной командой
# с хоста. Отдельная команда уходила в терминал, пока скрипт ещё работал,
# и её проглатывал `read` в диалоге `bdd remove` («Удалить всё равно?»):
# маркер не появлялся, харнесс молча ждал таймаута, а QEMU оставался
# висеть и портить disk.img.
# Маркеры нужны, чтобы отделить вывод скрипта от шума загрузки и приглашения
# шелла. Раньше вывод складывался в out.txt на 9p-шаре — и на этом зависал
# сам гость, см. комментарий про nohz=off в параметрах ядра.
MARK_BEGIN='<<<vmsh:begin>>>'
MARK_END='<<<vmsh:end>>>'

{
    echo '#!/bin/sh'
    echo "trap 'echo vmsh-done > $DONE_GUEST 2>/dev/null' EXIT INT TERM"
    printf 'echo "%s"\n' "$MARK_BEGIN"
    # Перевод строки в конце — обязателен: файл скрипта может не кончиться
    # им, и тогда метка конца склеится с последней строкой вывода, а наш
    # разбор (awk по маркерам) проглотит её целиком вместе с результатом.
    [ -n "$SCRIPT" ] && [ -f "$SCRIPT" ] && { cat "$SCRIPT"; echo; }
    printf 'echo "%s"\n' "$MARK_END"
} > "$STAGE/cmd.sh"
chmod +x "$STAGE/cmd.sh" 2>/dev/null || :

FIFO=$RUNDIR/in
mkfifo "$FIFO"

# Время и часовой пояс хоста: в гостевой ФС нет ни RTC, ни zoneinfo.
./tools/hostinfo.sh || :

# Уборка выполняется только в главном шелле. Фоновый под-шелл feed()
# наследует EXIT-ловушку, и без этой проверки он сносил каталог сам.
VMSH_MAIN=1
cleanup() {
    [ "${VMSH_MAIN:-0}" = 1 ] || return 0
    VMSH_MAIN=0
    rm -f "$FIFO"
    [ -n "${QMPID:-}" ] && kill "$QMPID" 2>/dev/null || :
    rm -rf "$STAGE"
}
trap cleanup EXIT INT TERM

# Подавать ввод в QEMU, пока гость не отметит конец скрипта.
# Всё печатаем в дескриптор 3 — это FIFO, из которого читает QEMU.
feed() {
    VMSH_MAIN=0
    exec 3>"$FIFO"
    sleep "$BOOT_WAIT"
    printf '\n' >&3              # автологин: пустая строка = войти
    sleep 4
    # Вывод скрипта НЕ перенаправляем в файл на шаре. Он уходит прямо
    # на терминал гостя, то есть в $LOG, — оттуда его и забираем.
    # Так не зависит от записи в 9p, которая при nohz не выключенной
    # висела насмерть (см. параметры ядра выше).
    printf 'sh %s/cmd.sh\n' "$STAGE_GUEST" >&3
    waited=0
    while [ ! -f "$DONE" ]; do
        sleep 1
        waited=$((waited + 1))
        [ "$waited" -ge "$TIMEOUT" ] && break
    done
    if [ ! -f "$DONE" ]; then
        printf '(скрипт не отметил завершение за %s с — смотри лог)\n' \
            "$TIMEOUT" >&2
    fi
    sleep 1
    printf 'sudo poweroff -f\n' >&3
    sleep 4
    # Гость выключается не мгновенно: sync + размонтирование + poweroff
    # занимают несколько секунд. Поэтому проверяем дважды, через паузы.
    # Именно последовательные sleep, а НЕ цикл опроса — см. комментарий
    # у wait в конце файла: с опросом гость зависает.
    killed=no
    for pause in 4 6 10; do
        sleep "$pause"
        if ! kill -0 "$QMPID" 2>/dev/null; then
            killed=no
            break
        fi
        killed=yes
    done
    if [ "$killed" = yes ]; then
        # QEMU продолжает писать в disk.img, и следующий запуск находит
        # «нечитаемый образ» — это уже стоило одного потерянного состояния.
        printf '(гость не выключился — убиваю qemu)\n' >&2
        kill -TERM "$QMPID" 2>/dev/null || :
        sleep 2
        kill -KILL "$QMPID" 2>/dev/null || :
    fi
    exec 3>&-
}
qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "console=ttyS0 loglevel=4 $APPEND_EXTRA" \
    -m 1024 -smp "$SMP" \
    -drive file=disk.img,if=virtio,format=raw \
    -drive file=data.img,if=virtio,format=raw \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -fsdev local,id=fs0,path="$PWD/share",security_model=none \
    -device virtio-9p-pci,fsdev=fs0,mount_tag=host \
    -qmp "unix:$RUNDIR/qmp,server=on,wait=off" \
    -nographic -no-reboot $EXTRA < "$FIFO" > "$LOG" 2>&1 &
QMPID=$!

# feed запускаем ПОСЛЕ QEMU. Раньше он стартовал раньше, и переменная
# QMPID в нём была пустой: под-шелл получает копию переменных на момент
# fork, а присваивание происходит позже. Из-за этого `kill -0 "$QMPID"`
# проверял пустую строку, всегда считал QEMU мёртвым и печатал ложное
# «гость не выключился».
#
# Само по себе ожидание на FIFO никого не блокирует: QEMU открывает его
# на чтение сразу при старте, а feed первым делом всё равно спит BOOT_WAIT.
feed &
FEEDER=$!

# VMSH_TEE=1 — дублировать консоль гостя на терминал хоста в реальном
# времени. Теперь это чисто host-side: в гостя никакого tee не уходит,
# поэтому на скорость и на 9p не влияет.
if [ "${VMSH_TEE:-0}" = 1 ]; then
    tail -f "$LOG" >&2 2>/dev/null &
    TAILPID=$!
fi

# Ждём выключения гостя обычным wait — без опроса kill -0 по секундам.
#
# Это не стилистика. С секундным опросом (и с отдельным сторожем, который
# просыпается по таймеру) гость примерно через 3.5 секунды после старта
# скрипта перестаёт выполняться вообще: QEMU показывает 0% CPU, оба vCPU
# стоят в hlt, консоль молчит наглухо. Воспроизводится стабильно и только
# через vmsh — тот же QEMU с тем же скриптом, запущенный напрямую, отрабатывает
# целиком (цикл в 100000 итераций проходит за 45 секунд uptime). Ни 9p, ни
# sleep, ни параметры ядра, ни число процессоров к этому не относятся.
# Механизм не разобран, поэтому здесь просто ничего не опрашиваем: убить
# зависший QEMU поручено feed(), у которой цикла опроса нет.
wait "$QMPID" 2>/dev/null || :
kill "$WATCHDOG" 2>/dev/null || :
wait "$FEEDER" 2>/dev/null || :
[ -n "${TAILPID:-}" ] && kill "$TAILPID" 2>/dev/null || :

# Вывод скрипта вытаскиваем из консоли между маркерами. Если скрипт не
# дошёл до конца, маркера конца не будет — покажем всё до конца лога,
# иначе вместо диагностики будет пустота.
clean_log() {
    sed 's/\r//g' "$1" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\[6n//g'
}

if [ "$VERBOSE" = 1 ]; then
    cat "$LOG"
else
    clean_log "$LOG" > "$RUNDIR/clean.log"
    if ! awk -v b="$MARK_BEGIN" -v e="$MARK_END" \
            'index($0,b){f=1;next} index($0,e){f=0} f' "$RUNDIR/clean.log" \
            > "$RUNDIR/script.log"; then
        :
    fi
    if [ -s "$RUNDIR/script.log" ]; then
        cat "$RUNDIR/script.log"
    else
        printf '### вывод скрипта не найден, показываю консоль ###\n'
        awk -v re="cmd\\.sh" '$0 ~ re {f=1;next} f' "$RUNDIR/clean.log"
    fi
fi

# Лог полезен для разбора, если что-то пошло не так. VMSH_KEEP=1 — не удалять.
if [ "${VMSH_KEEP:-0}" = 1 ]; then
    echo "(лог: $LOG)"
else
    rm -rf "$RUNDIR"
fi
exit 0