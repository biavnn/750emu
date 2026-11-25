# Instruction sequences that deliberately raise exceptions. Each faulting
# instruction has a global label so the C side can report where SRR0 points.

    .text
    .globl do_sc, sc_ret
do_sc:                           # do_sc(n): system call with r0 = n
    mr      r0, r3
    sc
sc_ret:
    blr

    .globl do_illegal, ill_insn
do_illegal:
ill_insn:
    .long   0x00000000           # not a valid instruction
    blr

    .globl do_fp, fp_insn
do_fp:
fp_insn:
    fmr     f1, f1               # MSR[FP]=0 -> FP unavailable
    blr

    .globl do_twi_always, do_tw_lt, do_tw_gtu, do_twi_eq5
    .globl trap1, trap2, trap3, trap4
do_twi_always:
trap1:
    twi     31, r3, 0
    blr
do_tw_lt:                        # trap if (int)a < (int)b
trap2:
    tw      16, r3, r4
    blr
do_tw_gtu:                       # trap if a > b unsigned
trap3:
    tw      1, r3, r4
    blr
do_twi_eq5:                      # trap if a == 5
trap4:
    twi     4, r3, 5
    blr

# run_user(fn): call fn in user mode (MSR[PR]=1). fn returns with blr to
# user_back, which makes system call 0x55; the C handler clears PR in SRR1 so
# execution continues here in supervisor mode.
    .globl run_user, user_sc_ret
run_user:
    mflr    r0
    stw     r0, 4(r1)
    stwu    r1, -16(r1)
    mtsrr0  r3
    mfmsr   r4
    ori     r4, r4, 0x4000
    mtsrr1  r4
    lis     r4, user_back@ha
    addi    r4, r4, user_back@l
    mtlr    r4
    rfi
user_back:
    li      r0, 0x55
    sc
user_sc_ret:
    addi    r1, r1, 16
    lwz     r0, 4(r1)
    mtlr    r0
    blr

    .globl user_code, u_mfmsr, u_mtmsr, u_mtsrr0, u_mfsprg, u_rfi, u_ill
user_code:
    li      r3, 100
u_mfmsr:
    mfmsr   r3                   # privileged
    addi    r3, r3, 1
u_mtmsr:
    mtmsr   r3                   # privileged
    addi    r3, r3, 1
u_mtsrr0:
    mtsrr0  r3                   # privileged SPR
    addi    r3, r3, 1
u_mfsprg:
    mfsprg  r3, 0                # privileged SPR
    addi    r3, r3, 1
u_rfi:
    rfi                          # privileged
    addi    r3, r3, 1
u_ill:
    .long   0x00000000           # illegal, in user mode
    mfxer   r4                   # user-accessible SPRs are fine
    mflr    r4
    mfctr   r4
    addi    r3, r3, 1
    blr

    .section .note.GNU-stack,"",@progbits
