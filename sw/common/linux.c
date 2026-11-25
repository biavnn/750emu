// Linux-user backend: same test code, run under qemu-ppc as the golden reference.
#include "tlib.h"
#include <unistd.h>
#include <stdlib.h>

static char obuf[4096];
static int  olen;

static void flush(void) {
    if (olen) { write(1, obuf, olen); olen = 0; }
}

void tputc(char c) {
    obuf[olen++] = c;
    if (olen == sizeof obuf) flush();
}

void texit(int code) {
    flush();
    _exit(code);
}

void tlib_enable_fp(void) {}

int main(void) {
    texit(test_main());
}
