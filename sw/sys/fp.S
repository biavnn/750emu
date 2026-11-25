# FP register file: double load/store in every addressing form, register
# moves, FPSCR access. No arithmetic.
#   void fp_moves(const unsigned *in, unsigned *out)
    .text
    .globl fp_moves
fp_moves:
    lfd     f1, 0(r3)
    lfd     f2, 8(r3)
    fmr     f3, f1
    fneg    f4, f2
    fabs    f5, f4
    fnabs   f6, f1
    stfd    f3, 0(r4)
    stfd    f4, 8(r4)
    stfd    f5, 16(r4)
    stfd    f6, 24(r4)
    mr      r5, r3
    lfdu    f7, 16(r5)           # r5 = in+16
    li      r6, 8
    lfdx    f8, r5, r6           # in+24
    lfdux   f9, r5, r6           # r5 = in+24
    subf    r7, r3, r5
    stw     r7, 32(r4)           # 24
    addi    r5, r4, 32
    stfdu   f7, 8(r5)            # out+40, r5 = out+40
    stfdx   f8, r5, r6           # out+48
    stfdux  f9, r5, r6           # out+48 again, r5 = out+48
    subf    r7, r4, r5
    stw     r7, 36(r4)           # 48
    li      r6, 56
    stfiwx  f1, r4, r6           # low word of f1 at out+56
    lfd     f31, 8(r3)
    fmr     f0, f31
    stfd    f0, 64(r4)
    blr

#   unsigned fpscr_rw(unsigned v): FPSCR <- v via mtfsf, returns FPSCR
    .globl fpscr_rw
fpscr_rw:
    stwu    r1, -32(r1)
    li      r0, 0
    stw     r0, 8(r1)
    stw     r3, 12(r1)
    lfd     f1, 8(r1)
    mtfsf   0xff, f1
    mffs    f2
    stfd    f2, 16(r1)
    lwz     r3, 20(r1)
    lwz     r4, 16(r1)           # high word of mffs result (kept in r4 for fpscr_hi)
    addi    r1, r1, 32
    blr

    .globl fpscr_bits            # mtfsb1 / mtfsb0 / mtfsfi, returns FPSCR
fpscr_bits:
    stwu    r1, -32(r1)
    mtfsfi  7, 2                 # rounding mode field
    mtfsb1  24                   # VE
    mtfsb1  3                    # OX (sticky)
    mtfsb0  24
    mffs    f2
    stfd    f2, 16(r1)
    lwz     r3, 20(r1)
    addi    r1, r1, 32
    blr

    .section .note.GNU-stack,"",@progbits
