// Compile smoke test for the xcframework: builds against the iOS SDK (device
// and simulator slices) to confirm headers, modulemap, and the static lib all
// link cleanly. Not runnable on its own — it just has to compile+link.

#include "ish_embed.h"

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;

    ish_instance_t *ish = ish_init("/does-not-exist/alpine-fakefs/data", "/");
    if (ish == NULL) return 1;

    uint8_t *out = NULL;
    size_t out_len = 0;
    int ec = 0;
    int rc = ish_run(ish, "echo hi", NULL, 0, &out, &out_len, &ec);
    (void)rc;
    ish_free(out);

    const char *argvv[] = {"/usr/bin/env", NULL};
    const char *envpp[] = {"FOO=bar", NULL};
    rc = ish_exec(ish, argvv, envpp, NULL, 0, &out, &out_len, &ec);
    (void)rc;
    ish_free(out);

    ish_shutdown(ish);
    return 0;
}
