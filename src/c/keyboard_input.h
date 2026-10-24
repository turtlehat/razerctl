#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <linux/input.h>
#include <unistd.h>

/* Opens every event node of the given Razer product.
   Returns the number opened, or -1 with errno when a match can't be opened. */
static inline int rz_keyboard_open_all(unsigned short product, int *fds, int max) {
    DIR *dir = opendir("/sys/class/input");
    if (!dir) return -1;
    int count = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) && count < max) {
        if (strncmp(entry->d_name, "event", 5)) continue;
        char path[300];
        unsigned vendor = 0, id = 0;
        snprintf(path, sizeof(path), "/sys/class/input/%s/device/id/vendor", entry->d_name);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        int ok = fscanf(f, "%x", &vendor) == 1;
        fclose(f);
        snprintf(path, sizeof(path), "/sys/class/input/%s/device/id/product", entry->d_name);
        f = fopen(path, "r");
        if (!f) continue;
        ok = ok && fscanf(f, "%x", &id) == 1;
        fclose(f);
        if (!ok || vendor != 0x1532 || id != product) continue;
        snprintf(path, sizeof(path), "/dev/input/%s", entry->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd >= 0) { fds[count++] = fd; continue; }
        int saved = errno;
        while (count > 0) close(fds[--count]);
        closedir(dir);
        errno = saved;
        return -1;
    }
    closedir(dir);
    return count;
}

/* 0: drained, 1: event, negative: explicit failure. No exclusive grab. */
static inline int rz_keyboard_next(int fd, unsigned short *type,
                                    unsigned short *code, int *value) {
    struct input_event event;
    ssize_t n;
    do { n = read(fd, &event, sizeof(event)); } while (n < 0 && errno == EINTR);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    if (n != sizeof(event)) return -1;
    *type = event.type;
    *code = event.code;
    *value = event.value;
    return 1;
}
