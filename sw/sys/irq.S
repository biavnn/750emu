# Multi-cycle instructions for the interrupt stress test:
#   unsigned lmw_loop(unsigned n): stmw/lmw round trips, returns a checksum
    .text
    .globl lmw_loop
lmw_loop:
    stwu    r1, -160(r1)
    stmw    r14, 16(r1)          # save callee-saved registers
    mtctr   r3
    li      r3, 0
    li      r20, 1
    li      r21, 2
    li      r22, 3
    li      r23, 5
    li      r24, 8
    li      r25, 13
    li      r26, 21
    li      r27, 34
1:  stmw    r20, 96(r1)          # r20..r31 out
    add     r20, r20, r27
    lwz     r4, 96(r1)
    add     r3, r3, r4
    lmw     r21, 96(r1)          # shifted reload: r21<-old r20, r22<-old r21, ...
    lwz     r5, 100(r1)
    xor     r3, r3, r5
    add     r3, r3, r21
    rlwinm  r3, r3, 3, 0, 31
    bdnz    1b
    lmw     r14, 16(r1)
    addi    r1, r1, 160
    blr

    .section .note.GNU-stack,"",@progbits
