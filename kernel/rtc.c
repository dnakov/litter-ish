// /dev/rtc emulator. Several Linux programs (hwclock, parts of busybox,
// systemd's date sync, certain RNG-init / Tor consensus checks) read
// /dev/rtc to verify the wall clock without going through gettimeofday.
// Returning the host's current local time via RTC_RD_TIME is enough.
//
// Adapted from ish-AOK 7b7d06b9. Re-written in portable C so the embed
// host build works without Foundation; iOS reads the same NSDate-backed
// system clock through localtime_r.

#include <time.h>
#include "fs/dyndev.h"
#include "fs/devices.h"
#include "fs/fd.h"
#include "fs/poll.h"
#include "kernel/errno.h"

// Linux UAPI struct rtc_time. Same layout as struct tm minus the
// tm_wday/tm_yday/tm_isdst tail fields.
struct rtc_time_ {
    int tm_sec;
    int tm_min;
    int tm_hour;
    int tm_mday;
    int tm_mon;
    int tm_year;
    int tm_wday;
    int tm_yday;
    int tm_isdst;
};

#define RTC_RD_TIME_ 0x80247009u

static ssize_t rtc_read(struct fd *UNUSED(fd), void *UNUSED(buf), size_t UNUSED(bufsize)) {
    return 0;
}
static int rtc_poll(struct fd *UNUSED(fd)) {
    return 0;
}
static int rtc_open(int UNUSED(major), int UNUSED(minor), struct fd *UNUSED(fd)) {
    return 0;
}
static int rtc_close(struct fd *UNUSED(fd)) {
    return 0;
}

static ssize_t rtc_ioctl_size(int cmd) {
    switch ((unsigned) cmd) {
        case RTC_RD_TIME_: return sizeof(struct rtc_time_);
        default: return -1;
    }
}

static int rtc_ioctl(struct fd *UNUSED(fd), int cmd, void *arg) {
    if ((unsigned) cmd != RTC_RD_TIME_)
        return _EINVAL;
    time_t now = time(NULL);
    struct tm tm = {0};
    if (localtime_r(&now, &tm) == NULL)
        return _EIO;
    struct rtc_time_ *out = arg;
    out->tm_sec = tm.tm_sec;
    out->tm_min = tm.tm_min;
    out->tm_hour = tm.tm_hour;
    out->tm_mday = tm.tm_mday;
    out->tm_mon = tm.tm_mon;
    out->tm_year = tm.tm_year;
    out->tm_wday = tm.tm_wday;
    out->tm_yday = tm.tm_yday;
    out->tm_isdst = tm.tm_isdst;
    return 0;
}

struct dev_ops rtc_dev = {
    .open = rtc_open,
    .fd.read = rtc_read,
    .fd.poll = rtc_poll,
    .fd.close = rtc_close,
    .fd.ioctl = rtc_ioctl,
    .fd.ioctl_size = rtc_ioctl_size,
};
