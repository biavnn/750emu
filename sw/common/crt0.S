# Bare-metal startup for g3core. The core resets at 0x100 (system reset vector, MSR[IP]=0).

    .section .reset, "ax"
    .globl _reset
_reset:
    b       _start

    .text
    .globl _start
_start:
    lis     r1, __stack_top@ha
    addi    r1, r1, __stack_top@l
    li      r0, 0
    stwu    r0, -16(r1)          # terminate the stack back-chain

    lis     r3, __bss_start@ha   # zero .bss
    addi    r3, r3, __bss_start@l
    lis     r4, __bss_end@ha
    addi    r4, r4, __bss_end@l
1:  cmplw   r3, r4
    bge     2f
    stw     r0, 0(r3)
    addi    r3, r3, 4
    b       1b

2:  li      r2, 0
    li      r13, 0
    bl      main
    bl      texit                # exit code = main's return value
3:  b       3b

    .section .note.GNU-stack,"",@progbits
