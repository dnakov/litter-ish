#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#ifndef SS_AUTODISARM
#define SS_AUTODISARM 0
#endif

static _Thread_local uintptr_t tls_stack_lo;
static _Thread_local uintptr_t tls_stack_hi;
static atomic_int ready_count;
static atomic_int handled_count;
static atomic_int failure_count;
static atomic_int stop_threads;

static void handler(int sig, siginfo_t *info, void *uctx) {
    (void)sig;
    (void)info;
    (void)uctx;
    char marker;
    uintptr_t sp = (uintptr_t)&marker;
    if (!(tls_stack_lo < sp && sp <= tls_stack_hi)) {
        atomic_fetch_add_explicit(&failure_count, 1, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&handled_count, 1, memory_order_release);
}

static void *thread_main(void *arg) {
    long id = (long)arg;
    size_t size = 64 * 1024;
    void *mem = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) {
        perror("mmap");
        atomic_fetch_add_explicit(&failure_count, 1, memory_order_relaxed);
        return NULL;
    }

    // Touch the stack and make each thread's range distinct and observable.
    memset(mem, (int)(0x40 + id), size);
    tls_stack_lo = (uintptr_t)mem;
    tls_stack_hi = tls_stack_lo + size;

    stack_t ss;
    memset(&ss, 0, sizeof(ss));
    ss.ss_sp = mem;
    ss.ss_size = size;
    ss.ss_flags = 0;
    if (sigaltstack(&ss, NULL) != 0) {
        perror("sigaltstack");
        atomic_fetch_add_explicit(&failure_count, 1, memory_order_relaxed);
        return NULL;
    }

    atomic_fetch_add_explicit(&ready_count, 1, memory_order_release);
    while (!atomic_load_explicit(&stop_threads, memory_order_acquire)) {
        struct timespec ts = {.tv_sec = 0, .tv_nsec = 1000000};
        nanosleep(&ts, NULL);
    }
    return NULL;
}

static int wait_for_count(atomic_int *value, int want) {
    for (int i = 0; i < 5000; i++) {
        if (atomic_load_explicit(value, memory_order_acquire) >= want)
            return 0;
        struct timespec ts = {.tv_sec = 0, .tv_nsec = 1000000};
        nanosleep(&ts, NULL);
    }
    return 1;
}

int main(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    if (sigaction(SIGUSR1, &sa, NULL) != 0) {
        perror("sigaction");
        return 2;
    }

    pthread_t t1, t2;
    if (pthread_create(&t1, NULL, thread_main, (void *)1) != 0)
        return 3;
    if (pthread_create(&t2, NULL, thread_main, (void *)2) != 0)
        return 4;

    if (wait_for_count(&ready_count, 2) != 0) {
        puts("timeout waiting for threads");
        return 5;
    }

    // If sigaltstack is incorrectly shared through sighand, both deliveries
    // will use whichever thread installed its stack last. The TLS range check
    // in the handler catches that deterministically.
    if (pthread_kill(t1, SIGUSR1) != 0)
        return 6;
    if (wait_for_count(&handled_count, 1) != 0)
        return 7;
    if (pthread_kill(t2, SIGUSR1) != 0)
        return 8;
    if (wait_for_count(&handled_count, 2) != 0)
        return 9;
    if (pthread_kill(t1, SIGUSR1) != 0)
        return 10;
    if (wait_for_count(&handled_count, 3) != 0)
        return 11;

    atomic_store_explicit(&stop_threads, 1, memory_order_release);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);

    int failures = atomic_load_explicit(&failure_count, memory_order_acquire);
    printf("sigaltstack-thread handled=%d failures=%d\n",
           atomic_load_explicit(&handled_count, memory_order_acquire), failures);
    if (failures != 0)
        return 12;
    puts("sigaltstack-thread-ok");
    return 0;
}
