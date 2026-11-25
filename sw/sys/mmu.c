// MMU test: BATs, segments, hashed page table, TLB invalidation, Referenced /
// Changed bits, protection keys, DSI and ISI. Compared against QEMU's 750.
#include "tlib.h"
#include "exc.h"

unsigned peek(unsigned *a);
void poke(unsigned *a, unsigned v);
unsigned peekb(unsigned char *a);
void stmw_cross(unsigned *a);
unsigned run_user(void *fn, unsigned arg);
extern char peek_insn[], poke_insn[], peekb_insn[], stmw_insn[];

#define SPR_GET(n)     ({ unsigned v_; __asm__ volatile("mfspr %0," #n : "=r"(v_)); v_; })
#define SPR_SET(n, v)  __asm__ volatile("mtspr " #n ",%0; isync" : : "r"((unsigned)(v)))
static inline unsigned mfmsr(void) { unsigned v; __asm__ volatile("mfmsr %0" : "=r"(v)); return v; }
static inline void mtmsr(unsigned v) { __asm__ volatile("mtmsr %0; isync" : : "r"(v)); }
static inline void mtsrin(unsigned v, unsigned ea) { __asm__ volatile("mtsrin %0,%1; isync" : : "r"(v), "r"(ea)); }
static inline unsigned mfsrin(unsigned ea) { unsigned v; __asm__ volatile("mfsrin %0,%1" : "=r"(v) : "r"(ea)); return v; }
static inline void tlbie(unsigned ea) { __asm__ volatile("tlbie %0; sync; isync" : : "r"(ea)); }

#ifdef PLAT_QEMU_40P
#define UART_BLOCK 0x80000000u
#else
#define UART_BLOCK 0xF0000000u
#endif

// physical memory plan (identity-mapped by BAT0)
#define HTAB      ((unsigned *)0x00080000)      // 64 KiB hashed page table
#define P(n)      (0x00090000u + 0x1000u * (n)) // scratch page frames
#define BAT_RO_PA 0x000A0000u

#define VSID4 0x000123u
#define VSID6 0x000456u

static const char *where(unsigned a) {
    if (a == (unsigned)peek_insn) return "peek";
    if (a == (unsigned)poke_insn) return "poke";
    if (a == (unsigned)peekb_insn) return "peekb";
    if (a == (unsigned)stmw_insn) return "stmw";
    return "?";
}

static void h_dsi(struct exc_frame *f) {
    tprintf("  [300] dsisr=%08x dar=%08x srr1=%08x at %s\n", SPR_GET(18), SPR_GET(19), f->srr1, where(f->srr0));
    f->srr0 += 4;
    f->r3 = 0xDEAD;
}

static void h_isi(struct exc_frame *f) {
    tprintf("  [400] srr1=%08x srr0=%08x\n", f->srr1, f->srr0);
    f->srr0 = f->lr;            // return to the caller
    f->r3 = 0xBAD;
}

static void h_sc(struct exc_frame *f) {
    if (f->r0 == 0x55) f->srr1 &= ~0x4000u;
}

static unsigned *pte_insert(unsigned vsid, unsigned ea, unsigned pa, unsigned pp, unsigned secondary) {
    unsigned pgidx = (ea >> 12) & 0xFFFF;
    unsigned hash = (vsid ^ pgidx) & 0x7FFFF;
    if (secondary) hash = ~hash & 0x7FFFF;
    unsigned *pteg = HTAB + (hash & 0x3FF) * 16;
    for (int i = 0; i < 8; i++) {
        if (!(pteg[2 * i] & 0x80000000u)) {
            pteg[2 * i + 1] = (pa & ~0xFFFu) | pp;
            pteg[2 * i] = 0x80000000u | (vsid << 7) | (secondary << 6) | (pgidx >> 10);
            return &pteg[2 * i];
        }
    }
    return 0;
}

int test_main(void) {
    exc_set_handler(0x300, h_dsi);
    exc_set_handler(0x400, h_isi);
    exc_set_handler(0xC00, h_sc);

    // ---- BATs and segments ----
    for (unsigned i = 0; i < 16; i++) mtsrin(0, i << 28);
    SPR_SET(528, 0); SPR_SET(530, 0); SPR_SET(532, 0); SPR_SET(534, 0);
    SPR_SET(536, 0); SPR_SET(538, 0); SPR_SET(540, 0); SPR_SET(542, 0);
    SPR_SET(529, 0x00000002); SPR_SET(528, 0x000001FF);            // IBAT0: 16 MiB identity, RW
    SPR_SET(537, 0x00000002); SPR_SET(536, 0x000001FF);            // DBAT0: same
    SPR_SET(539, UART_BLOCK | 2); SPR_SET(538, UART_BLOCK | 3);    // DBAT1: UART
    SPR_SET(541, BAT_RO_PA | 1); SPR_SET(540, 0x50000003);         // DBAT2: 0x50000000 -> read-only block
    mtsrin(0x20000000 | VSID4, 0x40000000);                        // Ks=0 Kp=1
    mtsrin(0x10000000 | VSID6, 0x60000000);                        // no-execute
    for (unsigned i = 0; i < 0x4000; i++) HTAB[i] = 0;
    SPR_SET(25, (unsigned)HTAB);
    tprintf("sdr1=%08x sr4=%08x dbat2u=%08x dbat2l=%08x\n", SPR_GET(25), mfsrin(0x40000000), SPR_GET(540), SPR_GET(541));

    *(unsigned *)BAT_RO_PA = 0xB10CB10C;
    mtmsr(mfmsr() | 0x30);
    tprintf("translation on, msr=%08x\n", mfmsr());

    tprintf("BAT read-only block:\n");
    tprintf("  load %08x\n", peek((unsigned *)0x50000000));
    poke((unsigned *)0x50000000, 1);
    tprintf("  byte at +0x1F003: %02x\n", (*(unsigned *)(BAT_RO_PA + 0x1F000) = 0x11223344, peekb((unsigned char *)0x5001F003)));

    tprintf("page mapping, Referenced/Changed:\n");
    unsigned *pte = pte_insert(VSID4, 0x40001000, P(0), 2, 0);
    *(unsigned *)P(0) = 0xCAFE0001;
    tprintf("  pte1 before  %08x\n", pte[1]);
    tprintf("  load         %08x\n", peek((unsigned *)0x40001000));
    tprintf("  pte1 loaded  %08x\n", pte[1]);
    poke((unsigned *)0x40001004, 0xCAFE0002);
    tprintf("  pte1 stored  %08x, physical word %08x\n", pte[1], ((unsigned *)P(0))[1]);

    tprintf("unmapped page:\n");
    peek((unsigned *)0x40005008);
    poke((unsigned *)0x4000500C, 5);
    peek((unsigned *)0x70000000);                                  // segment with nothing mapped

    tprintf("read-only page (pp=3):\n");
    pte = pte_insert(VSID4, 0x40009000, P(1), 3, 0);
    *(unsigned *)P(1) = 0x0000900D;
    tprintf("  load %08x\n", peek((unsigned *)0x40009000));
    poke((unsigned *)0x40009000, 9);
    tprintf("  pte1 %08x, physical word %08x\n", pte[1], *(unsigned *)P(1));

    tprintf("secondary hash group:\n");
    pte_insert(VSID4, 0x40004000, P(2), 2, 1);
    poke((unsigned *)0x40004FFC, 0x5EC0DA4F);
    tprintf("  physical word %08x\n", *(unsigned *)(P(2) + 0xFFC));

    tprintf("remap + tlbie:\n");
    pte = pte_insert(VSID4, 0x40003000, P(3), 2, 0);
    poke((unsigned *)0x40003000, 0xAAAA0000);
    *(unsigned *)P(4) = 0xBBBB0000;
    pte[1] = P(4) | 2;
    tlbie(0x40003000);
    tprintf("  after tlbie %08x, pte1 %08x\n", peek((unsigned *)0x40003000), pte[1]);
    pte[0] = 0;                                                    // unmap
    tlbie(0x40003000);
    peek((unsigned *)0x40003000);

    tprintf("stmw running into an unmapped page:\n");
    pte_insert(VSID4, 0x40010000, P(5), 2, 0);
    stmw_cross((unsigned *)0x40010FF8);
    // (whether the words before the fault were stored is implementation-defined;
    //  QEMU stores none, g3core stores them like real hardware, so it is not printed)

    tprintf("execute from a mapped page:\n");
    ((unsigned *)P(6))[0] = 0x3860004D;                            // li r3,77
    ((unsigned *)P(6))[1] = 0x4E800020;                            // blr
    pte = pte_insert(VSID4, 0x40002000, P(6), 2, 0);
    tprintf("  returned %u, pte1 %08x\n", ((unsigned (*)(void))0x40002000)(), pte[1]);
    tprintf("  unmapped: %x\n", ((unsigned (*)(void))0x40008000)());
    pte_insert(VSID6, 0x60002000, P(6), 2, 0);
    tprintf("  no-execute segment: %x\n", ((unsigned (*)(void))0x60002000)());
    tprintf("  but data access there works: %08x\n", peek((unsigned *)0x60002000));

    // Code that switches its own segment to a different address space. The two
    // spaces map the same virtual page to different frames holding the same
    // code up to the isync, so execution must continue in the new space.
    tprintf("segment switch under running code:\n");
    for (unsigned k = 0; k < 2; k++) {
        unsigned *c = (unsigned *)P(9 + k);
        c[0] = 0x7C6021E4;                                         // mtsrin r3,r4
        c[1] = 0x4C00012C;                                         // isync
        c[2] = 0x38600001 + k;                                     // li r3,1  /  li r3,2
        c[3] = 0x4E800020;                                         // blr
    }
    pte_insert(0x111, 0x10003000, P(9), 2, 0);
    pte_insert(0x222, 0x10003000, P(10), 2, 0);
    mtsrin(0x111, 0x10000000);
    unsigned (*sw)(unsigned, unsigned) = (void *)0x10003000;
    tprintf("  stay: %u\n", sw(0x111, 0x10000000));
    tprintf("  switch: %u\n", sw(0x222, 0x10000000));
    tprintf("  and back: %u\n", sw(0x111, 0x10000000));

    tprintf("protection keys (user vs supervisor):\n");
    pte_insert(VSID4, 0x40006000, P(7), 1, 0);                     // pp=1: user read-only, supervisor read/write
    pte_insert(VSID4, 0x40007000, P(8), 0, 0);                     // pp=0: user no access
    poke((unsigned *)0x40006000, 0x51);
    poke((unsigned *)0x40007000, 0x52);
    tprintf("  supervisor: %x %x\n", peek((unsigned *)0x40006000), peek((unsigned *)0x40007000));
    tprintf("  user load pp=1: %x\n", run_user(peek, 0x40006000));
    tprintf("  user load pp=0: %x\n", run_user(peek, 0x40007000));
    run_user(poke, 0x40006000);
    tprintf("  after user store attempt: %x, msr=%08x\n", peek((unsigned *)0x40006000), mfmsr());

    mtmsr(mfmsr() & ~0x30u);
    tprintf("translation off, msr=%08x\n", mfmsr());
    return 0;
}
