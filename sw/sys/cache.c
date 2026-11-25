// Cache behaviour that software can observe: code rewritten and flushed with
// icbi or HID0[ICFI], data sets larger than the cache with conflicting lines,
// and stores of every size and alignment (including ones that straddle word
// and line boundaries) read back through other sizes.
#include "tlib.h"
#include "exc.h"

#define SPR_GET(n)     ({ unsigned v_; __asm__ volatile("mfspr %0," #n : "=r"(v_)); v_; })
#define SPR_SET(n, v)  __asm__ volatile("mtspr " #n ",%0; isync" : : "r"((unsigned)(v)))

static unsigned code[64] __attribute__((aligned(32)));
typedef unsigned (*fn_t)(void);

static void flush_icbi(void *p) {
    __asm__ volatile("dcbst 0,%0; sync; icbi 0,%0; sync; isync" : : "r"(p));
}

static void set_code(unsigned *at, unsigned n) {
    at[0] = 0x38600000u | (n & 0x7FFF);     // li r3,n
    at[1] = 0x4E800020u;                    // blr
}

#define BIG (48 * 1024)
static unsigned char big[BIG] __attribute__((aligned(32)));

static unsigned sum_bytes(const unsigned char *p, unsigned n) {
    unsigned s = 0;
    for (unsigned i = 0; i < n; i++) s = s * 131 + p[i];
    return s;
}

int test_main(void) {
    tprintf("rewritten code with icbi:\n");
    for (unsigned k = 1; k <= 4; k++) {
        set_code(code, 100 * k);
        flush_icbi(code);
        tprintf("  call %u -> %u\n", k, ((fn_t)code)());
    }

    tprintf("rewritten code with HID0[ICFI]:\n");
    unsigned hid0 = SPR_GET(1008);
    for (unsigned k = 1; k <= 3; k++) {
        set_code(code + 32, 7 * k);
        SPR_SET(1008, hid0 | 0x800);
        SPR_SET(1008, hid0);
        tprintf("  call %u -> %u\n", k, ((fn_t)(code + 32))());
    }

    tprintf("several functions in one line, rewritten one at a time:\n");
    for (unsigned i = 0; i < 4; i++) set_code(code + 8 + 2 * i, 10 + i);
    flush_icbi(code + 8);
    unsigned acc = 0;
    for (unsigned i = 0; i < 4; i++) acc = acc * 100 + ((fn_t)(code + 8 + 2 * i))();
    tprintf("  before %u\n", acc);
    set_code(code + 8 + 2 * 2, 55);
    flush_icbi(code + 8);
    acc = 0;
    for (unsigned i = 0; i < 4; i++) acc = acc * 100 + ((fn_t)(code + 8 + 2 * i))();
    tprintf("  after  %u\n", acc);

    tprintf("data larger than the cache:\n");
    unsigned s = 12345;
    for (unsigned i = 0; i < BIG; i++) { s = s * 1103515245u + 12345u; big[i] = (unsigned char)(s >> 16); }
    tprintf("  sum %08x\n", sum_bytes(big, BIG));
    // ping-pong between lines that share a cache index (16 KiB apart)
    unsigned h = 0;
    for (unsigned i = 0; i < 2000; i++) {
        unsigned o = (i * 37) & 0x3FFF;
        big[o] ^= (unsigned char)i;
        big[o + 16384] += big[o];
        big[o + 32768] = (unsigned char)(big[o + 16384] + big[o]);
        h = h * 31 + big[o + 32768];
    }
    tprintf("  ping-pong h=%08x sum %08x\n", h, sum_bytes(big, BIG));

    tprintf("stores of every size and alignment:\n");
    for (unsigned i = 0; i < 256; i++) big[i] = (unsigned char)i;
    unsigned char *p = big + 64;
    for (unsigned off = 0; off < 40; off++) {
        volatile unsigned *w = (volatile unsigned *)(p + off);
        volatile unsigned short *hw = (volatile unsigned short *)(p + 80 + off);
        volatile unsigned char *b = p;
        // byte reads first, so the lines involved are in the cache when the
        // unaligned store arrives, and again afterwards to see its effect
        h += b[off] + b[off + 3] + b[80 + off] + b[80 + off + 1];
        *w = 0xA0B0C0D0u + off;                 // word at every byte offset, across lines
        *hw = (unsigned short)(0xE100 + off);   // halfword likewise
        h = h * 31 + b[off] + b[off + 3] + b[80 + off] + b[80 + off + 1];
        h = h * 31 + *(volatile unsigned *)(p + off + 1) + *(volatile unsigned short *)(p + 80 + off + 1);
    }
    tprintf("  h=%08x sum %08x\n", h, sum_bytes(big, 256));
    return 0;
}
