# Hand-written corner cases that compilers rarely emit: XER CA/OV/SO,
# record forms, CR logical ops, mtcrf/mcrxr, byte-reversed and update-form
# loads/stores, lmw/stmw, CTR branches. Results land in out[] as
# (value, CR, XER) triples; nothing address-dependent is recorded so the
# bare-metal and Linux builds must match exactly.
#
#   unsigned isa_misc(unsigned *out)   -> returns bytes written

    .macro SAVE reg
    stw     \reg, 0(r31)
    mfcr    r29
    stw     r29, 4(r31)
    mfxer   r29
    stw     r29, 8(r31)
    addi    r31, r31, 12
    li      r29, 0
    mtxer   r29
    mtcrf   0xff, r29
    .endm

    .text
    .globl isa_misc
isa_misc:
    stwu    r1, -96(r1)
    mflr    r0
    stw     r0, 100(r1)
    stmw    r14, 16(r1)          # r14..r31 -> 16..87
    mfcr    r12
    stw     r12, 88(r1)
    mr      r31, r3
    mr      r30, r3
    li      r0, 0
    mtxer   r0
    mtcrf   0xff, r0

    # --- add/sub with carry and overflow ---
    lis     r3, 0x7fff
    ori     r3, r3, 0xffff
    li      r4, 1
    addo.   r5, r3, r4           # overflow -> OV, SO, CR0=LT|SO
    SAVE    r5
    li      r3, -1
    addc.   r5, r3, r4           # 0, CA=1, CR0=EQ
    SAVE    r5
    li      r3, -1
    addc    r5, r3, r4
    li      r6, 0
    adde    r7, r6, r6           # 0+0+CA = 1
    SAVE    r7
    li      r3, 5
    li      r4, 7
    subfc   r5, r4, r3           # 5-7: borrow -> CA=0
    SAVE    r5
    subfc   r5, r3, r4           # 7-5: CA=1
    SAVE    r5
    lis     r3, 0x8000
    nego.   r5, r3               # -INT_MIN overflows
    SAVE    r5
    subfo.  r5, r4, r3           # INT_MIN - 7 overflows
    SAVE    r5
    li      r3, 5
    subfic  r5, r3, 3            # 3-5: CA=0
    SAVE    r5
    li      r3, -1
    addic.  r5, r3, 1            # 0, CA=1, EQ
    SAVE    r5
    li      r3, -1               # set CA, then extended ops
    li      r4, 1
    addc    r0, r3, r4
    li      r3, 10
    addme   r5, r3               # 10 + -1 + 1 = 10, CA=1
    SAVE    r5
    li      r3, 10
    addze   r5, r3               # CA=0 -> 10
    SAVE    r5
    subfze  r5, r3               # ~10 + 0 + 0 = -11
    SAVE    r5
    subfme  r5, r3               # ~10 + -1 + 0 = -12, CA=1
    SAVE    r5
    li      r3, 3
    li      r4, 9
    addc    r0, r4, r4           # CA=0
    subfe   r5, r3, r4           # ~3 + 9 + 0 = 5, CA=1
    SAVE    r5

    # --- multiply / divide ---
    lis     r3, 0x1000
    lis     r4, 0x0010
    mullwo. r5, r3, r4           # overflow
    SAVE    r5
    li      r3, -3
    lis     r4, 0x4000
    mulhw   r5, r3, r4
    SAVE    r5
    mulhwu  r5, r3, r4
    SAVE    r5
    mulli   r5, r3, -1000
    SAVE    r5
    li      r3, -7
    li      r4, 2
    divw.   r5, r3, r4           # -3
    SAVE    r5
    divwu   r5, r3, r4           # 0x7ffffffc
    SAVE    r5

    # --- shifts, rotates, count ---
    li      r3, -5
    srawi.  r5, r3, 1            # -3, CA=1 (1 shifted out)
    SAVE    r5
    li      r3, -4
    srawi   r5, r3, 2            # -1, CA=0
    SAVE    r5
    li      r4, 40
    sraw    r5, r3, r4           # -1, CA=1
    SAVE    r5
    li      r4, 32
    srw     r5, r3, r4           # 0
    SAVE    r5
    li      r4, 31
    slw.    r5, r3, r4
    SAVE    r5
    lis     r5, 0x1234
    ori     r5, r5, 0x5678
    li      r3, 0xAB
    rlwimi  r5, r3, 8, 16, 23    # 0x1234AB78
    SAVE    r5
    li      r4, 12
    rlwnm.  r5, r5, r4, 4, 27
    SAVE    r5
    rlwinm  r5, r5, 0, 28, 3     # wrap-around mask
    SAVE    r5
    li      r3, 0
    cntlzw. r5, r3               # 32
    SAVE    r5
    li      r3, 1
    cntlzw  r5, r3               # 31
    SAVE    r5

    # --- logical / sign extension ---
    lis     r3, 0xF0F0
    ori     r3, r3, 0x1234
    li      r4, 0x0FF0
    andi.   r5, r3, 0x00F0
    SAVE    r5
    andis.  r5, r3, 0x0F0F
    SAVE    r5
    nand    r5, r3, r4
    nor     r6, r3, r4
    eqv     r7, r3, r4
    orc     r8, r3, r4
    andc.   r9, r3, r4
    xor     r5, r5, r6
    add     r5, r5, r7
    xor     r5, r5, r8
    add     r5, r5, r9
    SAVE    r5
    xoris   r5, r3, 0xFFFF
    oris    r5, r5, 0x0001
    SAVE    r5
    li      r3, 0x80
    extsb.  r5, r3
    SAVE    r5
    li      r3, 0x7FFF
    addi    r3, r3, 1
    extsh.  r5, r3
    SAVE    r5

    # --- compares and CR logic ---
    li      r3, -1
    li      r4, 1
    cmpw    cr0, r3, r4          # LT
    cmplw   cr1, r3, r4          # GT (unsigned)
    cmpwi   cr2, r3, -1          # EQ
    cmplwi  cr3, r4, 2           # LT
    SAVE    r3
    li      r3, 5
    cmpwi   cr3, r3, 5           # cr3.eq = bit 14
    cmpwi   cr5, r3, 7           # cr5.lt = bit 20
    crand   0, 14, 20
    cror    1, 14, 21
    crxor   2, 14, 20
    crnand  3, 14, 20
    creqv   4, 14, 21
    crandc  5, 14, 21
    crorc   6, 21, 14
    crnor   7, 21, 22
    SAVE    r3
    cmpwi   cr2, r3, 9
    mcrf    cr7, cr2
    SAVE    r3
    lis     r3, 0x1234
    ori     r3, r3, 0x5678
    mtcrf   0x5a, r3
    SAVE    r3
    lis     r3, 0xE000
    mtxer   r3
    mcrxr   cr6                  # cr6 <- SO,OV,CA,0 ; clears XER[0:3]
    SAVE    r3

    # --- byte-reversed and update-form memory ops (scratch at 8(r1)) ---
    lis     r3, 0x1122
    ori     r3, r3, 0x3344
    addi    r4, r1, 8
    stwbrx  r3, 0, r4
    lwz     r5, 0(r4)
    SAVE    r5
    lhbrx   r5, 0, r4
    SAVE    r5
    sthbrx  r3, 0, r4
    lwz     r5, 0(r4)
    SAVE    r5
    lwbrx   r5, 0, r4
    SAVE    r5
    li      r3, 0x55
    stbu    r3, 1(r4)            # r4 = r1+9
    subf    r5, r1, r4
    SAVE    r5
    lbzu    r6, -1(r4)           # r4 = r1+8
    li      r7, 2
    lhzux   r5, r4, r7           # r4 = r1+10
    subf    r7, r1, r4
    add     r5, r5, r7
    add     r5, r5, r6
    SAVE    r5
    li      r3, -2
    sth     r3, 8(r1)
    lha     r5, 8(r1)
    SAVE    r5
    lhz     r5, 8(r1)
    SAVE    r5
    li      r3, 0x80
    stb     r3, 9(r1)
    lbz     r5, 9(r1)
    SAVE    r5
    lwzu    r5, 8(r4)            # misaligned word load (750 handles in hw), r4 = r1+18
    subf    r5, r1, r4
    SAVE    r5

    # --- lmw/stmw on a scratch block (r20..r27) ---
    li      r20, 20
    li      r21, 21
    li      r22, 22
    li      r23, 23
    li      r24, 24
    li      r25, 25
    li      r26, 26
    li      r27, 27
    addi    r4, r1, -64          # below the stack pointer is ok for a leaf block
    stmw    r20, 0(r4)
    li      r20, 0
    li      r27, 0
    lmw     r24, 16(r4)          # r24..r31 <- values stored above (r28..r31 unchanged)
    lwz     r5, 0(r4)
    lwz     r6, 28(r4)
    add     r5, r5, r6
    add     r5, r5, r24
    add     r5, r5, r27
    SAVE    r5

    # --- CTR branches ---
    li      r3, 10
    mtctr   r3
    li      r5, 0
1:  addi    r5, r5, 3
    bdnz    1b
    SAVE    r5
    mfctr   r5
    SAVE    r5
    li      r3, 5
    mtctr   r3
    li      r5, 0
2:  addi    r5, r5, 1
    cmpwi   r5, 3
    bdnzf   2, 2b                # stop when r5==3 or ctr hits 0
    mfctr   r6
    add     r5, r5, r6
    SAVE    r5
    lis     r3, 9f@ha
    addi    r3, r3, 9f@l
    mtctr   r3
    li      r5, 0
    bctrl
    addi    r5, r5, 1
    SAVE    r5
    li      r3, 1
    mtctr   r3
    bdz     3f                   # ctr 1->0: taken
    li      r5, 111
    b       4f
3:  li      r5, 222
4:  SAVE    r5
    b       done

9:  li      r5, 77               # bctrl target
    blr

done:
    subf    r3, r30, r31         # bytes written
    lmw     r14, 16(r1)
    lwz     r12, 88(r1)
    mtcrf   0xff, r12
    lwz     r0, 100(r1)
    mtlr    r0
    addi    r1, r1, 96
    blr

    .section .note.GNU-stack,"",@progbits
