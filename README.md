# g3core

An open 32-bit PowerPC core (G3/750-class), with the long-term goal of booting
classic Mac OS 9 on an FPGA. The design target is "what Mac OS accepts as a G3",
not a clone of the real 750's out-of-order microarchitecture.

## Status: phase 1 (pipelined integer core)

Two cores share one execute unit (`rtl/ppc_exec.sv`), so they implement
identical instruction semantics:

- `rtl/ppc_core.sv`: single-cycle reference core (stage 0), easy to read, the golden RTL model
- `rtl/ppc_pipe.sv`: 5-stage in-order pipeline (IF/ID/EX/MEM/WB) with full
  forwarding, a one-cycle load-use interlock, static branch prediction in ID
  (taken for `b`, unconditional `bc`/`blr`/`bctr`, and backward `bc`), and
  `lmw`/`stmw` sequenced one register per cycle

Verification, all passing:

| Check | What it compares |
|---|---|
| `make test` | both cores vs QEMU (`qemu-ppc -cpu 750`) on the C/asm test programs, then pipeline vs reference in lockstep |
| `make randtest` | random instruction programs: pipeline vs QEMU output, plus lockstep vs reference. 130 seeds x 2,000 instructions pass |

The lockstep checker compares every retired step (PC, instruction, register
writes, CR/XER/LR/CTR, store address/data) and prints the first divergence with
context. Planted bugs (wrong forwarding priority, wrong rotate mask) were caught
within a few seeds.

Pipeline CPI on the current tests (combinational memories, no caches yet):

| Test | CPI |
|---|---|
| arith | 1.11 |
| isa | 1.18 |
| hello | 1.20 |
| sort | 1.24 |

Implemented ISA: integer arithmetic (all carrying, extended, overflow and record
forms), multiply/divide, logical, shifts, rotates, `cntlzw`, `extsb`/`extsh`,
compares, all CR ops, `mcrf`, `mfcr`/`mtcrf`, `mcrxr`, all branch forms,
byte/half/word loads and stores (algebraic, update, indexed, byte-reversed),
`lmw`/`stmw`, `mfspr`/`mtspr` (XER, LR, CTR, SRR0/1, SPRG0-3, DEC, TB, PVR, HID0/1),
`mfmsr`/`mtmsr`, `mftb`.

Not yet implemented (the cores trap on these): FPU, MMU, exceptions/`rfi`/`sc`,
string ops, `lwarx`/`stwcx.`, `dcbz`, `tw`/`twi`.

## Layout

```
rtl/ppc_pkg.sv      shared helpers
rtl/ppc_exec.sv     decode + execute (combinational, shared by both cores)
rtl/ppc_core.sv     single-cycle reference core
rtl/ppc_pipe.sv     5-stage pipeline
rtl/soc_top.sv      simulation SoC: 1 MiB RAM, UART + exit MMIO at 0xF0000000; CORE=0/1 picks the core
rtl/lockstep_top.sv both SoCs side by side for trace comparison
sim/tb.cpp          Verilator driver (prints cycles, CPI, stalls, flushes)
sim/tb_lockstep.cpp lockstep trace checker
sw/rand/rand.c      driver for generated random tests
tools/gen_random.py random instruction-sequence generator
sw/common/          crt0, linker script, tiny printf, bare-metal + Linux backends
sw/tests/           test programs (C, plus optional same-named .S)
tools/difftest.sh   runs each test on a sim and under qemu-ppc, diffs output
tools/lockstep.sh   runs each test in lockstep
tools/randtest.sh   generate, build and check random tests
```

## Usage

Requires `verilator` (5.x), `gcc-powerpc-linux-gnu`, `qemu-user`.
On Ubuntu: `sudo apt install verilator gcc-powerpc-linux-gnu qemu-user`.
On macOS: `brew install verilator qemu`; the cross-compiler is easiest via a Linux VM or container.

```
make test          # build everything; QEMU diff for both cores + lockstep
make randtest      # 50 random programs (SEED=, N=, LEN= to change)
make run T=hello   # run one program on the pipeline simulator
```

Note: Verilator needs `-fno-case` (set in the Makefile); without it, 5.020
expands the nested decode `case` statements into ~44 MB of C++ and runs out of memory.

Every test is built twice from the same source: once for the bare-metal SoC
and once as a static Linux binary that runs under QEMU (the golden model). A
test passes when both produce identical output and exit codes.

## Roadmap

| Phase | Goal |
|---|---|
| **0** (done) | Single-cycle integer reference core, differential tests vs QEMU |
| **1** (done) | 5-stage in-order pipeline, forwarding, load-use interlock, static branch prediction, lockstep + random testing |
| 2 | Exceptions, MSR, `sc`/`rfi`, decrementer interrupt; MMU (BATs, segments, TLB with 603-style software reload); boot 32-bit Linux |
| 3 | FPU: IEEE double, fused multiply-add, FPSCR; pass IEEE test vectors |
| 4 | Caches, DDR3 (LiteDRAM), FPGA bring-up on Artix-7 |
| 5 | mac99-style platform (OpenPIC, MacIO/KeyLargo subset, framebuffer + NDRV), OpenBIOS, Mac OS 9 |

## Next steps (phase 2: exceptions and MMU)

1. Exception model: MSR, SRR0/SRR1, vectors at 0x000nn00 / 0xFFFnnn00, `sc`, `rfi`,
   program exception for illegal instructions (instead of halting), decrementer interrupt.
   Precise exceptions mean moving SPR commit to a single point (WB) or adding
   squash logic.
2. Supervisor tests: bare-metal programs that take and return from exceptions;
   QEMU system mode (`qemu-system-ppc -M g3beige` or a minimal board) as the golden model.
3. MMU: BATs, segment registers, hashed page table walk (or 603-style software
   TLB reload), ISI/DSI exceptions.
4. Milestone: boot a 32-bit PowerPC Linux kernel to a shell in simulation.
5. Optional performance work: branch target buffer, synchronous (BRAM-style) memories
   with a real fetch/load latency, then caches.
