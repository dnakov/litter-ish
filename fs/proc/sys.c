// /proc/sys hierarchy. Mostly stubs — many guest programs (apt, libc init,
// network daemons) probe for these paths and fall over if they 404 instead
// of returning empty content. Adapted from ish-AOK 918fb41d.

#include <sys/stat.h>
#include "fs/proc.h"
#include "kernel/calls.h"

extern const char *proc_ish_version;

// stub readdir for empty leaf-style directories
static bool sys_show_empty(struct proc_entry *UNUSED(entry), unsigned long *UNUSED(index), struct proc_entry *UNUSED(next_entry)) {
    return false;
}

// /proc/sys/fs/binfmt_misc — apt and various other tools poke at this; the
// "status" file reads "enabled" on real Linux when the binfmt_misc handler
// is loaded, "disabled" otherwise. Returning "enabled" is the common path.
static int proc_binfmt_misc_status_show(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "enabled\n");
    return 0;
}
static int proc_binfmt_misc_empty_show(struct proc_entry *UNUSED(entry), struct proc_data *UNUSED(buf)) {
    return 0;
}
static int proc_binfmt_misc_noop_update(struct proc_entry *UNUSED(entry), struct proc_data *UNUSED(data)) {
    return 0;
}

static struct proc_dir_entry proc_binfmt_misc_entries[] = {
    {"register", S_IFREG | 0200, .show = proc_binfmt_misc_empty_show, .update = proc_binfmt_misc_noop_update},
    {"status", S_IFREG | 0644, .show = proc_binfmt_misc_status_show, .update = proc_binfmt_misc_noop_update},
};
#define PROC_BINFMT_MISC_LEN (sizeof(proc_binfmt_misc_entries) / sizeof(proc_binfmt_misc_entries[0]))

static bool proc_binfmt_misc_readdir(struct proc_entry *UNUSED(entry), unsigned long *index, struct proc_entry *next_entry) {
    if (*index < PROC_BINFMT_MISC_LEN) {
        *next_entry = (struct proc_entry) {&proc_binfmt_misc_entries[*index], *index, NULL, NULL, 0, 0};
        (*index)++;
        return true;
    }
    return false;
}

static struct proc_dir_entry proc_sys_fs_entries[] = {
    {"binfmt_misc", S_IFDIR, .readdir = proc_binfmt_misc_readdir},
};
#define PROC_SYS_FS_LEN (sizeof(proc_sys_fs_entries) / sizeof(proc_sys_fs_entries[0]))

static bool proc_sys_fs_readdir(struct proc_entry *UNUSED(entry), unsigned long *index, struct proc_entry *next_entry) {
    if (*index < PROC_SYS_FS_LEN) {
        *next_entry = (struct proc_entry) {&proc_sys_fs_entries[*index], *index, NULL, NULL, 0, 0};
        (*index)++;
        return true;
    }
    return false;
}

// /proc/sys/kernel
static int sys_show_hostname(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    struct uname uts;
    do_uname(&uts);
    proc_printf(buf, "%s\n", uts.hostname);
    return 0;
}
static int sys_show_version(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "%s\n", proc_ish_version);
    return 0;
}
static int sys_show_kernel_osrelease(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    struct uname uts;
    do_uname(&uts);
    proc_printf(buf, "%s\n", uts.release);
    return 0;
}
static int sys_show_kernel_cap_last_cap(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    // Aligned with uname_release "4.20.69-ish".
    proc_printf(buf, "%d\n", 37);
    return 0;
}

static struct proc_dir_entry proc_sys_kernel_entries[] = {
    {"cap_last_cap", .show = sys_show_kernel_cap_last_cap},
    {"hostname", .show = sys_show_hostname},
    {"osrelease", .show = sys_show_kernel_osrelease},
    {"version", .show = sys_show_version},
};
#define PROC_SYS_KERNEL_LEN (sizeof(proc_sys_kernel_entries) / sizeof(proc_sys_kernel_entries[0]))

static bool proc_sys_kernel_readdir(struct proc_entry *UNUSED(entry), unsigned long *index, struct proc_entry *next_entry) {
    if (*index < PROC_SYS_KERNEL_LEN) {
        *next_entry = (struct proc_entry) {&proc_sys_kernel_entries[*index], *index, NULL, NULL, 0, 0};
        (*index)++;
        return true;
    }
    return false;
}

// /proc/sys/debug/exception-trace — a few RNG-init paths read this.
static int sys_show_debug_exception_trace(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "0\n");
    return 0;
}
static struct proc_dir_entry proc_sys_debug_entries[] = {
    {"exception-trace", .show = sys_show_debug_exception_trace},
};
#define PROC_SYS_DEBUG_LEN (sizeof(proc_sys_debug_entries) / sizeof(proc_sys_debug_entries[0]))
static bool proc_sys_debug_readdir(struct proc_entry *UNUSED(entry), unsigned long *index, struct proc_entry *next_entry) {
    if (*index < PROC_SYS_DEBUG_LEN) {
        *next_entry = (struct proc_entry) {&proc_sys_debug_entries[*index], *index, NULL, NULL, 0, 0};
        (*index)++;
        return true;
    }
    return false;
}

struct proc_children proc_sys_children = PROC_CHILDREN({
    {"abi", S_IFDIR, .readdir = sys_show_empty},
    {"debug", S_IFDIR, .readdir = proc_sys_debug_readdir},
    {"dev", S_IFDIR, .readdir = sys_show_empty},
    {"fs", S_IFDIR, .readdir = proc_sys_fs_readdir},
    {"fscache", S_IFDIR, .readdir = sys_show_empty},
    {"kernel", S_IFDIR, .readdir = proc_sys_kernel_readdir},
    {"net", S_IFDIR, .readdir = sys_show_empty},
    {"sunrpc", S_IFDIR, .readdir = sys_show_empty},
    {"user", S_IFDIR, .readdir = sys_show_empty},
    {"vm", S_IFDIR, .readdir = sys_show_empty},
});
