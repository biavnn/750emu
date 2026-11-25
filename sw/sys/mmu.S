# Single-instruction memory accesses with labels, so page-fault handlers can
# report and skip the exact instruction.
    .text
    .globl peek, peek_insn, poke, poke_insn, peekb, peekb_insn
peek:                            # unsigned peek(unsigned *a)
peek_insn:
    lwz     r3, 0(r3)
    blr
poke:                            # void poke(unsigned *a, unsigned v)
poke_insn:
    stw     r4, 0(r3)
    blr
peekb:
peekb_insn:
    lbz     r3, 0(r3)
    blr

    .globl stmw_cross, stmw_insn
stmw_cross:                      # stmw of r29..r31 starting at address r3
    stwu    r1, -32(r1)
    stmw    r29, 16(r1)
    li      r29, 0x111
    li      r30, 0x222
    li      r31, 0x333
stmw_insn:
    stmw    r29, 0(r3)
    lmw     r29, 16(r1)
    addi    r1, r1, 32
    blr

# run_user(fn, arg): call fn(arg) in user mode; returns fn's result.
    .globl run_user, user_sc_ret
run_user:
    mflr    r0
    stw     r0, 4(r1)
    stwu    r1, -16(r1)
    mtsrr0  r3
    mfmsr   r5
    ori     r5, r5, 0x4000
    mtsrr1  r5
    lis     r5, user_back@ha
    addi    r5, r5, user_back@l
    mtlr    r5
    mr      r3, r4
    rfi
user_back:
    li      r0, 0x55
    sc
user_sc_ret:
    addi    r1, r1, 16
    lwz     r0, 4(r1)
    mtlr    r0
    blr

    .section .note.GNU-stack,"",@progbits
