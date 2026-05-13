#include <stdint.h>
#include <stdio.h>

static volatile uint64_t g64 = 0x1122334455667788ULL;
static volatile uint32_t g32 = 0x89abcdefU;
static volatile uint64_t p64[2] = {0x0102030405060708ULL, 0x1112131415161718ULL};
static volatile uint32_t p32[2] = {0x10203040U, 0x50607080U};

static int test_stxr64_after_clrex(void) {
    uint64_t old = 0, newv = 0xfeedfacecafebeefULL;
    uint32_t st = 0;
    g64 = 0x1122334455667788ULL;
    __asm__ volatile(
        "ldxr %0, [%2]\n"
        "clrex\n"
        "stxr %w1, %3, [%2]\n"
        : "=&r"(old), "=&r"(st)
        : "r"(&g64), "r"(newv)
        : "memory");
    printf("stxr64 old=%#llx st=%u mem=%#llx\n",
           (unsigned long long) old, st, (unsigned long long) g64);
    return (st == 1 && g64 == 0x1122334455667788ULL) ? 0 : 1;
}

static int test_stxr32_after_clrex(void) {
    uint32_t old = 0, newv = 0x13579bdfU;
    uint32_t st = 0;
    g32 = 0x89abcdefU;
    __asm__ volatile(
        "ldxr %w0, [%2]\n"
        "clrex\n"
        "stxr %w1, %w3, [%2]\n"
        : "=&r"(old), "=&r"(st)
        : "r"(&g32), "r"(newv)
        : "memory");
    printf("stxr32 old=%#x st=%u mem=%#x\n", old, st, g32);
    return (st == 1 && g32 == 0x89abcdefU) ? 0 : 2;
}

static int test_stxp64_after_clrex(void) {
    uint64_t old0 = 0, old1 = 0;
    uint64_t new0 = 0xaaaaaaaa55555555ULL, new1 = 0xcccccccc33333333ULL;
    uint32_t st = 0;
    p64[0] = 0x0102030405060708ULL;
    p64[1] = 0x1112131415161718ULL;
    __asm__ volatile(
        "ldxp %0, %1, [%3]\n"
        "clrex\n"
        "stxp %w2, %4, %5, [%3]\n"
        : "=&r"(old0), "=&r"(old1), "=&r"(st)
        : "r"(p64), "r"(new0), "r"(new1)
        : "memory");
    printf("stxp64 old=%#llx,%#llx st=%u mem=%#llx,%#llx\n",
           (unsigned long long) old0, (unsigned long long) old1, st,
           (unsigned long long) p64[0], (unsigned long long) p64[1]);
    return (st == 1 && p64[0] == 0x0102030405060708ULL && p64[1] == 0x1112131415161718ULL) ? 0 : 3;
}

static int test_stxp32_after_clrex(void) {
    uint32_t old0 = 0, old1 = 0;
    uint32_t new0 = 0xa5a5f00dU, new1 = 0x55aa0ff0U;
    uint32_t st = 0;
    p32[0] = 0x10203040U;
    p32[1] = 0x50607080U;
    __asm__ volatile(
        "ldxp %w0, %w1, [%3]\n"
        "clrex\n"
        "stxp %w2, %w4, %w5, [%3]\n"
        : "=&r"(old0), "=&r"(old1), "=&r"(st)
        : "r"(p32), "r"(new0), "r"(new1)
        : "memory");
    printf("stxp32 old=%#x,%#x st=%u mem=%#x,%#x\n",
           old0, old1, st, p32[0], p32[1]);
    return (st == 1 && p32[0] == 0x10203040U && p32[1] == 0x50607080U) ? 0 : 4;
}

int main(void) {
    int r1 = test_stxr64_after_clrex();
    int r2 = test_stxr32_after_clrex();
    int r3 = test_stxp64_after_clrex();
    int r4 = test_stxp32_after_clrex();

    if (r1 || r2 || r3 || r4) {
        printf("FAIL r1=%d r2=%d r3=%d r4=%d\n", r1, r2, r3, r4);
        return 1;
    }

    puts("clrex-ok");
    return 0;
}
