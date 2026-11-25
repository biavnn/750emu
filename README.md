# g3core

An open 32-bit PowerPC core (G3/750-class), with the long-term goal of booting
classic Mac OS 9 on an FPGA. The design target is "what Mac OS accepts as a G3",
not a clone of the real 750's out-of-order microarchitecture.

## Status: phase 2b in progress (exceptions and MMU done; Linux boot next)

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
| `make test` (supervisor part) | bare-metal exception tests on both cores vs full-system QEMU (`qemu-system-ppc -M 40p -cpu 750`), plus lockstep |
| `make randtest` | random instruction programs: pipeline vs QEMU output, plus lockstep vs reference. 190 seeds x 2,000 instructions pass |

Supervisor tests (`sw/sys/`): `exc` (every exception type, user mode), `irq`
(decrementer interrupts at pseudo-random points under load), `mmu` (BATs, page
table, R/C bits, protection, faults, tlbie, segment switch), `vm` (all code and
data through the page table via two aliased mappings that keep evicting each
other from the TLBs, with interrupts).

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

Exception model (both cores, precise):
- MSR (EE, PR, FP, ME, FE0/1, SE, BE, IP, IR, DR, RI stored; EE, PR, FP, IP acted on), SRR0/SRR1, `rfi`, `sc`, `tw`/`twi`
- program exception for illegal, privileged (user mode) and trap, with the SRR1 reason bits
- FP unavailable (0x800) for FP instructions while MSR[FP]=0
- decrementer interrupt (latched when DEC passes zero, taken when EE=1) and an external interrupt input
- vectors at 0x000nnn00, or 0xFFFnnn00 with MSR[IP]=1

In simulation the time base and decrementer count executed steps, not clock
cycles, so both cores see the same timer values and interrupts land on the same
instruction; that is what lets the interrupt stress test run in lockstep. On an
FPGA they will count a real clock.

Known differences from QEMU 8.2's 750 model (tests avoid them):
- QEMU does not let `mtmsr` change MSR[ME]; g3core does (as real hardware).
- QEMU clears MSR[IP] on exception entry; g3core preserves it (as real hardware).

MMU (`rtl/ppc_mmu.sv`, shared by both cores):
- 4 instruction + 4 data BATs, 16 segment registers (`mtsr`/`mfsr`/`mtsrin`/`mfsrin`), SDR1
- hardware walk of the hashed page table (primary and secondary groups), with
  Referenced/Changed bit updates written back to the page table
- separate 64-entry direct-mapped instruction and data TLBs tagged by VSID, `tlbie`
- protection keys (Ks/Kp with PP), no-execute segments
- ISI (0x400) and DSI (0x300) with SRR1 / DSISR / DAR set as on the 750
- in the pipeline, fetches that miss the TLB or fault travel as markers and are
  resolved non-speculatively in EX; data addresses translate in EX; instructions
  that change the translation context flush younger fetches

MMU limitations: an access crossing a page boundary is translated by its first
byte only; direct-store segments fault; a faulting `stmw`/`lmw` may have
completed part of its work (allowed by the architecture; QEMU completes none).
QEMU also lets code execute from a page with no read access (key=1, PP=00);
g3core raises ISI as real hardware does.

Not yet implemented: FPU (FP instructions raise FP-unavailable or program
exceptions), machine check, trace/single-step, string ops, `lwarx`/`stwcx.`,
`dcbz` (these raise a program exception).

## Layout

```
rtl/ppc_pkg.sv      shared helpers
rtl/ppc_exec.sv     decode + execute (combinational, shared by both cores)
rtl/ppc_mmu.sv      BATs, segments, TLBs, page table walker
rtl/ppc_core.sv     single-cycle reference core
rtl/ppc_pipe.sv     5-stage pipeline
rtl/soc_top.sv      simulation SoC: 1 MiB RAM, UART + exit MMIO at 0xF0000000; CORE=0/1 picks the core
rtl/lockstep_top.sv both SoCs side by side for trace comparison
sim/tb.cpp          Verilator driver (prints cycles, CPI, stalls, flushes)
sim/tb_lockstep.cpp lockstep trace checker
sw/rand/rand.c      driver for generated random tests
tools/gen_random.py random instruction-sequence generator
sw/common/          crt0 + exception vectors, handler framework (exc.h), linker script, tiny printf, backends
sw/sys/             supervisor-mode tests (exceptions, user mode, interrupts)
sw/tests/           test programs (C, plus optional same-named .S)
tools/difftest.sh   runs each test on a sim and under qemu-ppc, diffs output
tools/lockstep.sh   runs each test in lockstep
tools/randtest.sh   generate, build and check random tests
tools/systest.sh    supervisor tests: both cores vs QEMU system, plus lockstep
tools/qemu_sys.py   runs a bare-metal ELF on QEMU's 750 (machine 40p), captures the UART
```

## Usage

Requires `verilator` (5.x), `gcc-powerpc-linux-gnu`, `qemu-user`, `qemu-system-ppc`.
On Ubuntu: `sudo apt install verilator gcc-powerpc-linux-gnu qemu-user qemu-system-ppc`.
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
| **2a** (done) | Exceptions: MSR, `sc`/`rfi`, program/trap/privilege, FP unavailable, decrementer + external interrupt, user mode |
| **2b** (MMU done) | BATs, segments, hardware page table walk, TLBs, DSI/ISI. Remaining: `lwarx`/`stwcx.`, `dcbz`, string ops, then boot 32-bit Linux |
| 3 | FPU: IEEE double, fused multiply-add, FPSCR; pass IEEE test vectors |
| 4 | Caches, DDR3 (LiteDRAM), FPGA bring-up on Artix-7 |
| 5 | mac99-style platform (OpenPIC, MacIO/KeyLargo subset, framebuffer + NDRV), OpenBIOS, Mac OS 9 |

## Next steps (rest of phase 2b: Linux)

1. Remaining integer instructions Linux needs: `lwarx`/`stwcx.`, `dcbz`,
   `lswi`/`lswx`/`stswi`/`stswx`, `eciwx`-class no-ops, `mfspr`/`mtspr` for the
   750's remaining SPRs (L2CR, ICTC, THRM, IABR, DABR, performance monitor) as
   stubs, alignment exception or full unaligned support across pages.
2. A minimal Linux platform in simulation: more RAM (sparse model in the
   testbench), UART (16550-compatible so stock drivers work), device tree,
   a small boot wrapper; faster simulation (Verilator threads, `-O3` tuning).
3. Boot a 32-bit PowerPC kernel with an initramfs to a shell; compare the
   early boot trace against QEMU where practical.
4. FPU (phase 3) can start in parallel: the kernel can run with FP emulation.
5. Performance: branch target buffer, synchronous (BRAM-style) memories, caches,
   2-way TLBs.
