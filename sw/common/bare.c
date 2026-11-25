// Bare-metal backend for the g3core SoC.
#include "tlib.h"

#define UART_TX   (*(volatile unsigned *)0xF0000000u)
#define SIM_EXIT  (*(volatile unsigned *)0xF0000004u)

void tputc(char c) { UART_TX = (unsigned char)c; }

void texit(int code) {
    SIM_EXIT = (unsigned)code;
    for (;;) {}
}

int main(void) {
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
