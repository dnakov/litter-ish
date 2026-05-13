#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0)
        return 10;

    uint8_t *p = mmap(NULL, (size_t) ps * 2, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED)
        return 11;

    int32_t *cross = (int32_t *)(p + ps - 4);
    cross[0] = -1;
    cross[1] = INT32_MIN;

    int32_t *near = (int32_t *)(p + 128);
    near[0] = 0x12345678;
    near[1] = -1234567;

    int64_t a = 0, b = 0, c = 0, d = 0, e = 0, f = 0;
    uint8_t *post = (uint8_t *)near;

    // Signed-offset form.  This is the common fused JIT path and must sign
    // extend each loaded 32-bit word into the destination X registers.
    __asm__ volatile("ldpsw %x0, %x1, [%2, #-4]"
                     : "=&r"(a), "=&r"(b)
                     : "r"(p + ps)
                     : "memory");

    // Post-indexed form exercises the generic pair-load gadget.
    __asm__ volatile("ldpsw %x0, %x1, [%2], #8"
                     : "=&r"(c), "=&r"(d), "+r"(post)
                     :
                     : "memory");

    // Plain signed-offset positive case, also useful for native comparison.
    __asm__ volatile("ldpsw %x0, %x1, [%2]"
                     : "=&r"(e), "=&r"(f)
                     : "r"(near)
                     : "memory");

    printf("cross=%lld,%lld post=%lld,%lld post_delta=%ld plain=%lld,%lld\n",
           (long long)a, (long long)b,
           (long long)c, (long long)d,
           (long)(post - (uint8_t *)near),
           (long long)e, (long long)f);

    return (a == -1 && b == (int64_t)INT32_MIN &&
            c == 0x12345678LL && d == -1234567LL &&
            post == (uint8_t *)near + 8 &&
            e == 0x12345678LL && f == -1234567LL) ? 0 : 12;
}
