#ifndef ISH_EMBED_H
#define ISH_EMBED_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ish_instance ish_instance_t;

enum {
    ISH_OK                =  0,
    ISH_E_BOOT            = -1,
    ISH_E_MOUNT           = -2,
    ISH_E_EXECVE          = -3,
    ISH_E_PIPE            = -4,
    ISH_E_THREAD          = -5,
    ISH_E_NOT_RUNNING     = -6,
    ISH_E_IO              = -7,
    ISH_E_TIMEOUT         = -8,
    ISH_E_NOMEM           = -9,
    ISH_E_ARGS            = -10,
};

// Boot the iSH kernel with a fakefs rooted at `rootfs_path`, chdir to
// `workdir` (NULL means "/"), and start `/bin/sh` as init. Returns NULL on
// failure. At most one instance per process lifetime — iSH uses per-process
// kernel globals, so calling ish_init a second time (even after
// ish_shutdown) is undefined.
ish_instance_t *ish_init(const char *rootfs_path, const char *workdir);

// Run a shell command string through the persistent /bin/sh.
// Pass NULL/0 for no stdin. On success, fills *out_bytes (malloc'd; caller
// frees with ish_free), *out_len, and *exit_code. stdout + stderr are merged.
int ish_run(ish_instance_t *ish,
            const char *cmd,
            const uint8_t *stdin_bytes, size_t stdin_len,
            uint8_t **out_bytes, size_t *out_len,
            int *exit_code);

// Run an argv-style program directly (no shell word-splitting). argv is
// NULL-terminated. envp is NULL-terminated "KEY=VALUE" strings, or NULL.
int ish_exec(ish_instance_t *ish,
             const char *const *argv,
             const char *const *envp,
             const uint8_t *stdin_bytes, size_t stdin_len,
             uint8_t **out_bytes, size_t *out_len,
             int *exit_code);

// Free a buffer returned by ish_run/ish_exec.
void ish_free(void *p);

// Send `exit` to the shell, wait for iSH's exit_hook (5-second timeout),
// then clean up. Does not guarantee the process may call ish_init again.
void ish_shutdown(ish_instance_t *ish);

#ifdef __cplusplus
}
#endif

#endif
