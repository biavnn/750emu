// Driver for generated floating-point tests (see tools/gen_fprand.py).
#include "tlib.h"

const int tlib_fp = 1;

unsigned fp_rand(unsigned *out);

static unsigned out[4 * 4096];

int test_main(void) {
    tlib_enable_fp();
    unsigned n = fp_rand(out) / 16;
    for (unsigned i = 0; i < n; i++)
        tprintf("%4u: %08x%08x fpscr=%08x cr=%08x\n", i, out[4 * i], out[4 * i + 1], out[4 * i + 2], out[4 * i + 3]);
    return 0;
}
