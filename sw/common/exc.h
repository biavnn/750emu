// Exception handling for bare-metal g3core programs.
#ifndef EXC_H
#define EXC_H

// Layout must match the save/restore code in crt0.S.
struct exc_frame {
    unsigned backchain, lrsave;
    unsigned r0, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12;
    unsigned lr, ctr, xer, cr;
    unsigned srr0, srr1;      // handlers may modify these to change where/how execution resumes
    unsigned vec;
};

typedef void (*exc_handler_t)(struct exc_frame *f);

// vec is the vector offset (0x700 = program, 0x900 = decrementer, 0xC00 = sc, ...)
void exc_set_handler(unsigned vec, exc_handler_t h);

#endif
