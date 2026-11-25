# Helpers for the "remaining instructions" test.
    .text

    .globl atomic_add                # unsigned atomic_add(unsigned *p, unsigned v)
atomic_add:
1:  lwarx   r5, 0, r3
    add     r5, r5, r4
    stwcx.  r5, 0, r3
    bne-    1b
    mr      r3, r5
    blr

    .globl stwcx_twice               # CR0 of a stwcx. with and then without a reservation
stwcx_twice:
    lwarx   r5, 0, r3
    stwcx.  r4, 0, r3
    mfcr    r6
    addi    r4, r4, 1
    stwcx.  r4, 0, r3                # reservation is gone: must not store
    mfcr    r7
    srwi    r6, r6, 28
    srwi    r7, r7, 28
    slwi    r3, r6, 4
    or      r3, r3, r7
    blr

    .globl dcbz_at
dcbz_at:
    dcbz    0, r3
    blr

    .globl str_lswi11                # (src, out[3])
str_lswi11:
    lswi    r5, r3, 11
    stw     r5, 0(r4)
    stw     r6, 4(r4)
    stw     r7, 8(r4)
    blr

    .globl str_lswi32                # (src, out[8])
str_lswi32:
    lswi    r5, r3, 0
    stw     r5, 0(r4)
    stw     r6, 4(r4)
    stw     r7, 8(r4)
    stw     r8, 12(r4)
    stw     r9, 16(r4)
    stw     r10, 20(r4)
    stw     r11, 24(r4)
    stw     r12, 28(r4)
    blr

    .globl str_lswx                  # (base, out[4], n, index)
str_lswx:
    mtxer   r5
    li      r7, -1
    li      r8, -1
    li      r9, -1
    li      r10, -1
    lswx    r7, r3, r6
    stw     r7, 0(r4)
    stw     r8, 4(r4)
    stw     r9, 8(r4)
    stw     r10, 12(r4)
    li      r5, 0
    mtxer   r5
    blr

    .globl str_stswi13               # (dst)
str_stswi13:
    lis     r5, 0x4142
    ori     r5, r5, 0x4344
    lis     r6, 0x4546
    ori     r6, r6, 0x4748
    lis     r7, 0x494A
    ori     r7, r7, 0x4B4C
    lis     r8, 0x4D4E
    ori     r8, r8, 0x4F50
    stswi   r5, r3, 13
    blr

    .globl str_stswx                 # (base, index, n)
str_stswx:
    mtxer   r5
    lis     r6, 0x6162
    ori     r6, r6, 0x6364
    lis     r7, 0x6566
    ori     r7, r7, 0x6768
    stswx   r6, r3, r4
    li      r5, 0
    mtxer   r5
    blr

# one-instruction accessors (possibly unaligned)
    .globl x_lwz, x_lhz, x_lha, x_lwbrx, x_lhbrx, x_stw, x_sth, x_stwbrx, x_sthbrx
x_lwz:    lwz     r3, 0(r3)
          blr
x_lhz:    lhz     r3, 0(r3)
          blr
x_lha:    lha     r3, 0(r3)
          blr
x_lwbrx:  lwbrx   r3, 0, r3
          blr
x_lhbrx:  lhbrx   r3, 0, r3
          blr
x_stw:    stw     r4, 0(r3)
          blr
x_sth:    sth     r4, 0(r3)
          blr
x_stwbrx: stwbrx  r4, 0, r3
          blr
x_sthbrx: sthbrx  r4, 0, r3
          blr

    .globl x_lwzu                    # (base, out[2]): lwzu with a displacement that lands on the boundary
x_lwzu:
    lwzu    r5, 0xFFD(r3)
    stw     r5, 0(r4)
    stw     r3, 4(r4)
    blr
    .globl x_stwux                   # (base, index, v) -> updated base
x_stwux:
    stwux   r5, r3, r4
    blr

    .section .note.GNU-stack,"",@progbits
