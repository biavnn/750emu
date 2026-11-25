# Bare-metal startup and exception vectors for g3core.
# The image is linked at 0, so the vectors sit at their architectural
# addresses (MSR[IP]=0). Reset enters at 0x100.

    .macro VECTOR addr
    .org \addr
    stwu    r1, -96(r1)          # exception frame (struct exc_frame in exc.h)
    stw     r0, 8(r1)
    stw     r3, 16(r1)
    li      r3, \addr
    b       exc_common
    .endm

    .section .vectors, "ax"
    .org 0x100
    .globl _reset
_reset:
    b       _start
    VECTOR 0x200                 # machine check
    VECTOR 0x300                 # DSI
    VECTOR 0x400                 # ISI
    VECTOR 0x500                 # external interrupt
    VECTOR 0x600                 # alignment
    VECTOR 0x700                 # program
    VECTOR 0x800                 # FP unavailable
    VECTOR 0x900                 # decrementer
    VECTOR 0xC00                 # system call
    VECTOR 0xD00                 # trace
    VECTOR 0x1300                # instruction address breakpoint
    VECTOR 0x1400                # system management
    VECTOR 0x1700                # thermal management

    .text
    .globl _start
_start:
    li      r0, 0x0002           # MSR: RI only (IP=0, interrupts off, supervisor)
    mtmsr   r0
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

# Save volatile state, call exc_dispatch(vec, frame), restore, return.
exc_common:
    stw     r2, 12(r1)
    stw     r4, 20(r1)
    stw     r5, 24(r1)
    stw     r6, 28(r1)
    stw     r7, 32(r1)
    stw     r8, 36(r1)
    stw     r9, 40(r1)
    stw     r10, 44(r1)
    stw     r11, 48(r1)
    stw     r12, 52(r1)
    mflr    r4
    stw     r4, 56(r1)
    mfctr   r4
    stw     r4, 60(r1)
    mfxer   r4
    stw     r4, 64(r1)
    mfcr    r4
    stw     r4, 68(r1)
    mfsrr0  r4
    stw     r4, 72(r1)
    mfsrr1  r4
    stw     r4, 76(r1)
    stw     r3, 80(r1)
    mr      r4, r1
    bl      exc_dispatch
    lwz     r4, 56(r1)
    mtlr    r4
    lwz     r4, 60(r1)
    mtctr   r4
    lwz     r4, 64(r1)
    mtxer   r4
    lwz     r4, 68(r1)
    mtcrf   0xff, r4
    lwz     r4, 72(r1)
    mtsrr0  r4
    lwz     r4, 76(r1)
    mtsrr1  r4
    lwz     r2, 12(r1)
    lwz     r4, 20(r1)
    lwz     r5, 24(r1)
    lwz     r6, 28(r1)
    lwz     r7, 32(r1)
    lwz     r8, 36(r1)
    lwz     r9, 40(r1)
    lwz     r10, 44(r1)
    lwz     r11, 48(r1)
    lwz     r12, 52(r1)
    lwz     r3, 16(r1)
    lwz     r0, 8(r1)
    addi    r1, r1, 96
    rfi

    .section .note.GNU-stack,"",@progbits
