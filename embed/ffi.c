#include "embed/ffi.h"

#include <errno.h>
#include <stddef.h>
#include <string.h>
#include <sys/stat.h>

#include "misc.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/init.h"
#include "kernel/task.h"
#include "fs/dev.h"
#include "fs/devices.h"
#include "fs/fd.h"
#include "fs/path.h"

extern void (*exit_hook)(struct task *task, int code);

static ish_ffi_exit_cb g_exit_cb = NULL;

static void exit_hook_trampoline(struct task *t, int code) {
    if (t == NULL || t->parent != NULL)
        return; // not init
    ish_ffi_exit_cb cb = g_exit_cb;
    if (cb != NULL)
        cb(code);
}

int ish_ffi_mount_fakefs(const char *rootfs_path) {
    if (rootfs_path == NULL)
        return -EINVAL;
    return mount_root(&fakefs, rootfs_path);
}

int ish_ffi_become_init(void) {
    return become_first_process();
}

int ish_ffi_mount_procfs(void) {
    if (current == NULL)
        return -EINVAL;
    return do_mount(&procfs, "proc", "/proc", "", 0);
}

int ish_ffi_mount_devpts(void) {
    if (current == NULL)
        return -EINVAL;
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR|0666,
                    dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    return do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
}

int ish_ffi_install_pipe_stdio(int in_rd, int out_wr_a, int out_wr_b) {
    return create_piped_stdio_from_fds(in_rd, out_wr_a, out_wr_b);
}

int ish_ffi_chdir(const char *path) {
    if (path == NULL)
        return -EINVAL;
    struct fd *pwd = generic_open(path, O_RDONLY_, 0);
    if (IS_ERR(pwd))
        return (int)PTR_ERR(pwd);
    fs_chdir(current->fs, pwd);
    return 0;
}

int ish_ffi_install_executable(const char *path,
                               const unsigned char *bytes, size_t len) {
    if (path == NULL || (bytes == NULL && len > 0))
        return -EINVAL;
    // O_CREAT_|O_WRONLY_|O_TRUNC_ — create or truncate, write only. Fakefs
    // auto-registers metadata via fakefs_open's O_CREAT path.
    struct fd *fd = generic_open(path, O_CREAT_ | O_WRONLY_ | O_TRUNC_, 0755);
    if (IS_ERR(fd))
        return (int)PTR_ERR(fd);
    size_t written = 0;
    while (written < len) {
        ssize_t n = fd->ops->write(fd, bytes + written, len - written);
        if (n < 0) {
            fd_close(fd);
            return (int)n;
        }
        if (n == 0)
            break;
        written += (size_t)n;
    }
    int rc = fd_close(fd);
    if (rc < 0)
        return rc;
    return (written == len) ? 0 : -EIO;
}

int ish_ffi_execve(const char *path,
                   size_t argc, const char *argv_packed,
                   size_t envc, const char *envp_packed) {
    if (path == NULL || argv_packed == NULL)
        return -EINVAL;
    (void)envc; // do_execve treats envp as packed strings terminated by an empty entry; envc is informational
    (void)argc; // ditto
    return do_execve(path, argc, argv_packed, envp_packed);
}

int ish_ffi_task_start(void) {
    if (current == NULL)
        return -EINVAL;
    task_start(current);
    return 0;
}

void ish_ffi_register_exit_hook(ish_ffi_exit_cb cb) {
    g_exit_cb = cb;
    exit_hook = (cb != NULL) ? exit_hook_trampoline : NULL;
}
