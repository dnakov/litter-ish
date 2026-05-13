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

    // Place values close to the end of the page to exercise boundary logic.
    *(uint64_t *)(p + ps - 8) = 0x1122334455667788ULL;
    *(uint32_t *)(p + ps - 16) = 0xa1b2c3d4U;
    p[ps - 18] = 0xc3;
    p[ps - 17] = 0x5a;
    p[ps - 19] = 0x7f;

    uint32_t b = 0, h = 0, w = 0;
    uint64_t x = 0;

    __asm__ volatile("ldxrb %w0, [%1]\n"
                     "clrex\n"
                     : "=&r"(b)
                     : "r"(p + ps - 19)
                     : "memory");

    __asm__ volatile("ldxrh %w0, [%1]\n"
                     "clrex\n"
                     : "=&r"(h)
                     : "r"(p + ps - 18)
                     : "memory");

    __asm__ volatile("ldxr %w0, [%1]\n"
                     "clrex\n"
                     : "=&r"(w)
                     : "r"(p + ps - 16)
                     : "memory");

    __asm__ volatile("ldxr %0, [%1]\n"
                     "clrex\n"
                     : "=&r"(x)
                     : "r"(p + ps - 8)
                     : "memory");

    printf("b=%#x h=%#x w=%#x x=%#llx\n",
           b, h, w, (unsigned long long) x);

    return (b == 0x7f && h == 0x5ac3 && w == 0xa1b2c3d4U &&
            x == 0x1122334455667788ULL) ? 0 : 13;
}
