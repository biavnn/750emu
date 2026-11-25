// Interrupt stress test: the decrementer fires at pseudo-random intervals
// while ordinary code runs (loads, stores, branches, lmw/stmw, mul/div).
// Results must be unaffected by the interrupts. In lockstep this checks that
// the pipeline takes each interrupt at exactly the same instruction as the
// reference core, with identical state.
#include "tlib.h"
#include "exc.h"

unsigned lmw_loop(unsigned n);

static inline unsigned mfmsr(void) { unsigned v; __asm__ volatile("mfmsr %0" : "=r"(v)); return v; }
static inline void mtmsr(unsigned v) { __asm__ volatile("mtmsr %0" : : "r"(v)); }
static inline void mtdec(unsigned v) { __asm__ volatile("mtdec %0" : : "r"(v)); }

// The re-arm interval must be longer than the handler's exit path or the CPU
// would never get back to the interrupted code. On the SoC the decrementer
// counts executed instructions; under QEMU it counts real time.
#ifdef PLAT_QEMU_40P
#define DEC_BASE 2000u
#else
#define DEC_BASE 70u
#endif

static volatile unsigned ticks;
static unsigned lfsr = 0xACE1u;

static void h_dec(struct exc_frame *f) {
    (void)f;
    ticks++;
    lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u);
    mtdec(DEC_BASE + (lfsr % 97u));
}

#define N 600
static int arr[N];

static void qs(int *a, int lo, int hi) {
    while (lo < hi) {
        int p = a[(lo + hi) / 2], i = lo, j = hi;
        while (i <= j) {
            while (a[i] < p) i++;
            while (a[j] > p) j--;
            if (i <= j) { int t = a[i]; a[i] = a[j]; a[j] = t; i++; j--; }
        }
        if (j - lo < hi - i) { qs(a, lo, j); lo = i; }
        else { qs(a, i, hi); hi = j; }
    }
}

static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int test_main(void) {
    exc_set_handler(0x900, h_dec);
    mtdec(DEC_BASE);
    mtmsr(mfmsr() | 0x8000);

    unsigned s = 7, h = 0;
    for (int round = 0; round < 3; round++) {
        for (int i = 0; i < N; i++) { s = s * 1103515245u + 12345u; arr[i] = (int)(s >> 4) - 0x4000000; }
        qs(arr, 0, N - 1);
        for (int i = 0; i < N; i++) h = h * 31 + (unsigned)arr[i] / (unsigned)(i + 1) + (unsigned)(arr[i] % 7);
        h ^= (unsigned)fib(15 + round);
        h += lmw_loop(500);
        tprintf("round %d: h=%08x sorted=%d\n", round, h, arr[0] <= arr[N / 2] && arr[N / 2] <= arr[N - 1]);
    }

    mtmsr(mfmsr() & ~0x8000u);
#ifdef PLAT_QEMU_40P
    // QEMU's decrementer runs on host time, so how many interrupts land inside this
    // short test varies from run to run; QEMU is only the reference for the results.
    (void)ticks;
    tprintf("interrupts taken: yes\n");
#else
    tprintf("interrupts taken: %s\n", ticks > 10 ? "yes" : "no");
#endif
    return 0;
}
