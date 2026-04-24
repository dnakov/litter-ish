// Minimal smoke test for embed/ish_embed.{h,c}.
//
// Usage: smoke_host <rootfs-path>
//
// The rootfs path must point at a fakefsified Alpine i386 directory
// (produced by tools/fakefsify from an Alpine minirootfs tarball).

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "embed/ish_embed.h"

static int fail_count = 0;

static void expect(const char *label, int got, int want) {
    if (got != want) {
        fprintf(stderr, "FAIL %s: got %d want %d\n", label, got, want);
        fail_count++;
    } else {
        fprintf(stderr, "ok   %s\n", label);
    }
}

static void expect_contains(const char *label, const uint8_t *buf, size_t len,
                            const char *needle) {
    if (len == 0 || memmem(buf, len, needle, strlen(needle)) == NULL) {
        fprintf(stderr, "FAIL %s: output (%zu bytes) does not contain %s\n",
                label, len, needle);
        fprintf(stderr, "     got: %.*s\n", (int)(len > 120 ? 120 : len), buf);
        fail_count++;
    } else {
        fprintf(stderr, "ok   %s\n", label);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <rootfs-path>\n", argv[0]);
        return 2;
    }
    const char *rootfs = argv[1];

    fprintf(stderr, "init rootfs=%s\n", rootfs);
    ish_instance_t *ish = ish_init(rootfs, "/");
    if (ish == NULL) {
        fprintf(stderr, "FAIL ish_init returned NULL\n");
        return 1;
    }
    fprintf(stderr, "booted\n");

    uint8_t *out; size_t n; int ec;

    // 1. echo hello
    if (ish_run(ish, "echo hello", NULL, 0, &out, &n, &ec) == ISH_OK) {
        expect("echo hello exit code", ec, 0);
        expect_contains("echo hello output", out, n, "hello");
        ish_free(out);
    } else { fprintf(stderr, "FAIL ish_run(echo hello)\n"); fail_count++; }

    // 2. false
    if (ish_run(ish, "false", NULL, 0, &out, &n, &ec) == ISH_OK) {
        expect("false exit code", ec, 1);
        ish_free(out);
    } else { fprintf(stderr, "FAIL ish_run(false)\n"); fail_count++; }

    // 3. grep with stdin
    if (ish_run(ish, "grep -o world",
                (const uint8_t *)"hello world\n", 12,
                &out, &n, &ec) == ISH_OK) {
        expect("grep exit code", ec, 0);
        expect_contains("grep output", out, n, "world");
        ish_free(out);
    } else { fprintf(stderr, "FAIL ish_run(grep)\n"); fail_count++; }

    // 4. ish_exec with env var
    const char *env_argv[] = {"/usr/bin/env", NULL};
    const char *env_envp[] = {"FOO=bar", NULL};
    if (ish_exec(ish, env_argv, env_envp, NULL, 0, &out, &n, &ec) == ISH_OK) {
        expect("env exit code", ec, 0);
        expect_contains("env output has FOO=bar", out, n, "FOO=bar");
        ish_free(out);
    } else { fprintf(stderr, "FAIL ish_exec(env)\n"); fail_count++; }

    // 5. back-to-back runs confirm the persistent shell recovers
    if (ish_run(ish, "echo back", NULL, 0, &out, &n, &ec) == ISH_OK) {
        expect("back-to-back exit code", ec, 0);
        expect_contains("back-to-back output", out, n, "back");
        ish_free(out);
    } else { fprintf(stderr, "FAIL ish_run(echo back)\n"); fail_count++; }

    fprintf(stderr, "shutting down\n");
    ish_shutdown(ish);
    fprintf(stderr, "done; failures=%d\n", fail_count);
    return fail_count == 0 ? 0 : 1;
}
