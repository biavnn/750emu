// FP state handling (no arithmetic yet): the instructions an OS uses to
// initialise, save and restore floating-point registers and the FPSCR.
#include "tlib.h"
#include "exc.h"

void fp_moves(const unsigned *in, unsigned *out);
unsigned fpscr_rw(unsigned v);
unsigned fpscr_bits(void);

static inline unsigned mfmsr(void) { unsigned v; __asm__ volatile("mfmsr %0" : "=r"(v)); return v; }
static inline void mtmsr(unsigned v) { __asm__ volatile("mtmsr %0; isync" : : "r"(v)); }

static const unsigned in[8] __attribute__((aligned(8))) = {
    0x3FF00000, 0x00000001,     // 1.0000000000000002
    0xC0091EB8, 0x51EB851F,     // -3.14
    0x7FF80000, 0xDEADBEEF,     // a NaN with payload
    0x00112233, 0x44556677,
};
static unsigned out[20] __attribute__((aligned(8)));

int test_main(void) {
    mtmsr(mfmsr() | 0x2000);
    tprintf("msr=%08x\n", mfmsr());
    fp_moves(in, out);
    tprintf("fmr   %08x%08x\nfneg  %08x%08x\nfabs  %08x%08x\nfnabs %08x%08x\n",
            out[0], out[1], out[2], out[3], out[4], out[5], out[6], out[7]);
    tprintf("update forms: %u %u\n", out[8], out[9]);
    tprintf("stfdu %08x%08x\nstfdx/stfdux %08x%08x\nstfiwx %08x\nf31->f0 %08x%08x\n",
            out[10], out[11], out[12], out[13], out[14], out[16], out[17]);
    static const unsigned vals[] = { 0x000000F8, 0x00000003, 0x1F0000F8, 0x82000000, 0xFFFFFFFF, 0 };
    for (unsigned i = 0; i < sizeof vals / sizeof vals[0]; i++)
        tprintf("fpscr <- %08x reads %08x\n", vals[i], fpscr_rw(vals[i]));
    tprintf("fpscr bit ops: %08x\n", fpscr_bits());
    fpscr_rw(0);
    mtmsr(mfmsr() & ~0x2000u);
    return 0;
}
