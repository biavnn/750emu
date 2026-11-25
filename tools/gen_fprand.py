#!/usr/bin/env python3
"""Random floating-point test generator.

Emits `unsigned fp_rand(unsigned *out)`: a random sequence of FP arithmetic,
fused multiply-add, compares, conversions, moves and single-precision
load/store, over a pool of awkward operands (zeros, infinities, quiet and
signalling NaNs, denormals, values at the edges of single and double range,
rounding ties) in all four rounding modes. After every instruction the
destination register, the FPSCR and the CR are written to out[].

FPSCR[FR] is masked out of the dump: QEMU, the reference, does not model it.

    gen_fprand.py <seed> <n_ops> <out.S>
"""
import random, struct, sys

seed, count, path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
R = random.Random(seed)

SPECIAL = [
    0x0000000000000000, 0x8000000000000000, 0x7FF0000000000000, 0xFFF0000000000000,
    0x7FF8000000000000, 0xFFF8000000000001, 0x7FF0000000000001, 0xFFF4000000000000,
    0x7FF8DEADBEEF1234, 0x3FF0000000000000, 0xBFF0000000000000, 0x4000000000000000,
    0x3FE0000000000000, 0x4008000000000000, 0x7FEFFFFFFFFFFFFF, 0xFFEFFFFFFFFFFFFF,
    0x0010000000000000, 0x000FFFFFFFFFFFFF, 0x0000000000000001, 0x8000000000000001,
    0x0010000000000001, 0x001FFFFFFFFFFFFF, 0x47EFFFFFE0000000, 0x47EFFFFFF0000000,
    0x36A0000000000000, 0x3690000000000000, 0x3810000000000000, 0x380FFFFFC0000000,
    0x3FF0000010000000, 0x3FF0000030000000, 0x3FF0000010000001, 0x3FEFFFFFFFFFFFFF,
    0x41E0000000000000, 0x41DFFFFFFFE00000, 0xC1E0000000000000, 0x41DFFFFFFFC00000,
    0xC1E0000000100000, 0x3FE0000000000000, 0x3FF8000000000000, 0x4004000000000000,
    0xC004000000000000, 0x3FDFFFFFFFFFFFFF, 0x4330000000000000, 0x433FFFFFFFFFFFFF,
    0x3CA0000000000000, 0x3C90000000000000, 0x7FE0000000000000, 0x0020000000000000,
]


def rnd_double():
    k = R.random()
    if k < 0.35:
        return R.choice(SPECIAL)
    sign = R.getrandbits(1) << 63
    if k < 0.65:    # moderate exponents so sums and products interact
        exp = 1023 + R.randrange(-60, 61)
    elif k < 0.75:  # near single-precision limits
        exp = 1023 + R.choice([-150, -149, -127, -126, -125, 126, 127, 128]) + R.randrange(-1, 2)
    elif k < 0.85:  # near double-precision limits
        exp = R.choice([1, 2, 3, 52, 53, 54, 2044, 2045, 2046])
    else:
        exp = R.randrange(0, 2048)
    mant = R.choice([0, 1, (1 << 52) - 1, 1 << 51, R.getrandbits(52), R.getrandbits(52),
                     R.getrandbits(23) << 29, (R.getrandbits(23) << 29) | (1 << 28)])
    return sign | (exp << 52) | mant


POOL = [rnd_double() for _ in range(96)]
NREG = 12              # f0..f11 are working registers; f12 = 0.0; f13 = scratch

L = []
emit = L.append


def fr():
    return f"f{R.randrange(NREG)}"


def const(v):
    """Offset of a constant in the pool (added on demand)."""
    POOL.append(v & 0xFFFFFFFFFFFFFFFF)
    return 8 * (len(POOL) - 1)


def dbl(sign, exp, mant):
    return (sign << 63) | ((exp + 1023) << 52) | (mant & ((1 << 52) - 1))


def directed():
    """Operands built to land exactly on rounding boundaries and range edges."""
    sgn = R.getrandbits(1)
    k = R.randrange(8)
    if k == 0:      # round-to-single ties and near-ties
        m = (R.getrandbits(23) << 29) | (1 << 28) | R.choice([0, 0, 1, 1 << 27])
        a = dbl(sgn, R.randrange(-120, 120), m)
        return [("lfd", "f0", a)], R.choice(["frsp {d}, f0", "fadds {d}, f0, f12", "fmuls {d}, f0, f1|1"])
    if k == 1:      # double addition ties: x + half an ulp (or a hair more or less)
        e = R.randrange(-900, 900)
        a = dbl(sgn, e, R.getrandbits(52))
        b = dbl(R.getrandbits(1), e - 53, R.choice([0, 0, 1, 1 << 51])) if R.random() < 0.8 else dbl(sgn, e - 54, 0)
        return [("lfd", "f0", a), ("lfd", "f1", b)], R.choice(["fadd {d}, f0, f1", "fsub {d}, f0, f1", "fadd {d}, f1, f0"])
    if k == 2:      # single addition ties
        e = R.randrange(-100, 100)
        a = dbl(sgn, e, R.getrandbits(23) << 29)
        b = dbl(R.getrandbits(1), e - 24, R.choice([0, 0, 1 << 29, 1]))
        return [("lfd", "f0", a), ("lfd", "f1", b)], R.choice(["fadds {d}, f0, f1", "fsubs {d}, f0, f1"])
    if k == 3:      # results in and around the single denormal range
        a = dbl(sgn, R.randrange(-152, -122), R.choice([0, R.getrandbits(52), (R.getrandbits(23) << 29) | (1 << 28)]))
        b = dbl(0, R.randrange(-3, 4), R.choice([0, R.getrandbits(52)]))
        return [("lfd", "f0", a), ("lfd", "f1", b)], R.choice(["frsp {d}, f0", "fmuls {d}, f0, f1", "fdivs {d}, f0, f1", "fadds {d}, f0, f0"])
    if k == 4:      # results in and around the double denormal range
        e1 = R.randrange(-1000, -100)
        a = dbl(sgn, e1, R.getrandbits(52))
        b = dbl(0, R.randrange(-1080, -1018) - e1, R.choice([0, R.getrandbits(52)]))
        return [("lfd", "f0", a), ("lfd", "f1", b)], R.choice(["fmul {d}, f0, f1", "fmadd {d}, f0, f1, f12", "fdiv {d}, f0, f2|inv"])
    if k == 5:      # overflow edges
        e1 = R.randrange(100, 1000)
        a = dbl(sgn, e1, R.choice([(1 << 52) - 1, R.getrandbits(52)]))
        b = dbl(0, R.choice([1023, 1024, 127, 128]) - e1 + R.randrange(-1, 2), R.choice([0, (1 << 52) - 1, R.getrandbits(52)]))
        return [("lfd", "f0", a), ("lfd", "f1", b)], R.choice(["fmul {d}, f0, f1", "fmuls {d}, f0, f1"])
    if k == 6:      # exact residual of a product, via fused multiply-subtract
        a = dbl(sgn, R.randrange(-30, 30), R.getrandbits(52))
        b = dbl(0, R.randrange(-30, 30), R.getrandbits(52))
        return [("lfd", "f0", a), ("lfd", "f1", b), ("op", "fmul f2, f0, f1", 0)], R.choice(
            ["fmsub {d}, f0, f1, f2", "fmadd {d}, f0, f1, f2", "fmsubs {d}, f0, f1, f2"])
    # integer conversion ties and limits
    n = R.choice([0, 1, 2, 3, 2**31 - 1, 2**31 - 2, 2**31, 2**30, R.getrandbits(20), R.getrandbits(31)])
    v = n + R.choice([0.5, 0.5, 0.25, 0.75, 0.0, 0.4999999, 0.5000001])
    a = struct.unpack(">Q", struct.pack(">d", -v if sgn else v))[0]
    return [("lfd", "f0", a)], R.choice(["fctiw {d}, f0", "fctiwz {d}, f0"])


def dump(dst, mask="r7"):
    emit(f"    stfd {dst}, 0(r3)")
    emit(f"    mffs f13\n    stfd f13, 8(r1)\n    lwz r6, 12(r1)\n    and r6, r6, {mask}\n    stw r6, 8(r3)")
    emit("    mfcr r6\n    stw r6, 12(r3)\n    addi r3, r3, 16")


emit(f"# generated by tools/gen_fprand.py seed={seed} n={count}")
emit("    .text\n    .globl fp_rand\nfp_rand:")
emit("    stwu r1, -48(r1)\n    mr r9, r3\n    mfcr r10\n    stw r10, 32(r1)\n    li r6, 0\n    mtcrf 0xff, r6")
emit("    lis r4, fp_pool@ha\n    addi r4, r4, fp_pool@l")
emit("    lis r7, 0xFFFB\n    ori r7, r7, 0xFFFF")            # mask off FPSCR[FR]
emit("    lis r8, 0xFFFA\n    ori r8, r8, 0xFFFF")            # ... and the class bit C, after compares
emit("    li r6, 0\n    stw r6, 16(r1)\n    stw r6, 20(r1)\n    lfd f12, 16(r1)\n    mtfsf 0xff, f12")
for i in range(NREG):
    emit(f"    lfd f{i}, {8 * R.randrange(len(POOL))}(r4)")

cur_rn = 0
for opn in range(count):
    emit(f"# op {opn}")
    cmp_op = clear_after = False
    k = R.random()
    d = fr()
    rc = "." if R.random() < 0.15 else ""
    if k < 0.22:
        setup, tmpl = directed()
        for kind, x, v in setup:
            emit(f"    lfd {x}, {const(v)}(r4)" if kind == "lfd" else f"    {x}")
        if "|1" in tmpl:
            emit(f"    lfd f1, {const(0x3FF0000000000000)}(r4)")
            tmpl = tmpl.replace("|1", "")
        if "|inv" in tmpl:      # divide by the reciprocal power of two instead of multiplying
            emit(f"    lfd f2, {const(0x3FF0000000000000)}(r4)\n    fdiv f2, f2, f1")
            tmpl = tmpl.replace("|inv", "")
        emit("    " + tmpl.format(d=d))
    elif k < 0.40:
        op = R.choice(["fadd", "fsub", "fmul", "fdiv"]) + ("s" if R.random() < 0.35 else "")
        emit(f"    {op}{rc} {d}, {fr()}, {fr()}")
    elif k < 0.55:
        # fnmadd/fnmsub round first and then negate. QEMU negates before rounding, which
        # differs in the two directed modes, so the negated forms are only generated in
        # the sign-symmetric modes.
        names = ["fmadd", "fmsub", "fnmadd", "fnmsub"] if cur_rn < 2 else ["fmadd", "fmsub"]
        op = R.choice(names) + ("s" if R.random() < 0.35 else "")
        emit(f"    {op}{rc} {d}, {fr()}, {fr()}, {fr()}")
    elif k < 0.60:
        emit(f"    {R.choice(['frsp', 'fctiw', 'fctiwz'])}{rc} {d}, {fr()}")
    elif k < 0.65:
        # Compares: hardware leaves FPSCR[FI] and the class bit C alone; QEMU clears FI
        # and rewrites C. Clear FI first, ignore C in this dump and clear it afterwards.
        emit("    mtfsb0 14")
        cmp_op = True
        emit(f"    {R.choice(['fcmpu', 'fcmpo'])} cr{R.randrange(8)}, {fr()}, {fr()}")
    elif k < 0.68:
        emit(f"    fsel {d}, {fr()}, {fr()}, {fr()}")
    elif k < 0.71:
        emit(f"    {R.choice(['fmr', 'fneg', 'fabs', 'fnabs'])} {d}, {fr()}")
    elif k < 0.80:
        emit(f"    lfd {d}, {8 * R.randrange(len(POOL))}(r4)")
    elif k < 0.86:
        emit(f"    stfs {fr()}, 24(r1)\n    lfs {d}, 24(r1)")
    elif k < 0.90:
        emit(f"    lfs {d}, {4 * R.randrange(2 * len(POOL))}(r4)")     # arbitrary bits read as a single
    elif k < 0.95:
        cur_rn = R.randrange(4)
        emit(f"    mtfsfi 7, {cur_rn}")                                # rounding mode
    elif k < 0.98:
        # (field 3 holds FR, which QEMU does not model)
        emit(f"    mcrfs cr{R.randrange(8)}, {R.choice([0, 1, 2, 4, 5])}")
        clear_after = True
    else:
        emit("    mtfsf 0xff, f12")                                    # clear the FPSCR
        cur_rn = 0
    dump(d, "r8" if cmp_op else "r7")
    if cmp_op:
        emit("    mtfsb0 15")
    if clear_after:
        # QEMU sets FX every time an exception occurs; hardware only when an exception
        # bit goes from 0 to 1. Start from a clean FPSCR after FX may have been cleared.
        emit(f"    mtfsf 0xff, f12\n    mtfsfi 7, {cur_rn}")

emit("    mtfsf 0xff, f12")
emit("    lwz r10, 32(r1)\n    mtcrf 0xff, r10\n    subf r3, r9, r3\n    addi r1, r1, 48\n    blr")
emit("    .section .rodata\n    .align 3\nfp_pool:")
for v in POOL:
    emit(f"    .long 0x{v >> 32:08x}, 0x{v & 0xFFFFFFFF:08x}")
emit('    .section .note.GNU-stack,"",@progbits')
open(path, "w").write("\n".join(L) + "\n")
