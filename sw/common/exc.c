#include "exc.h"
#include "tlib.h"

static exc_handler_t handlers[32];

void exc_set_handler(unsigned vec, exc_handler_t h) {
    handlers[(vec >> 8) & 31] = h;
}

void exc_dispatch(unsigned vec, struct exc_frame *f) {
    exc_handler_t h = handlers[(vec >> 8) & 31];
    if (h) { h(f); return; }
    tprintf("\nUNHANDLED EXCEPTION vec=%x srr0=%08x srr1=%08x lr=%08x\n", vec, f->srr0, f->srr1, f->lr);
    texit(99);
}
