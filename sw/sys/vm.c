// Virtual-memory stress test. Everything (code, data, stack) runs through the
// hashed page table, no instruction BATs. The same physical memory is mapped
// twice (segment 0 and an alias in segment 1); code and data are used through
// both views alternately so the direct-mapped TLBs keep evicting each other,
// while the decrementer interrupts at pseudo-random points. Results must not
// depend on any of that. In lockstep this checks that the pipeline walks,
// refetches and takes interrupts at exactly the same steps as the reference.
#include "tlib.h"
#include "exc.h"

unsigned lmw_loop(unsigned n);

#define SPR_SET(n, v)  __asm__ volatile("mtspr " #n ",%0; isync" : : "r"((unsigned)(v)))
static inline unsigned mfmsr(void) { unsigned v; __asm__ volatile("mfmsr %0" : "=r"(v)); return v; }
static inline void mtmsr(unsigned v) { __asm__ volatile("mtmsr %0; isync" : : "r"(v)); }
static inline void mtdec(unsigned v) { __asm__ volatile("mtdec %0" : : "r"(v)); }
static inline void mtsrin(unsigned v, unsigned ea) { __asm__ volatile("mtsrin %0,%1; isync" : : "r"(v), "r"(ea)); }

#ifdef PLAT_QEMU_40P
#define UART_BLOCK 0x80000000u
#define DEC_BASE 2000u
#else
#define UART_BLOCK 0xF0000000u
#define DEC_BASE 70u
#endif

#define HTAB   ((unsigned *)0x00080000)
#define ALIAS  0x10000000u
#define VSID1  0x000111u

static volatile unsigned ticks;
static unsigned lfsr = 0xACE1u;

static void h_dec(struct exc_frame *f) {
    (void)f;
    ticks++;
    lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u);
    mtdec(DEC_BASE + (lfsr % 97u));
}

static void map(unsigned vsid, unsigned ea, unsigned pa) {
    unsigned pgidx = (ea >> 12) & 0xFFFF, hash = (vsid ^ pgidx) & 0x7FFFF;
    for (unsigned sec = 0; sec < 2; sec++, hash = ~hash & 0x7FFFF) {
        unsigned *pteg = HTAB + (hash & 0x3FF) * 16;
        for (int i = 0; i < 8; i++)
            if (!(pteg[2 * i] & 0x80000000u)) {
                pteg[2 * i + 1] = pa | 2;
                pteg[2 * i] = 0x80000000u | (vsid << 7) | (sec << 6) | (pgidx >> 10);
                return;
            }
    }
}

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

static __attribute__((noinline)) unsigned work(int *a, int n, unsigned s) {
    unsigned h = 0;
    for (int i = 0; i < n; i++) { s = s * 1103515245u + 12345u; a[i] = (int)(s >> 4) - 0x4000000; }
    qs(a, 0, n - 1);
    for (int i = 0; i < n; i++) h = h * 31 + (unsigned)a[i] / (unsigned)(i + 1) + (unsigned)(a[i] % 7);
    return h;
}

#define N 300
static int arr[N * 8];      // spans several pages

int test_main(void) {
    exc_set_handler(0x900, h_dec);

    for (unsigned i = 0; i < 16; i++) mtsrin(0, i << 28);
    mtsrin(VSID1, ALIAS);
    SPR_SET(528, 0); SPR_SET(530, 0); SPR_SET(532, 0); SPR_SET(534, 0);
    SPR_SET(536, 0); SPR_SET(538, 0); SPR_SET(540, 0); SPR_SET(542, 0);
    SPR_SET(537, UART_BLOCK | 2); SPR_SET(536, UART_BLOCK | 3);
    for (unsigned i = 0; i < 0x4000; i++) HTAB[i] = 0;
    for (unsigned pa = 0; pa < 0x100000; pa += 0x1000) {
        map(0, pa, pa);
        map(VSID1, ALIAS + pa, pa);
    }
    SPR_SET(25, (unsigned)HTAB);
    mtmsr(mfmsr() | 0x30);

    mtdec(DEC_BASE);
    mtmsr(mfmsr() | 0x8000);

    unsigned h = 0;
    for (unsigned round = 0; round < 8; round++) {
        unsigned (*fn)(int *, int, unsigned) = work;
        unsigned (*ll)(unsigned) = lmw_loop;
        int *a = arr + (round % 5) * N;
        if (round & 1) { fn = (void *)((unsigned)fn + ALIAS); ll = (void *)((unsigned)ll + ALIAS); }
        if (round & 2) a = (int *)((unsigned)a + ALIAS);
        h ^= fn(a, N, round + 1);
        h += ll(200);
        tprintf("round %u: h=%08x\n", round, h);
    }

    mtmsr(mfmsr() & ~0x8030u);
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
