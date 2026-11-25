// Driver for generated random-instruction tests (see tools/gen_random.py).
#include "tlib.h"

unsigned rnd_test(unsigned *out);

static unsigned out[16384];

int test_main(void) {
    unsigned n = rnd_test(out) / 4;
    for (unsigned i = 0; i < n; i++)
        tprintf("%08x%c", out[i], (i % 8 == 7) ? '\n' : ' ');
    tputc('\n');
    return 0;
}
