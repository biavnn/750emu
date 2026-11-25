// Supervisor-mode test: system call, program exceptions (illegal, privileged,
// trap), FP unavailable, user mode, rfi, decrementer interrupt.
// Output is compared against QEMU's emulated 750 (qemu-system-ppc -M 40p).
#include "tlib.h"
#include "exc.h"

unsigned do_sc(unsigned n);
void do_illegal(void);
void do_fp(void);
void do_twi_always(unsigned a);
void do_tw_lt(int a, int b);
void do_tw_gtu(unsigned a, unsigned b);
void do_twi_eq5(unsigned a);
unsigned run_user(void (*fn)(void));
void user_code(void);

extern char sc_ret[], ill_insn[], fp_insn[], trap1[], trap2[], trap3[], trap4[], user_sc_ret[];
extern char u_mfmsr[], u_mtmsr[], u_mtsrr0[], u_mfsprg[], u_rfi[], u_ill[];

static const struct { const char *name; char *addr; } labels[] = {
    {"sc_ret", sc_ret}, {"ill_insn", ill_insn}, {"fp_insn", fp_insn},
    {"trap1", trap1}, {"trap2", trap2}, {"trap3", trap3}, {"trap4", trap4},
    {"user_sc_ret", user_sc_ret}, {"u_mfmsr", u_mfmsr}, {"u_mtmsr", u_mtmsr},
    {"u_mtsrr0", u_mtsrr0}, {"u_mfsprg", u_mfsprg}, {"u_rfi", u_rfi}, {"u_ill", u_ill},
};

static const char *where(unsigned a) {
    for (unsigned i = 0; i < sizeof labels / sizeof labels[0]; i++)
        if ((unsigned)labels[i].addr == a) return labels[i].name;
    return "?";
}

static inline unsigned mfmsr(void) { unsigned v; __asm__ volatile("mfmsr %0" : "=r"(v)); return v; }
static inline void mtmsr(unsigned v) { __asm__ volatile("mtmsr %0" : : "r"(v)); }
static inline void mtdec(unsigned v) { __asm__ volatile("mtdec %0" : : "r"(v)); }
static inline unsigned mfdec(void) { unsigned v; __asm__ volatile("mfdec %0" : "=r"(v)); return v; }
static inline unsigned mfpvr(void) { unsigned v; __asm__ volatile("mfpvr %0" : "=r"(v)); return v; }

static int nexc;

static void h_program(struct exc_frame *f) {
    nexc++;
    tprintf("  [%x] srr1=%08x at %s\n", f->vec, f->srr1, where(f->srr0));
    f->srr0 += 4;                       // skip the faulting instruction
}

static void h_sc(struct exc_frame *f) {
    nexc++;
    tprintf("  [c00] srr1=%08x r0=%x return to %s, handler msr=%08x\n", f->srr1, f->r0, where(f->srr0), mfmsr());
    if (f->r0 == 0x55) f->srr1 &= ~0x4000u;     // back to supervisor mode
    else f->r3 = f->r0 * 2;                     // "system call" result
}

static volatile unsigned dec_count, dec_srr1, dec_msr;

static void h_dec(struct exc_frame *f) {
    dec_count++;
    dec_srr1 = f->srr1;
    dec_msr = mfmsr();                  // interrupts must be masked inside the handler
}

int test_main(void) {
    exc_set_handler(0x700, h_program);
    exc_set_handler(0x800, h_program);
    exc_set_handler(0xC00, h_sc);
    exc_set_handler(0x900, h_dec);

    tprintf("msr=%08x pvr=%04xxxxx\n", mfmsr(), mfpvr() >> 16);

    unsigned v;
    __asm__ volatile("mtsprg 0,%0; mtsprg 1,%1; mtsprg 2,%2; mtsprg 3,%3"
                     : : "r"(0x11110000u), "r"(0x22220000u), "r"(0x33330000u), "r"(0x44440000u));
    __asm__ volatile("mfsprg %0,2" : "=r"(v));
    tprintf("sprg2=%08x\n", v);

    tprintf("system call:\n");
    tprintf("  result=%u\n", do_sc(21));

    tprintf("illegal instruction:\n");
    do_illegal();

    tprintf("FP unavailable:\n");
    do_fp();

    tprintf("traps:\n");
    do_twi_always(0);
    do_tw_lt(1, 2);
    do_tw_lt(2, 1);         // no trap
    do_tw_lt(-1, 1);
    do_tw_gtu(0xFFFFFFFFu, 1);
    do_tw_gtu(1, 2);        // no trap
    do_twi_eq5(5);
    do_twi_eq5(4);          // no trap
    tprintf("  exceptions so far: %d\n", nexc);

    tprintf("user mode:\n");
    unsigned r = run_user(user_code);
    tprintf("  returned %u, msr=%08x\n", r, mfmsr());

    tprintf("decrementer:\n");
    mtdec(0x7FFFFFFF);
    mtmsr(mfmsr() | 0x8000);            // take any stale pending interrupt
    mtmsr(mfmsr() & ~0x8000u);
    dec_count = 0;
    mtdec(100);
    for (volatile int i = 0; i < 100000; i++) {}    // DEC passes zero with EE=0
    tprintf("  EE=0: count=%u, dec<0: %d\n", dec_count, (int)mfdec() < 0);
    mtmsr(mfmsr() | 0x8000);
    for (volatile int i = 0; i < 100000000 && !dec_count; i++) {}   // QEMU delivers on host time
    mtmsr(mfmsr() & ~0x8000u);
    tprintf("  EE=1: count=%u srr1=%08x handler msr=%08x\n", dec_count, dec_srr1, dec_msr);
    for (volatile int i = 0; i < 1000; i++) {}
    tprintf("  later: count=%u msr=%08x\n", dec_count, mfmsr());

    tprintf("done, %d synchronous exceptions\n", nexc);
    return 0;
}
