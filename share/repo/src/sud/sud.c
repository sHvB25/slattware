/* sud.c — маленький помощник для повышения прав.
 *
 * Замысел: в slattware нет паролей и полноценного sudo, но есть
 * несколько операций, которые вроде бы должны требовать root
 * (выключение, перезагрузка, установка пакетов от root).
 *
 * sud — бинарь с битом setuid root. Он НЕ даёт произвольный root:
 * разрешён только белый список команд, каждая из которых и так
 * безопасна сама по себе.
 *
 * Собирается динамически: tcc -static даёт бинарь, который падает
 * с segfault, а musl-загрузчик в системе есть.
 *     tcc -B <tcc-lib> -o sud sud.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>

/* Команды, которые можно запускать от root. */
static const char *allowed[] = {
    "poweroff",
    "reboot",
    "bdd",
    "dinitctl",
    "mount",
    "umount",
    "hostname",
    "myfetch",
    "sync",
    /* chmod нужен, чтобы починить бит setuid самому (см. подсказку
     * в сообщении об ошибке). Остального намеренно нет: root-шелл
     * в системе, где паролей нет, — это уже не помощь, а дыра. */
    "chmod",
    NULL
};

static int is_allowed(const char *cmd)
{
    for (int i = 0; allowed[i]; i++)
        if (!strcmp(cmd, allowed[i]))
            return 1;
    return 0;
}

static void die_msg(const char *msg)
{
    fprintf(stderr, "sud: %s\n", msg);
    exit(1);
}

/* die("строка") — tcc не понимает die как макрос с выражением,
 * поэтому отдельная функция с постоянным текстом. */
#define die(msg) die_msg(msg)

static void print_list(FILE *out)
{
    fprintf(out, "sud: команды, которые можно запустить от root:\n");
    for (int i = 0; allowed[i]; i++)
        fprintf(out, "  %s\n", allowed[i]);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr,
                "usage: sud <команда> [аргументы]\n"
                "       sud -l          список разрешённых команд\n"
                "разрешено: ");
        for (int i = 0; allowed[i]; i++)
            fprintf(stderr, "%s ", allowed[i]);
        fprintf(stderr, "\n");
        return 1;
    }

    /* Список и справка: работают и без setuid, и без root —
     * их и должен уметь показать обычный пользователь. */
    if (!strcmp(argv[1], "-l") || !strcmp(argv[1], "--list")) {
        print_list(stdout);
        return 0;
    }
    if (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help")) {
        printf("usage: sud <команда> [аргументы]\n"
               "       sud -l      список разрешённых команд\n"
               "\n"
               "sud не даёт произвольный root: только белый список команд.\n");
        return 0;
    }

    /* Отладочный режим: SUD_DEBUG=1 показывает, что было бы сделано. */
    if (getenv("SUD_DEBUG")) {
        printf("sud: выполнил бы от uid=%d: %s\n", (int)getuid(), argv[1]);
        for (int i = 2; i < argc; i++)
            printf("  %s\n", argv[i]);
        return 0;
    }

    /* Три разные причины отказа — говорим разными словами, иначе
     * непонятно, чинить бит, владельца или права. */
    if (geteuid() != 0) {
        struct stat st;
        if (stat(argv[0], &st) == 0) {
            if (st.st_uid != 0)
                fprintf(stderr,
                    "sud: файл принадлежит uid=%d, а не root\n"
                    "sud: поставь пакет через 'sudo bdd install ...'\n",
                    (int)st.st_uid);
            else
                fprintf(stderr,
                    "sud: бит setuid снят (ls -l %s)\n"
                    "sud: восстановить: sudo chmod 4755 %s\n",
                    argv[0], argv[0]);
        } else {
            fprintf(stderr, "sud: не могу stat %s\n", argv[0]);
        }
        return 1;
    }

    const char *cmd = argv[1];

    /* Отрезаем путь, чтобы sudo /bin/sh не прошёл проверку имени. */
    const char *base = strrchr(cmd, '/');
    base = base ? base + 1 : cmd;

    if (!is_allowed(base)) {
        fprintf(stderr, "sud: команда '%s' не в списке разрешённых\n", base);
        fprintf(stderr, "sud: разрешено: ");
        for (int i = 0; allowed[i]; i++)
            fprintf(stderr, "%s ", allowed[i]);
        fprintf(stderr, "\n");
        return 1;
    }

    /* Полный путь ищем сами: PATH пользователя нам не доверяем.
     * Сначала /usr/local (свои программы), потом стандартные /bin, /sbin. */
    static const char *dirs[] = {
        "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/usr/sbin", "/bin", "/sbin",
        NULL
    };
    char full[512];
    full[0] = 0;

    if (strchr(cmd, '/')) {
        snprintf(full, sizeof full, "%s", cmd);
    } else {
        for (int i = 0; dirs[i] && !full[0]; i++) {
            char cand[512];
            snprintf(cand, sizeof cand, "%s/%s", dirs[i], cmd);
            if (access(cand, X_OK) == 0)
                snprintf(full, sizeof full, "%s", cand);
        }
    }

    if (!full[0] || access(full, X_OK) != 0) {
        fprintf(stderr, "sud: не нашёл исполняемый файл для '%s'\n", cmd);
        fprintf(stderr, "sud: искал в /usr/local/bin, /usr/local/sbin, /usr/bin, "
                        "/usr/sbin, /bin, /sbin\n");
        return 1;
    }

    /* setgid(0) обязателен перед setuid(0): setuid root сам по себе не
     * меняет группу, и процесс продолжал бы работать с gid пользователя.
     * Из-за этого, например, файлы, созданные «от root», получали группу
     * slat, а группа пользователя — это лишние права, которых у процесса
     * быть не должно. Порядок именно такой: после setuid(0) группу уже
     * не поменять. */
    if (setgid(0) != 0)
        die(strerror(errno));
    if (setuid(0) != 0)
        die(strerror(errno));

    execv(full, &argv[1]);
    fprintf(stderr, "sud: не смог запустить %s: %s\n", full, strerror(errno));
    return 1;
}
