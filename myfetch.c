/* myfetch.c - маленький fastfetch для mydistro.
 *
 * Идея: программа читает файлы в /proc.
 * А /proc создаёт ТО ЯДРО, которое сейчас запущено.
 * Поэтому на хосте она покажет одно, а в твоей системе - другое.
 */

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>

/* Напечатать первую строку файла. */
static void print_head(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        printf("  (нет файла %s)\n", path);
        return;
    }
    char line[512];
    if (fgets(line, sizeof line, f))
        printf("%s", line);
    fclose(f);
}

/* Найти строку в /proc/meminfo по названию, напр. "MemTotal:" */
static void print_meminfo(const char *key)
{
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f)
        return;
    char line[256];
    size_t len = strlen(key);
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, key, len) == 0) {
            printf("  %s", line);
            break;
        }
    }
    fclose(f);
}

/* Считать процессы: в /proc лежит папка на каждый процесс. */
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

int main(void)
{
    printf("=== myfetch 1.0 ===\n");
    printf("Ядро:\n");
    print_head("/proc/version");
    printf("Хост:\n");
    print_head("/proc/sys/kernel/hostname");
    printf("Память:\n");
    print_meminfo("MemTotal:");
    print_meminfo("MemFree:");
    int p = count_processes();
    if (p > 0)
        printf("Процессов: %d\n", p);
    printf("Запущен от uid=%d\n", (int)getuid());
    return 0;
}
