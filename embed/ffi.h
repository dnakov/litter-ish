// Stable C ABI exposed to the Rust host crate. Wraps just enough of iSH's
// internal kernel APIs to bring up an instance, install pipe-backed stdio,
// chdir, exec init, and start the kernel task. Bindgen runs over this
// header rather than the iSH kernel headers directly because the latter use
// macros and types (`struct task *`, `current`, `IS_ERR`, ...) that don't
// translate cleanly to Rust.

#ifndef ISH_EMBED_FFI_H
#define ISH_EMBED_FFI_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Mount the fakefs rootfs at /. Returns 0 on success, negative on failure.
// Must be called before any other ish_ffi_* function.
int ish_ffi_mount_fakefs(const char *rootfs_path);

// Allocate the init task and set `current` to it. Returns 0 on success.
// Must be called once per process; iSH's kernel state is process-global.
int ish_ffi_become_init(void);

// Install three host-owned fds as the init task's stdin (in_rd), stdout
// (out_wr_a), and stderr (out_wr_b). After return, the kernel owns these
// fds and will close them on task exit; the host must NOT close them.
int ish_ffi_install_pipe_stdio(int in_rd, int out_wr_a, int out_wr_b);

// chdir the init task. Returns 0 on success.
int ish_ffi_chdir(const char *path);

// Install a file with mode 0755 at `path` inside the mounted fakefs.
// Used to drop the supervisor binary into the rootfs at boot time on dev
// builds — the kernel's generic_open() auto-creates fakefs metadata, so
// the file becomes visible to subsequent execve(). On production builds
// the supervisor is pre-baked into the rootfs by build-rootfs.sh and this
// call is a no-op.
//
// Must be called AFTER ish_ffi_become_init() so `current` is set, BEFORE
// ish_ffi_execve(). Returns 0 on success, negative on failure.
int ish_ffi_install_executable(const char *path,
                               const unsigned char *bytes, size_t len);

// Exec a program in the init task. argv_packed and envp_packed are
// concatenations of NUL-terminated strings; argc/envc are counts. Returns
// 0 on success.
int ish_ffi_execve(const char *path,
                   size_t argc, const char *argv_packed,
                   size_t envc, const char *envp_packed);

// Hand the init task off to a detached kernel pthread. After this returns,
// the kernel is running; the host should drive I/O over its end of the
// stdio pipes.
int ish_ffi_task_start(void);

// Callback invoked by iSH's kernel on init exit, AFTER halt_system has
// torn down filesystems. Fires on a kernel thread; callee must be
// thread-safe and brief (post a condvar / write a self-pipe).
typedef void (*ish_ffi_exit_cb)(int code);
void ish_ffi_register_exit_hook(ish_ffi_exit_cb cb);

#ifdef __cplusplus
}
#endif

#endif
