# Boot stub: what a boot loader would do. Linked at BOOT_ADDR; the flat kernel
# image sits at physical 0 and the device tree blob at DTB_ADDR.
    .globl _start
_start:
    li      0, 0
    mtmsr   0                    # real mode, interrupts off, vectors at 0
    isync
.ifdef QEMU_40P
    # QEMU's 40p has an i8259 whose timer line would raise external interrupts
    # that this kernel has no controller driver for: mask every line.
    lis     9, 0x8000
    li      0, 0xFF
    stb     0, 0x21(9)
    stb     0, 0xA1(9)
.endif
    lis     3, DTB_ADDR@h        # r3 = flattened device tree
    ori     3, 3, DTB_ADDR@l
    li      4, 0                 # r4 = kernel load address
    lis     1, STACK_ADDR@h      # the kernel's first C code needs a small stack
    ori     1, 1, STACK_ADDR@l
    li      5, 0
    li      6, 0
    li      7, 0
    mtctr   4
    bctr
