// Remaining integer instructions: lwarx/stwcx., dcbz, string load/store, and
// unaligned accesses that straddle a page boundary (with the two pages mapped
// to unrelated frames, and with the second page missing).
#include "tlib.h"
#include "exc.h"

unsigned atomic_add(unsigned *p, unsigned v);
unsigned stwcx_twice(unsigned *p, unsigned v);
void dcbz_at(void *p);
void str_lswi11(const void *src, unsigned *out);
void str_lswi32(const void *src, unsigned *out);
void str_lswx(const void *base, unsigned *out, unsigned n, unsigned index);
void str_stswi13(void *dst);
void str_stswx(void *base, unsigned index, unsigned n);
unsigned x_lwz(unsigned a), x_lhz(unsigned a), x_lwbrx(unsigned a), x_lhbrx(unsigned a);
int x_lha(unsigned a);
void x_stw(unsigned a, unsigned v), x_sth(unsigned a, unsigned v), x_stwbrx(unsigned a, unsigned v), x_sthbrx(unsigned a, unsigned v);
void x_lwzu(unsigned base, unsigned *out);
unsigned x_stwux(unsigned base, unsigned index, unsigned v);

#define SPR_GET(n)     ({ unsigned v_; __asm__ volatile("mfspr %0," #n : "=r"(v_)); v_; })
#define SPR_SET(n, v)  __asm__ volatile("mtspr " #n ",%0; isync" : : "r"((unsigned)(v)))
static inline unsigned mfmsr(void) { unsigned v; __asm__ volatile("mfmsr %0" : "=r"(v)); return v; }
static inline void mtmsr(unsigned v) { __asm__ volatile("mtmsr %0; isync" : : "r"(v)); }
static inline void mtsrin(unsigned v, unsigned ea) { __asm__ volatile("mtsrin %0,%1; isync" : : "r"(v), "r"(ea)); }

#ifdef PLAT_QEMU_40P
#define UART_BLOCK 0x80000000u
#else
#define UART_BLOCK 0xF0000000u
#endif
#define HTAB  ((unsigned *)0x00080000)
#define P(n)  (0x00090000u + 0x1000u * (n))
#define VSID4 0x000123u

static void h_dsi(struct exc_frame *f) {
    tprintf("  [300] dsisr=%08x dar=%08x\n", SPR_GET(18), SPR_GET(19));
    f->srr0 += 4;
    f->r3 = 0xDEAD;
}

static void map(unsigned ea, unsigned pa) {
    unsigned pgidx = (ea >> 12) & 0xFFFF, hash = (VSID4 ^ pgidx) & 0x7FFFF;
    unsigned *pteg = HTAB + (hash & 0x3FF) * 16;
    for (int i = 0; i < 8; i++)
        if (!(pteg[2 * i] & 0x80000000u)) {
            pteg[2 * i + 1] = pa | 2;
            pteg[2 * i] = 0x80000000u | (VSID4 << 7) | (pgidx >> 10);
            return;
        }
}

static void dump(const char *tag, const unsigned char *p, int n) {
    tprintf("  %s", tag);
    for (int i = 0; i < n; i++) tprintf(" %02x", p[i]);
    tputc('\n');
}

static unsigned char buf[128] __attribute__((aligned(32)));
static unsigned out[8];

int test_main(void) {
    exc_set_handler(0x300, h_dsi);

    tprintf("lwarx/stwcx.:\n");
    unsigned cell = 40;
    tprintf("  atomic_add -> %u, %u\n", atomic_add(&cell, 2), atomic_add(&cell, 100));
    tprintf("  stwcx. CR0 with/without reservation: %02x, cell=%u\n", stwcx_twice(&cell, 7), cell);

    tprintf("dcbz:\n");
    for (int i = 0; i < 128; i++) buf[i] = (unsigned char)(0xA0 + i);
    dcbz_at(buf + 45);                                  // zeroes buf[32..63]
    dump("28..35:", buf + 28, 8);
    dump("60..67:", buf + 60, 8);

    tprintf("string instructions:\n");
    for (int i = 0; i < 128; i++) buf[i] = (unsigned char)(i + 1);
    str_lswi11(buf + 3, out);
    tprintf("  lswi 11: %08x %08x %08x\n", out[0], out[1], out[2]);
    str_lswi32(buf + 1, out);
    tprintf("  lswi 32: %08x %08x ... %08x %08x\n", out[0], out[1], out[6], out[7]);
    for (unsigned n = 1; n <= 16; n += 5) {
        str_lswx(buf, out, n, 70 + n);
        tprintf("  lswx %2u: %08x %08x %08x %08x\n", n, out[0], out[1], out[2], out[3]);
    }
    for (int i = 0; i < 32; i++) buf[i] = '.';
    str_stswi13(buf + 2);
    str_stswx(buf, 20, 6);
    buf[31] = 0;
    tprintf("  stswi/stswx: %s\n", (char *)buf);

    // ---- page-crossing accesses under translation ----
    for (unsigned i = 0; i < 16; i++) mtsrin(0, i << 28);
    SPR_SET(528, 0); SPR_SET(530, 0); SPR_SET(532, 0); SPR_SET(534, 0);
    SPR_SET(536, 0); SPR_SET(538, 0); SPR_SET(540, 0); SPR_SET(542, 0);
    SPR_SET(529, 0x00000002); SPR_SET(528, 0x000001FF);
    SPR_SET(537, 0x00000002); SPR_SET(536, 0x000001FF);
    SPR_SET(539, UART_BLOCK | 2); SPR_SET(538, UART_BLOCK | 3);
    mtsrin(VSID4, 0x40000000);
    for (unsigned i = 0; i < 0x4000; i++) HTAB[i] = 0;
    SPR_SET(25, (unsigned)HTAB);
    map(0x40020000, P(0));          // two virtually adjacent pages ...
    map(0x40021000, P(3));          // ... in unrelated frames
    map(0x40022000, P(5));          // and one whose successor is not mapped
    unsigned char *lo = (unsigned char *)P(0) + 0xFF8, *hi = (unsigned char *)P(3);
    for (int i = 0; i < 8; i++) { lo[i] = (unsigned char)(0x10 + i); hi[i] = (unsigned char)(0x80 + i); }
    mtmsr(mfmsr() | 0x30);

    tprintf("loads across a page boundary:\n");
    for (unsigned off = 0xFFC; off <= 0x1000; off++)
        tprintf("  +%03x lwz %08x lwbrx %08x lhz %04x lha %d lhbrx %04x\n", off, x_lwz(0x40020000 + off),
                x_lwbrx(0x40020000 + off), x_lhz(0x40020000 + off), x_lha(0x40020000 + off), x_lhbrx(0x40020000 + off));
    x_lwzu(0x40020000, out);
    tprintf("  lwzu: value %08x, updated base %08x\n", out[0], out[1]);

    tprintf("stores across a page boundary:\n");
    x_stw(0x40020FFD, 0xA1A2A3A4);  dump("stw    @ffd:", lo + 4, 4); dump("            ", hi, 4);
    x_stwbrx(0x40020FFF, 0xB1B2B3B4); dump("stwbrx @fff:", lo + 4, 4); dump("            ", hi, 4);
    x_sth(0x40020FFF, 0xC1C2);      dump("sth    @fff:", lo + 4, 4); dump("            ", hi, 4);
    x_sthbrx(0x40020FFF, 0xD1D2);   dump("sthbrx @fff:", lo + 4, 4); dump("            ", hi, 4);
    tprintf("  stwux: updated base %08x\n", x_stwux(0x40020000, 0xFFE, 0xE1E2E3E4));
    dump("stwux  @ffe:", lo + 4, 4); dump("            ", hi, 4);
    str_lswi11((void *)0x40020FFA, out);
    tprintf("  lswi across: %08x %08x %08x\n", out[0], out[1], out[2]);

    tprintf("second page missing:\n");
    x_lwz(0x40022FFE);
    x_lhz(0x40022FFF);
    x_stw(0x40022FFD, 1);
    tprintf("  inside the page still works: %08x\n", (x_stw(0x40022FFC, 0x600D600D), x_lwz(0x40022FFC)));

    mtmsr(mfmsr() & ~0x30u);

    tprintf("misc registers: ");
    SPR_SET(1010, 0x00004000); SPR_SET(282, 0);
    tprintf("iabr=%08x ear=%08x\n", SPR_GET(1010), SPR_GET(282));
    return 0;
}
