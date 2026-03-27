#include <stdlib.h>
#include <string.h>
#include "kernel/calls.h"
#include "kernel/task.h"
#include "xX_main_Xx.h"

int main(int argc, char *const argv[]) {
    char *envp;
    char *term = getenv("TERM");
    if (term) {
        size_t term_len = strlen(term);
        // "TERM=" + term + "\0" + "\0"
        envp = malloc(5 + term_len + 2);
        if (!envp) {
            fprintf(stderr, "malloc: %s\n", strerror(ENOMEM));
            return -ENOMEM;
        }
        snprintf(envp, 5 + term_len + 1, "TERM=%s", term);
        envp[5 + term_len + 1] = '\0'; // double null terminator
    } else {
        envp = malloc(1);
        if (!envp) {
            fprintf(stderr, "malloc: %s\n", strerror(ENOMEM));
            return -ENOMEM;
        }
        envp[0] = '\0';
    }

    int err = xX_main_Xx(argc, argv, envp);
    free(envp);
    if (err < 0) {
        fprintf(stderr, "xX_main_Xx: %s\n", strerror(-err));
        return err;
    }
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    task_run_current();
}
