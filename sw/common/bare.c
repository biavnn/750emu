// Bare-metal backend: g3core SoC by default, QEMU 40p with -DPLAT_QEMU_40P.
#include "tlib.h"

#ifdef PLAT_QEMU_40P
// QEMU "40p" machine (golden model for supervisor tests): 16550 UART in ISA
// I/O space. There is no exit device, so print a sentinel the runner looks for.
#define UART_THR  (*(volatile unsigned char *)0x800003F8u)

void tputc(char c) { UART_THR = (unsigned char)c; }

void texit(int code) {
    tprintf("\n<<EXIT %d>>\n", code);
    for (;;) {}
}
#else
#define UART_TX   (*(volatile unsigned *)0xF0000000u)
#define SIM_EXIT  (*(volatile unsigned *)0xF0000004u)

void tputc(char c) { UART_TX = (unsigned char)c; }

void texit(int code) {
    SIM_EXIT = (unsigned)code;
    for (;;) {}
}
#endif

void tlib_enable_fp(void) {
    unsigned m;
    __asm__ volatile("mfmsr %0" : "=r"(m));
    m |= 0x2000;
    __asm__ volatile("mtmsr %0; isync" : : "r"(m));
}

// A test that uses floating point defines `const int tlib_fp = 1;` so FP is
// enabled before any compiled code can touch an FP register.
__attribute__((weak)) extern const int tlib_fp;

int main(void) {
    if (&tlib_fp && tlib_fp) tlib_enable_fp();
    return test_main();
}

// GCC may emit calls to these even with -ffreestanding.
typedef unsigned long size_t;

void *memcpy(void *d, const void *s, size_t n) {
    unsigned char *dp = d;
    const unsigned char *sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}

void *memmove(void *d, const void *s, size_t n) {
    unsigned char *dp = d;
    const unsigned char *sp = s;
    if (dp < sp) { while (n--) *dp++ = *sp++; }
    else { dp += n; sp += n; while (n--) *--dp = *--sp; }
    return d;
}

void *memset(void *d, int c, size_t n) {
    unsigned char *dp = d;
    while (n--) *dp++ = (unsigned char)c;
    return d;
}

int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = a, *y = b;
    for (; n; n--, x++, y++)
        if (*x != *y) return *x - *y;
    return 0;
}

size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}
