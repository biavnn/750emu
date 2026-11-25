// Tiny portable I/O layer. Two backends:
//   bare.c  - runs on the g3core SoC (MMIO UART + exit register)
//   linux.c - runs under qemu-ppc user mode (write/exit syscalls)
// Tests use only this API so both builds produce byte-identical output.
#ifndef TLIB_H
#define TLIB_H

#include <stdarg.h>

void tputc(char c);
void tputs(const char *s);
void tprintf(const char *fmt, ...);
void texit(int code) __attribute__((noreturn));

int test_main(void);

#endif
