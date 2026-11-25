#!/usr/bin/env python3
"""Random instruction-sequence generator for differential testing.

Emits an assembly function `unsigned rnd_test(unsigned *out)` containing a
random mix of integer instructions (arithmetic with all OE/Rc variants,
logical, rotates, shifts, compares, CR ops, XER/LR/CTR moves, loads and
stores to a scratch buffer, forward conditional branches). Architectural
state is dumped to out[] at regular intervals. Nothing address-dependent is
ever observed, so the bare-metal build and the QEMU Linux build must agree.

    gen_random.py <seed> <n_instructions> <out.S>
"""
import random
import sys

seed, count, path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
R = random.Random(seed)

POOL = [0] + list(range(3, 13)) + list(range(14, 28))   # r28 update base, r29 temp, r30 out, r31 buffer
BUF = 256
DUMP_EVERY = 40


def reg():
    return f"r{R.choice(POOL)}"


def rnd32():
    return R.choice([0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, R.getrandbits(32),
                     R.getrandbits(32), R.getrandbits(8), (1 << R.randrange(32))])


def hi(v):
    """Upper half of v as a signed 16-bit immediate (what lis expects)."""
    return (((v >> 16) & 0xFFFF) ^ 0x8000) - 0x8000


def simm():
    return R.choice([0, 1, -1, -32768, 32767, R.randrange(-32768, 32768)])


def uimm():
    return R.choice([0, 0xFFFF, 0x8000, R.randrange(0, 65536)])


lines = []
emit = lines.append
label_id = 0


def gen_one(pending):
    """Emit one random instruction (or a short idiom). Returns number of insns."""
    global label_id
    k = R.random()
    if k < 0.22:
        op = R.choice(["add", "addc", "adde", "addme", "addze", "subf", "subfc", "subfe",
                       "subfme", "subfze", "neg", "mullw", "mulhw", "mulhwu"])
        o = "o" if op not in ("mulhw", "mulhwu") and R.random() < 0.3 else ""
        rc = "." if R.random() < 0.4 else ""
        if op in ("addme", "addze", "subfme", "subfze", "neg"):
            emit(f"    {op}{o}{rc} {reg()}, {reg()}")
        else:
            emit(f"    {op}{o}{rc} {reg()}, {reg()}, {reg()}")
    elif k < 0.27:
        o = "o" if R.random() < 0.3 else ""
        rc = "." if R.random() < 0.4 else ""
        if R.random() < 0.5:
            emit(f"    ori r29, {reg()}, 1")
            emit("    rlwinm r29, r29, 0, 1, 31")          # positive, odd: no /0, no INT_MIN/-1
            emit(f"    divw{o}{rc} {reg()}, {reg()}, r29")
        else:
            emit(f"    ori r29, {reg()}, 1")
            emit(f"    divwu{o}{rc} {reg()}, {reg()}, r29")
    elif k < 0.40:
        op = R.choice(["addi", "addis", "addic", "addic.", "subfic", "mulli"])
        ra = reg()
        if op in ("addi", "addis") and ra == "r0":
            ra = "0"                                    # RA=0 means literal zero for addi/addis
        emit(f"    {op} {reg()}, {ra}, {simm()}")
    elif k < 0.48:
        op = R.choice(["ori", "oris", "xori", "xoris", "andi.", "andis."])
        emit(f"    {op} {reg()}, {reg()}, {uimm()}")
    elif k < 0.60:
        op = R.choice(["and", "andc", "or", "nor", "xor", "nand", "eqv", "orc", "slw", "srw", "sraw"])
        rc = "." if R.random() < 0.4 else ""
        emit(f"    {op}{rc} {reg()}, {reg()}, {reg()}")
    elif k < 0.66:
        op = R.choice(["srawi", "cntlzw", "extsb", "extsh"])
        rc = "." if R.random() < 0.4 else ""
        if op == "srawi":
            emit(f"    srawi{rc} {reg()}, {reg()}, {R.randrange(32)}")
        else:
            emit(f"    {op}{rc} {reg()}, {reg()}")
    elif k < 0.74:
        op = R.choice(["rlwinm", "rlwnm", "rlwimi"])
        rc = "." if R.random() < 0.4 else ""
        mb, me = R.randrange(32), R.randrange(32)
        sh = reg() if op == "rlwnm" else R.randrange(32)
        emit(f"    {op}{rc} {reg()}, {reg()}, {sh}, {mb}, {me}")
    elif k < 0.79:
        crf = R.randrange(8)
        op = R.choice(["cmpw", "cmplw", "cmpwi", "cmplwi"])
        if op == "cmpwi":
            emit(f"    cmpwi cr{crf}, {reg()}, {simm()}")
        elif op == "cmplwi":
            emit(f"    cmplwi cr{crf}, {reg()}, {uimm()}")
        else:
            emit(f"    {op} cr{crf}, {reg()}, {reg()}")
    elif k < 0.84:
        c = R.random()
        if c < 0.5:
            op = R.choice(["crand", "cror", "crxor", "crnand", "crnor", "creqv", "crandc", "crorc"])
            emit(f"    {op} {R.randrange(32)}, {R.randrange(32)}, {R.randrange(32)}")
        elif c < 0.65:
            emit(f"    mcrf cr{R.randrange(8)}, cr{R.randrange(8)}")
        elif c < 0.8:
            emit(f"    mtcrf {R.randrange(256)}, {reg()}")
        elif c < 0.9:
            emit(f"    mfcr {reg()}")
        else:
            emit(f"    mcrxr cr{R.randrange(8)}")
    elif k < 0.88:
        c = R.random()
        if c < 0.3:
            emit(f"    lis r29, {hi(R.randrange(8) << 29)}")        # random SO/OV/CA
            emit("    mtxer r29")
        elif c < 0.45:
            emit(f"    mfxer {reg()}")
        elif c < 0.6:
            emit(f"    mtlr {reg()}")
        elif c < 0.7:
            emit(f"    mflr {reg()}")
        elif c < 0.85:
            emit(f"    mtctr {reg()}")
        else:
            emit(f"    mfctr {reg()}")
    elif k < 0.96:
        c = R.random()
        if c < 0.5:
            op, size = R.choice([("lwz", 4), ("lhz", 2), ("lha", 2), ("lbz", 1),
                                 ("stw", 4), ("sth", 2), ("stb", 1)])
            emit(f"    {op} {reg()}, {R.randrange(BUF - size + 1)}(r31)")
        elif c < 0.75:
            op, size = R.choice([("lwzx", 4), ("lhzx", 2), ("lhax", 2), ("lbzx", 1), ("stwx", 4),
                                 ("sthx", 2), ("stbx", 1), ("lwbrx", 4), ("lhbrx", 2),
                                 ("stwbrx", 4), ("sthbrx", 2)])
            emit(f"    li r29, {R.randrange(BUF - size + 1)}")
            emit(f"    {op} {reg()}, r31, r29")
        else:
            op, size = R.choice([("lwzu", 4), ("lhzu", 2), ("lhau", 2), ("lbzu", 1),
                                 ("stwu", 4), ("sthu", 2), ("stbu", 1)])
            base = R.randrange(BUF - size + 1)
            d = R.randrange(-base, BUF - size + 1 - base)
            emit(f"    addi r28, r31, {base}")
            emit(f"    {op} {reg()}, {d}(r28)")
            emit("    subf r28, r31, r28")                # observe the updated base as an offset
            emit(f"    mr {reg()}, r28")
    else:
        # forward conditional branch over 1-3 instructions
        label_id += 1
        lab = f".Lf{label_id}"
        bo = R.choice([12, 4, 20, 16, 18, 8, 0, 10, 2])
        emit(f"    bc {bo}, {R.randrange(32)}, {lab}")
        pending.append((lab, R.randrange(1, 4)))
        return


def main():
    emit("# generated by tools/gen_random.py seed=%d n=%d" % (seed, count))
    emit("    .text\n    .globl rnd_test\nrnd_test:")
    emit("    stwu r1, -96(r1)\n    mflr r0\n    stw r0, 100(r1)\n    stmw r14, 16(r1)")
    emit("    mfcr r12\n    stw r12, 88(r1)")
    emit("    mr r30, r3")
    emit("    stw r30, 8(r1)")                             # remember start of out[]
    emit("    lis r31, rnd_buf@ha\n    addi r31, r31, rnd_buf@l")
    for i in range(BUF // 4):                              # random scratch contents
        v = R.getrandbits(32)
        emit(f"    lis r29, {hi(v)}\n    ori r29, r29, {v & 0xFFFF}\n    stw r29, {4 * i}(r31)")
    for r in POOL:
        v = rnd32()
        emit(f"    lis r{r}, {hi(v)}\n    ori r{r}, r{r}, {v & 0xFFFF}")
    v = R.getrandbits(32)
    emit(f"    lis r29, {hi(v)}\n    ori r29, r29, {v & 0xFFFF}\n    mtcrf 0xff, r29")
    emit("    li r29, 0\n    mtxer r29\n    mtctr r29\n    mtlr r29")

    pending = []
    for i in range(count):
        gen_one(pending)
        # resolve forward branch labels
        for j in range(len(pending) - 1, -1, -1):
            lab, n = pending[j]
            if n == 0:
                emit(f"{lab}:")
                pending.pop(j)
            else:
                pending[j] = (lab, n - 1)
        if (i + 1) % DUMP_EVERY == 0 or i == count - 1:
            for lab, _ in pending:
                emit(f"{lab}:")
            pending.clear()
            for n, r in enumerate(POOL):
                emit(f"    stw r{r}, {4 * n}(r30)")
            base = 4 * len(POOL)
            for n, spr in enumerate(["mfcr", "mfxer", "mfctr", "mflr"]):
                emit(f"    {spr} r29\n    stw r29, {base + 4 * n}(r30)")
            emit(f"    addi r30, r30, {base + 16}")
    # also dump the scratch buffer
    emit(f"    li r29, {BUF // 4}\n    mtctr r29\n    addi r28, r31, -4\n    addi r27, r30, -4")
    emit("1:  lwzu r29, 4(r28)\n    stwu r29, 4(r27)\n    bdnz 1b")
    emit(f"    addi r30, r30, {BUF}")
    emit("    lwz r3, 8(r1)\n    subf r3, r3, r30")
    emit("    lmw r14, 16(r1)\n    lwz r12, 88(r1)\n    mtcrf 0xff, r12")
    emit("    lwz r0, 100(r1)\n    mtlr r0\n    addi r1, r1, 96\n    blr")
    emit("    .bss\n    .align 4\nrnd_buf: .space %d" % BUF)
    emit('    .section .note.GNU-stack,"",@progbits')
    open(path, "w").write("\n".join(lines) + "\n")


main()
