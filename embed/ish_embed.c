#include "embed/ish_embed.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "misc.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/init.h"
#include "kernel/task.h"
#include "fs/fd.h"

// ---------------------------------------------------------------------------
// Sentinel framing
//
// For each command we funnel into the persistent /bin/sh, we want to know
// exactly where its output ends and what its exit code was. We wrap the
// command so the shell emits a unique marker line when it's done.
//
// Marker: \x1e__ISH_END__<exit_code>\x1e\n
// Using \x1e (Record Separator) makes it unlikely to appear in normal
// command output.
// ---------------------------------------------------------------------------

#define ISH_MARKER_CH     '\x1e'
#define ISH_END_TOKEN     "__ISH_END__"
#define ISH_READY_TOKEN   "__ISH_READY__"

// ---------------------------------------------------------------------------
// Global state (one instance per process)
// ---------------------------------------------------------------------------

struct ish_instance {
    int stdin_wr;          // host writes commands here; kernel reads fd 0 from stdin_rd
    int stdout_rd;          // host reads merged stdout+stderr here
    int stdin_rd;           // kernel side — kept so we can close on shutdown
    int stdout_wr_a;        // kernel side — dup'd for fd 1
    int stdout_wr_b;        // kernel side — dup'd for fd 2
    pthread_mutex_t api_mtx; // serializes public API (iSH kernel is single-scheduler)
    bool running;
};

static struct ish_instance *g_ish = NULL;

static pthread_mutex_t g_exit_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_exit_cv = PTHREAD_COND_INITIALIZER;
static bool g_exit_signaled = false;
static int g_exit_code = 0;

// Hook installed into iSH's kernel/exit.c:exit_hook. Fires on the kernel
// thread when init (our /bin/sh) dies, AFTER halt_system has unmounted the
// filesystem. Signals ish_shutdown to unblock.
static void on_kernel_exit(struct task *t, int code) {
    if (t == NULL || t->parent != NULL)
        return; // not init
    pthread_mutex_lock(&g_exit_mtx);
    g_exit_signaled = true;
    g_exit_code = code;
    pthread_cond_broadcast(&g_exit_cv);
    pthread_mutex_unlock(&g_exit_mtx);
}

// Declared by kernel/exit.c
extern void (*exit_hook)(struct task *task, int code);

// ---------------------------------------------------------------------------
// Small utilities
// ---------------------------------------------------------------------------

static ssize_t write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    size_t remaining = len;
    while (remaining > 0) {
        ssize_t n = write(fd, p, remaining);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        p += n;
        remaining -= (size_t)n;
    }
    return (ssize_t)len;
}

static bool buf_append(uint8_t **buf, size_t *len, size_t *cap, const void *data, size_t n) {
    if (*len + n > *cap) {
        size_t new_cap = (*cap == 0) ? 4096 : *cap;
        while (new_cap < *len + n) new_cap *= 2;
        uint8_t *nb = realloc(*buf, new_cap);
        if (nb == NULL) return false;
        *buf = nb;
        *cap = new_cap;
    }
    memcpy(*buf + *len, data, n);
    *len += n;
    return true;
}

// Base64 encoder (no newlines, no padding trimming — standard RFC 4648).
static char *b64_encode(const uint8_t *in, size_t in_len) {
    static const char tbl[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t out_len = 4 * ((in_len + 2) / 3);
    char *out = malloc(out_len + 1);
    if (out == NULL) return NULL;
    size_t i = 0, j = 0;
    while (i + 3 <= in_len) {
        uint32_t v = ((uint32_t)in[i] << 16) | ((uint32_t)in[i+1] << 8) | (uint32_t)in[i+2];
        out[j++] = tbl[(v >> 18) & 0x3f];
        out[j++] = tbl[(v >> 12) & 0x3f];
        out[j++] = tbl[(v >> 6)  & 0x3f];
        out[j++] = tbl[ v        & 0x3f];
        i += 3;
    }
    if (i < in_len) {
        uint32_t v = (uint32_t)in[i] << 16;
        if (i + 1 < in_len) v |= (uint32_t)in[i+1] << 8;
        out[j++] = tbl[(v >> 18) & 0x3f];
        out[j++] = tbl[(v >> 12) & 0x3f];
        out[j++] = (i + 1 < in_len) ? tbl[(v >> 6) & 0x3f] : '=';
        out[j++] = '=';
    }
    out[j] = '\0';
    return out;
}

// Single-quote-escape `s` for POSIX sh: 'x' stays 'x', x's becomes 'x'\''s'.
static char *shell_quote(const char *s) {
    size_t n = strlen(s);
    // Worst case: every char is a single quote, expanding to 4 chars (`'\''`).
    char *out = malloc(n * 4 + 3);
    if (out == NULL) return NULL;
    size_t j = 0;
    out[j++] = '\'';
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '\'') {
            out[j++] = '\''; out[j++] = '\\'; out[j++] = '\''; out[j++] = '\'';
        } else {
            out[j++] = s[i];
        }
    }
    out[j++] = '\'';
    out[j] = '\0';
    return out;
}

// ---------------------------------------------------------------------------
// Send a pre-wrapped shell script to the persistent /bin/sh, then read
// until the __ISH_END__ sentinel appears. Returns ISH_OK on success and
// fills out_bytes (malloc'd), out_len, and exit_code.
// ---------------------------------------------------------------------------

static int run_wrapped(struct ish_instance *ish, const char *script,
                       uint8_t **out_bytes, size_t *out_len, int *exit_code) {
    if (!ish->running) return ISH_E_NOT_RUNNING;

    if (write_all(ish->stdin_wr, script, strlen(script)) < 0)
        return ISH_E_IO;

    uint8_t *buf = NULL;
    size_t len = 0, cap = 0;
    uint8_t chunk[4096];

    // We scan `buf` for the sentinel pattern: \x1e__ISH_END__<digits>\x1e\n
    // starting from the previous scan position to avoid O(n^2) worst case.
    size_t scan_from = 0;
    int ec = -1;
    size_t marker_start = (size_t)-1;
    size_t marker_end = (size_t)-1;

    for (;;) {
        ssize_t n = read(ish->stdout_rd, chunk, sizeof(chunk));
        if (n < 0) {
            if (errno == EINTR) continue;
            free(buf);
            return ISH_E_IO;
        }
        if (n == 0) {
            // EOF — shell died unexpectedly
            free(buf);
            return ISH_E_IO;
        }
        if (!buf_append(&buf, &len, &cap, chunk, (size_t)n)) {
            free(buf);
            return ISH_E_NOMEM;
        }

        // Scan for marker starting at scan_from. Back off a bit so a marker
        // straddling a chunk boundary isn't missed.
        size_t scan_start = scan_from > 32 ? scan_from - 32 : 0;
        for (size_t i = scan_start; i + 1 < len; i++) {
            if (buf[i] != (uint8_t)ISH_MARKER_CH) continue;
            // Expect: \x1e__ISH_END__<digits>\x1e\n
            size_t token_len = sizeof(ISH_END_TOKEN) - 1;
            if (i + 1 + token_len > len) break; // need more bytes
            if (memcmp(buf + i + 1, ISH_END_TOKEN, token_len) != 0) continue;
            size_t j = i + 1 + token_len;
            int val = 0;
            bool saw_digit = false;
            while (j < len && buf[j] >= '0' && buf[j] <= '9') {
                val = val * 10 + (buf[j] - '0');
                saw_digit = true;
                j++;
            }
            if (!saw_digit) continue;
            if (j + 1 >= len) break; // need more bytes for \x1e\n
            if (buf[j] != (uint8_t)ISH_MARKER_CH) continue;
            if (buf[j + 1] != '\n') continue;
            ec = val;
            marker_start = i;
            marker_end = j + 2;
            break;
        }
        if (marker_start != (size_t)-1) break;
        scan_from = len;
    }

    // Strip a single trailing newline before the marker (inserted by our
    // wrapper to flush any partial line of output).
    size_t payload_end = marker_start;
    if (payload_end > 0 && buf[payload_end - 1] == '\n')
        payload_end -= 1;

    uint8_t *payload = malloc(payload_end + 1);
    if (payload == NULL) {
        free(buf);
        return ISH_E_NOMEM;
    }
    memcpy(payload, buf, payload_end);
    payload[payload_end] = '\0';
    free(buf);

    (void)marker_end;
    *out_bytes = payload;
    *out_len = payload_end;
    *exit_code = ec;
    return ISH_OK;
}

// ---------------------------------------------------------------------------
// Public API: ish_run / ish_exec wrappers
// ---------------------------------------------------------------------------

int ish_run(ish_instance_t *ish, const char *cmd,
            const uint8_t *stdin_bytes, size_t stdin_len,
            uint8_t **out_bytes, size_t *out_len, int *exit_code) {
    if (ish == NULL || cmd == NULL || out_bytes == NULL || out_len == NULL || exit_code == NULL)
        return ISH_E_ARGS;

    pthread_mutex_lock(&ish->api_mtx);

    // Build: (<stdin-feeder>) | ({ <cmd> ;}) ; printf '\n\x1e__ISH_END__%d\x1e\n' $?
    // where stdin-feeder is `true` if no stdin, else `printf '%s' 'B64' | base64 -d`.
    char *stdin_b64 = NULL;
    if (stdin_len > 0) {
        stdin_b64 = b64_encode(stdin_bytes, stdin_len);
        if (stdin_b64 == NULL) {
            pthread_mutex_unlock(&ish->api_mtx);
            return ISH_E_NOMEM;
        }
    }

    size_t cap = strlen(cmd) + (stdin_b64 ? strlen(stdin_b64) : 0) + 256;
    char *script = malloc(cap);
    if (script == NULL) {
        free(stdin_b64);
        pthread_mutex_unlock(&ish->api_mtx);
        return ISH_E_NOMEM;
    }
    if (stdin_b64)
        snprintf(script, cap,
                 "{ printf %%s '%s' | base64 -d | { %s ;} ;}; "
                 "printf '\\n\\x1e%s%%d\\x1e\\n' $?\n",
                 stdin_b64, cmd, ISH_END_TOKEN);
    else
        snprintf(script, cap,
                 "{ %s ;}; printf '\\n\\x1e%s%%d\\x1e\\n' $?\n",
                 cmd, ISH_END_TOKEN);

    int rc = run_wrapped(ish, script, out_bytes, out_len, exit_code);
    free(script);
    free(stdin_b64);
    pthread_mutex_unlock(&ish->api_mtx);
    return rc;
}

int ish_exec(ish_instance_t *ish,
             const char *const *argv, const char *const *envp,
             const uint8_t *stdin_bytes, size_t stdin_len,
             uint8_t **out_bytes, size_t *out_len, int *exit_code) {
    if (ish == NULL || argv == NULL || argv[0] == NULL ||
        out_bytes == NULL || out_len == NULL || exit_code == NULL)
        return ISH_E_ARGS;

    // Build: <ENV=...> exec <quoted-argv>
    // Environment assignments before `exec` apply to it only.
    size_t total = 64;
    for (size_t i = 0; argv[i] != NULL; i++) total += strlen(argv[i]) * 4 + 4;
    if (envp) for (size_t i = 0; envp[i] != NULL; i++) total += strlen(envp[i]) * 4 + 4;

    char *cmd_buf = malloc(total);
    if (cmd_buf == NULL) return ISH_E_NOMEM;
    size_t p = 0;

    if (envp) {
        for (size_t i = 0; envp[i] != NULL; i++) {
            const char *eq = strchr(envp[i], '=');
            if (eq == NULL) { free(cmd_buf); return ISH_E_ARGS; }
            size_t key_len = (size_t)(eq - envp[i]);
            memcpy(cmd_buf + p, envp[i], key_len);
            p += key_len;
            cmd_buf[p++] = '=';
            char *q = shell_quote(eq + 1);
            if (q == NULL) { free(cmd_buf); return ISH_E_NOMEM; }
            size_t qlen = strlen(q);
            memcpy(cmd_buf + p, q, qlen);
            p += qlen;
            cmd_buf[p++] = ' ';
            free(q);
        }
    }

    // Note: no `exec` — that would replace our persistent shell (PID 1).
    // Running argv as a child process keeps the shell alive for the next call.
    for (size_t i = 0; argv[i] != NULL; i++) {
        char *q = shell_quote(argv[i]);
        if (q == NULL) { free(cmd_buf); return ISH_E_NOMEM; }
        size_t qlen = strlen(q);
        memcpy(cmd_buf + p, q, qlen);
        p += qlen;
        if (argv[i + 1] != NULL) cmd_buf[p++] = ' ';
    }
    cmd_buf[p] = '\0';

    int rc = ish_run(ish, cmd_buf, stdin_bytes, stdin_len, out_bytes, out_len, exit_code);
    free(cmd_buf);
    return rc;
}

void ish_free(void *p) { free(p); }

// ---------------------------------------------------------------------------
// Kernel boot + teardown
// ---------------------------------------------------------------------------

// do_execve wants argv and envp as concatenated NUL-separated strings.
// Pack `items[]` (a count-bounded array; no NULL terminator) into buf,
// returning total bytes written (including trailing NULs).
static size_t pack_args(char *buf, size_t cap, const char *const *items, size_t count) {
    size_t p = 0;
    for (size_t i = 0; i < count; i++) {
        size_t n = strlen(items[i]);
        if (p + n + 1 > cap) return (size_t)-1;
        memcpy(buf + p, items[i], n);
        buf[p + n] = '\0';
        p += n + 1;
    }
    return p;
}

ish_instance_t *ish_init(const char *rootfs_path, const char *workdir) {
    if (g_ish != NULL) return NULL; // one instance per process
    if (rootfs_path == NULL) return NULL;
    if (workdir == NULL) workdir = "/";

    struct ish_instance *ish = calloc(1, sizeof(*ish));
    if (ish == NULL) return NULL;
    pthread_mutex_init(&ish->api_mtx, NULL);
    ish->stdin_rd = ish->stdin_wr = ish->stdout_rd = -1;
    ish->stdout_wr_a = ish->stdout_wr_b = -1;

    // --- Mount fakefs rootfs ---
    if (mount_root(&fakefs, rootfs_path) < 0) {
        free(ish);
        return NULL;
    }

    // --- Become init (PID 1) ---
    if (become_first_process() < 0) {
        free(ish);
        return NULL;
    }

    // --- Set up stdin/stdout pipes ---
    int in_pipe[2];
    int out_pipe[2];
    if (pipe(in_pipe) < 0) { free(ish); return NULL; }
    if (pipe(out_pipe) < 0) { close(in_pipe[0]); close(in_pipe[1]); free(ish); return NULL; }
    ish->stdin_rd = in_pipe[0];
    ish->stdin_wr = in_pipe[1];
    ish->stdout_rd = out_pipe[0];
    ish->stdout_wr_a = out_pipe[1];
    ish->stdout_wr_b = dup(out_pipe[1]);
    if (ish->stdout_wr_b < 0) goto fail;

    if (create_piped_stdio_from_fds(ish->stdin_rd, ish->stdout_wr_a, ish->stdout_wr_b) < 0)
        goto fail;

    // --- chdir ---
    struct fd *pwd = generic_open(workdir, O_RDONLY_, 0);
    if (IS_ERR(pwd)) goto fail;
    fs_chdir(current->fs, pwd);

    // --- Register exit hook BEFORE execve/task_start ---
    exit_hook = on_kernel_exit;

    // --- execve /bin/sh ---
    const char *argv_items[] = {"sh", "-l"};
    char argv_buf[64];
    size_t argv_len = pack_args(argv_buf, sizeof(argv_buf), argv_items, 2);
    if (argv_len == (size_t)-1) goto fail;

    // Minimal universal env — enough to boot /bin/sh as a working shell.
    // Embedders should layer policy (LANG, PAGER, EDITOR, app-specific vars)
    // by sending `export FOO=bar` through ish_run after init.
    const char *envp_items[] = {
        "HOME=/root",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "TERM=dumb",
        "USER=root",
        "SHELL=/bin/sh",
    };
    char envp_buf[512];
    size_t envp_len = pack_args(envp_buf, sizeof(envp_buf), envp_items,
                                sizeof(envp_items) / sizeof(envp_items[0]));
    if (envp_len == (size_t)-1) goto fail;
    envp_buf[envp_len] = '\0'; // terminating empty string marks end

    if (do_execve("/bin/sh", 2, argv_buf, envp_buf) < 0)
        goto fail;

    // --- Hand the task off to a detached kernel thread ---
    task_start(current);
    ish->running = true;
    g_ish = ish;

    // --- Wait for the shell to be ready by sending a readiness probe ---
    //
    // We send: `exec 2>&1; printf '\x1e__ISH_READY__\x1e\n'\n`
    // to merge stderr into stdout for the shell's lifetime and to give us
    // a sync point before the first ish_run.
    const char *setup =
        "exec 2>&1\n"
        "printf '\\x1e" ISH_READY_TOKEN "\\x1e\\n'\n";
    if (write_all(ish->stdin_wr, setup, strlen(setup)) < 0)
        goto fail;

    // Drain stdout until we see the ready marker.
    uint8_t chunk[256];
    uint8_t *buf = NULL;
    size_t len = 0, cap = 0;
    const char ready_marker[] = {ISH_MARKER_CH, 'R','E','A','D','Y'}; // sentinel prefix
    (void)ready_marker;
    const size_t needle_len = 2 + strlen(ISH_READY_TOKEN); // \x1e TOKEN \x1e
    bool found = false;
    while (!found) {
        ssize_t n = read(ish->stdout_rd, chunk, sizeof(chunk));
        if (n <= 0) goto fail;
        if (!buf_append(&buf, &len, &cap, chunk, (size_t)n)) goto fail;
        if (len < needle_len) continue;
        // Search for \x1e__ISH_READY__\x1e
        for (size_t i = 0; i + needle_len <= len; i++) {
            if (buf[i] != (uint8_t)ISH_MARKER_CH) continue;
            if (memcmp(buf + i + 1, ISH_READY_TOKEN, strlen(ISH_READY_TOKEN)) != 0) continue;
            if (buf[i + 1 + strlen(ISH_READY_TOKEN)] != (uint8_t)ISH_MARKER_CH) continue;
            found = true;
            break;
        }
    }
    free(buf);

    return ish;

fail:
    if (ish->stdin_rd >= 0) close(ish->stdin_rd);
    if (ish->stdin_wr >= 0) close(ish->stdin_wr);
    if (ish->stdout_rd >= 0) close(ish->stdout_rd);
    if (ish->stdout_wr_a >= 0) close(ish->stdout_wr_a);
    if (ish->stdout_wr_b >= 0) close(ish->stdout_wr_b);
    free(ish);
    return NULL;
}

void ish_shutdown(ish_instance_t *ish) {
    if (ish == NULL) return;
    pthread_mutex_lock(&ish->api_mtx);
    if (ish->running) {
        // Ask the shell to exit. halt_system will kill any children and
        // unmount filesystems, then our exit_hook signals us.
        (void)write_all(ish->stdin_wr, "exit\n", 5);
    }
    pthread_mutex_unlock(&ish->api_mtx);

    // Wait for exit_hook (5s timeout).
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 5;
    pthread_mutex_lock(&g_exit_mtx);
    while (!g_exit_signaled) {
        if (pthread_cond_timedwait(&g_exit_cv, &g_exit_mtx, &deadline) == ETIMEDOUT)
            break;
    }
    pthread_mutex_unlock(&g_exit_mtx);

    pthread_mutex_lock(&ish->api_mtx);
    ish->running = false;
    if (ish->stdin_wr >= 0) { close(ish->stdin_wr); ish->stdin_wr = -1; }
    if (ish->stdout_rd >= 0) { close(ish->stdout_rd); ish->stdout_rd = -1; }
    // stdin_rd / stdout_wr_* are owned by the kernel fd table now; don't
    // double-close. fdtable_release in do_exit handles them.
    pthread_mutex_unlock(&ish->api_mtx);
    pthread_mutex_destroy(&ish->api_mtx);
    g_ish = NULL;
    free(ish);
}
