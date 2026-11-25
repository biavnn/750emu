#include "tlib.h"

int test_main(void) {
    tprintf("Hello from g3core! %d + %d = %d, 0x%08x\n", 2, 40, 2 + 40, 0xC0FFEEu);
    return 0;
}
