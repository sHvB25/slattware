/* myfetch.c — приветствие и инфо о системе для slattware.
 *
 * Читает /proc и /etc, внешних зависимостей нет.
 * Собирается tcc прямо внутри гостя:
 *     tcc myfetch.c -o myfetch
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/utsname.h>
#include <sys/statvfs.h>

/* --- цвета ------------------------------------------------------------- */
static const char *C_RST = "\033[0m";
static const char *C_B   = "\033[1m";
static const char *C_DIM = "\033[2m";
static const char *C_C   = "\033[36m";
static const char *C_Y   = "\033[33m";
static const char *C_BLU = "\033[34m";

static int use_color = 0;

static void paint(const char *color, const char *fmt, ...)
{
    va_list ap;
    if (use_color)
        fputs(color, stdout);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    if (use_color)
        fputs(C_RST, stdout);
}

/* Прочитать "key: value" или "key=value" из файла.
 * key="" — берём первую строку целиком.
 * Ключ сравнивается ТОЧНО: иначе "VERSION" нашлось бы в "VERSION_ID". */
static int kv(const char *path, const char *key, char *out, size_t n)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    char line[512];
    size_t klen = strlen(key);
    int found = -1;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, key, klen) != 0)
            continue;
        char *p = line + klen;
        /* после клюша допустим только разделитель или конец строки */
        if (klen > 0 && *p != '\0' && *p != '\n' &&
            *p != ' ' && *p != '\t' && *p != ':' && *p != '=')
            continue;
        while (*p == ' ' || *p == '\t' || *p == ':' || *p == '=')
            p++;
        char *e = strchr(p, '\n');
        if (e)
            *e = 0;
        /* В os-release значения в кавычках: NAME="Slattware" */
        size_t len = strlen(p);
        if (len >= 2 && ((p[0] == '"' && p[len-1] == '"') ||
                         (p[0] == '\'' && p[len-1] == '\''))) {
            p[len-1] = 0;
            p++;
        }
        snprintf(out, n, "%s", p);
        found = 0;
        break;
    }
    fclose(f);
    return found;
}

/* КБ -> "1.5G" */
static void human_size(double kb, char *buf, size_t n)
{
    static const char *u[] = { "K", "M", "G", "T" };
    int i = 0;
    while (kb >= 1024.0 && i < 3) {
        kb /= 1024.0;
        i++;
    }
    snprintf(buf, n, "%.1f%s", kb, u[i]);
}

static int count_processes(void)
{
    DIR *d = opendir("/proc");
    if (!d)
        return -1;
    int count = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL)
        if (e->d_name[0] >= '1' && e->d_name[0] <= '9')
            count++;
    closedir(d);
    return count;
}

static int count_installed(void)
{
    DIR *d = opendir("/var/lib/bdd/db");
    if (!d)
        return -1;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.')
            continue;
        n++;
    }
    closedir(d);
    return n;
}

static void logo(void)
{
    static const char *L[] = {
        "  ▄▄▄▄▄  ▄▄▄▄▄  ▄▄▄▄▄",
        "▄████████  ██████▄",
        "███  ███    ███  ███",
        "███  ███    ███  ███",
        "████████    ██████",
        "████████████████████████",
        NULL
    };
    for (int i = 0; L[i]; i++)
        paint(C_C, "%s\n", L[i]);
    printf("\n");
}

/* printf("%-Ns") считает БАЙТЫ, а русские буквы в UTF-8 занимают по 2 байта,
 * поэтому ширину считаем сами: одна кодовая точка = одна колонка. */
static int vis_width(const char *s)
{
    int w = 0;
    for (; *s; s++)
        if (((unsigned char)*s & 0xC0) != 0x80)   /* не продолжение UTF-8 */
            w++;
    return w;
}

static void row(const char *key, const char *val)
{
    const int width = 14;
    int pad = width - vis_width(key);
    paint(C_BLU, "  %s", key);
    while (pad-- > 0)
        printf(" ");
    printf("%s\n", val);
}

int main(int argc, char **argv)
{
    int quiet = 0, with_logo = 1, with_pkgs = 1;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-q") || !strcmp(argv[i], "--quiet"))
            quiet = 1;
        else if (!strcmp(argv[i], "--no-logo"))
            with_logo = 0;
        else if (!strcmp(argv[i], "--no-pkgs"))
            with_pkgs = 0;
        else if (!strcmp(argv[i], "--help")) {
            printf("usage: myfetch [-q] [--no-logo] [--no-pkgs]\n");
            return 0;
        }
    }
    use_color = isatty(1) ? 1 : 0;

    char buf[256], buf2[256];
    struct utsname u;
    int have_uname = (uname(&u) == 0);

    if (!quiet) {
        if (with_logo)
            logo();

        char osname[128], ver[64];
        if (kv("/etc/os-release", "NAME", osname, sizeof osname) != 0)
            snprintf(osname, sizeof osname, "slattware");
        if (kv("/etc/os-release", "VERSION", ver, sizeof ver) != 0 &&
            kv("/etc/os-release", "VERSION_ID", ver, sizeof ver) != 0)
            snprintf(ver, sizeof ver, "?");

        paint(C_B, "  %s", osname);
        if (strcmp(ver, "?") != 0)
            paint(C_B, " %s", ver);
        if (have_uname) {
            paint(C_Y, "   %s", u.sysname);
            paint(C_DIM, " %s %s\n", u.release, u.machine);
        } else {
            printf("\n");
        }
        printf("\n");
    }

    /* Хост */
    char hn[128] = "?";
    if (kv("/proc/sys/kernel/hostname", "", hn, sizeof hn) == 0) {
        char *p = hn;
        while (*p == ' ' || *p == '\t' || *p == ':' || *p == '=')
            p++;
        row("Хост", p);
    }

    /* Ядро: версионная строка длинная, покажем покороче + полную */
    if (kv("/proc/version", "", buf, sizeof buf) == 0) {
        char *p = buf;
        while (*p == ' ' || *p == '\t')
            p++;
        /* "Linux version 7.2.8 (build) #2 SMP ..." -> обрезаем по " #" */
        char *cut = strstr(p, " #");
        if (cut)
            *cut = 0;
        int pad = 14 - vis_width("Ядро");
        paint(C_BLU, "  %s", "Ядро");
        while (pad-- > 0)
            printf(" ");
        printf("%s", p);
        if (have_uname)
            paint(C_DIM, "  [uname: %s]", u.release);
        printf("\n");
    }

    if (have_uname)
        row("Архитектура", u.machine);

    /* Аптайм */
    if (kv("/proc/uptime", "", buf, sizeof buf) == 0) {
        int s = (int)strtod(buf, NULL);
        int d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60;
        if (d > 0)
            snprintf(buf2, sizeof buf2, "%dd %dh %dm", d, h, m);
        else if (h > 0)
            snprintf(buf2, sizeof buf2, "%dh %dm", h, m);
        else
            snprintf(buf2, sizeof buf2, "%dm %ds", m, s % 60);
        row("Аптайм", buf2);
    }

    /* Память */
    if (kv("/proc/meminfo", "MemTotal", buf, sizeof buf) == 0 &&
        kv("/proc/meminfo", "MemFree", buf2, sizeof buf2) == 0) {
        char *s1 = strchr(buf, ' '), *s2 = strchr(buf2, ' ');
        if (s1) *s1 = 0;
        if (s2) *s2 = 0;
        char b1[32], b2[32], mbuf[96];
        /* В /proc/meminfo значения уже в кБ, делить ещё раз не надо */
        human_size(strtod(buf, NULL), b1, sizeof b1);
        human_size(strtod(buf2, NULL), b2, sizeof b2);
        snprintf(mbuf, sizeof mbuf, "%s  (свободно %s)", b1, b2);
        row("Память", mbuf);
    }

    /* Диски */
    static const char *mounts[] = { "/", "/home", NULL };
    for (int i = 0; mounts[i]; i++) {
        struct statvfs st;
        if (statvfs(mounts[i], &st) != 0)
            continue;
        double total = (double)st.f_blocks * st.f_frsize / 1024.0;
        double free_ = (double)st.f_bavail * st.f_frsize / 1024.0;
        double used  = total - (double)st.f_bfree * st.f_frsize / 1024.0;
        char b1[32], b2[32], b3[32], mbuf[128], key[32];
        human_size(used,  b1, sizeof b1);
        human_size(total, b2, sizeof b2);
        human_size(free_, b3, sizeof b3);
        snprintf(mbuf, sizeof mbuf, "%s / %s   свободно %s", b1, b2, b3);
        snprintf(key, sizeof key, "Диск %s", strcmp(mounts[i], "/") == 0 ? "/" : "/home");
        row(key, mbuf);
    }

    int np = count_processes();
    if (np > 0) {
        char pbuf[32];
        snprintf(pbuf, sizeof pbuf, "%d", np);
        row("Процессов", pbuf);
    }

    char who[64];
    const char *user = getenv("USER");
    if (!user || !*user)
        user = (getuid() == 0) ? "root" : "uid?";
    snprintf(who, sizeof who, "%s (uid=%d)", user, (int)getuid());
    row("Пользователь", who);

    if (with_pkgs) {
        int n = count_installed();
        if (n > 0) {
            char pb[32];
            snprintf(pb, sizeof pb, "%d", n);
            row("Пакетов bdd", pb);
        }
    }

    printf("\n");
    paint(C_DIM, "  дистрибутив для своих · пакеты: ");
    paint(C_C, "bdd");
    paint(C_DIM, " · справка: ");
    paint(C_C, "bdd help");
    printf("\n\n");
    return 0;
}
