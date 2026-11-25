// Runs the hand-written corner-case sequences in isa_misc.S and prints
// each captured (result, CR, XER) triple.
#include "tlib.h"

unsigned isa_misc(unsigned *out);   // returns bytes written

static unsigned out[3 * 128];

int test_main(void) {
    unsigned n = isa_misc(out) / 12;
    for (unsigned i = 0; i < n; i++)
        tprintf("%2u: r=%08x cr=%08x xer=%08x\n", i, out[3 * i], out[3 * i + 1], out[3 * i + 2]);
    return 0;
}
