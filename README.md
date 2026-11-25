# g3core

An open 32-bit PowerPC core (G3/750-class), with the long-term goal of booting
classic Mac OS 9 on an FPGA. The design target is "what Mac OS accepts as a G3",
not a clone of the real 750's out-of-order microarchitecture.

## Status: phases 2 and 3 done in simulation (Linux boots; FPU implemented)

An unmodified Linux 6.8 kernel (plus a 90-line platform file, see `linux/`)
boots on the pipelined core in simulation, mounts its initramfs, runs a small
user-space program that makes system calls and sleeps on the timer, and powers
off: about 21 million instructions and 29 million cycles. The user program
also uses floating point, which exercises the kernel's lazy FPU switching. The console log is in `docs/linux-boot.log`. `make linux-test`
boots the same image on QEMU's 750 and on the pipeline, compares what user
space printed, and then runs the whole boot with the pipeline and the
reference core in lockstep (22.8 million steps match).

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
| `make fprandtest` | random and boundary-directed floating-point programs: pipeline vs QEMU after every instruction, plus lockstep |
| `make randtest` | random instruction programs (now including string ops, `dcbz`, `lwarx`/`stwcx.`): pipeline vs QEMU output, plus lockstep vs reference. 230 seeds x 2,000 instructions pass |

Supervisor tests (`sw/sys/`): `exc` (every exception type, user mode), `irq`
(decrementer interrupts at pseudo-random points under load), `mmu` (BATs, page
table, R/C bits, protection, faults, tlbie, segment switch), `vm` (all code and
data through the page table via two aliased mappings that keep evicting each
other from the TLBs, with interrupts), `insn` (atomics, `dcbz`, string ops,
page-crossing loads and stores including a missing second page), `fp` (FP
register moves, load/store forms, FPSCR). `sw/tests/fp.c` is compiled C
floating-point code (series, Newton iterations, conversions).

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
`mfmsr`/`mtmsr`, `mftb`, `lwarx`/`stwcx.`, `dcbz` (32-byte blocks), string ops
(`lswi`/`lswx`/`stswi`/`stswx`), and storage-only versions of the 750's cache,
thermal, breakpoint and performance-monitor registers.

Multi-step instructions (`lmw`/`stmw`, `dcbz`, string ops) run on a small
sequencer in the execute unit, one memory access per step. The same sequencer
splits an ordinary unaligned load or store that straddles a page boundary into
byte steps, so each page is translated and can fault on its own.

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

MMU limitations: a misaligned `lmw`/`stmw` word that crosses a page boundary is
translated by its first byte only; direct-store segments fault; a faulting
multi-step instruction or page-crossing store may have completed part of its
work (allowed by the architecture; QEMU completes none). `stwcx.` succeeds only
at the address of the preceding `lwarx` (a real 750 checks just the reservation
flag); exceptions do not clear the reservation.
QEMU also lets code execute from a page with no read access (key=1, PP=00);
g3core raises ISI as real hardware does.

Floating point (`rtl/ppc_fpu.sv`, IEEE 754 with PowerPC semantics):
- `fadd`/`fsub`/`fmul`/`fdiv` and the fused `fmadd`/`fmsub`/`fnmadd`/`fnmsub`,
  each in double and single precision, exact with a single rounding
- `frsp`, `fctiw`/`fctiwz`, `fcmpu`/`fcmpo`, `fsel`, `fmr`/`fneg`/`fabs`/`fnabs`
- `lfs`/`stfs`/`lfd`/`stfd` in all addressing forms, `stfiwx`
- FPSCR: all four rounding modes, the sticky exception bits (overflow,
  underflow, zero-divide, inexact and the invalid-operation causes), FX/FEX/VX,
  FI, the result class (FPRF), `mffs`/`mtfsf`/`mtfsfi`/`mtfsb0`/`mtfsb1`/`mcrfs`,
  and the record (`.`) forms that copy FPSCR bits to CR1
- the 32 FPRs live in the same register file as the GPRs as 32-bit halves; an
  FP instruction takes 2 or 3 sequencer steps (operands, compute, second word)

Checked with `make fprandtest`: random FP programs plus operands constructed to
land on rounding ties, denormal and overflow boundaries, in all rounding modes,
compared with QEMU after every instruction (result bits, FPSCR, CR). Over
80,000 FP operations pass.

FP limitations and known differences from QEMU 8.2:
- `fres`, `frsqrte`, `fsqrt` are not implemented (program exception); the 750
  has no `fsqrt`, and the two estimate instructions are rarely used.
- Enabled FP exceptions do not trap (FE0/FE1 are stored but ignored) and the
  result is always the "exception disabled" one.
- FPSCR[FR] is implemented but unverified: QEMU does not model it, so the tests
  mask it.
- `fnmadd`/`fnmsub` round and then negate, as the architecture specifies. QEMU
  negates before rounding, which differs in the two directed rounding modes.
- FX is set only when an exception bit goes from 0 to 1 (QEMU sets it on every
  exception); compares leave FI and the class bit C alone (QEMU rewrites them).
- The upper word of an `fctiw` result and FPRF after an invalid conversion are
  undefined by the architecture; g3core gives the same values as QEMU.
- The FPU is one large combinational block (a 106-bit multiplier, a 224-bit
  adder and a divider); it must become iterative before it can meet timing on
  an FPGA, and it currently slows the Verilator model by about 3x.

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

MMU limitations: a misaligned `lmw`/`stmw` word that crosses a page boundary is
translated by its first byte only; direct-store segments fault; a faulting
multi-step instruction or page-crossing store may have completed part of its
work (allowed by the architecture; QEMU completes none). `stwcx.` succeeds only
at the address of the preceding `lwarx` (a real 750 checks just the reservation
flag); exceptions do not clear the reservation.
QEMU also lets code execute from a page with no read access (key=1, PP=00);
g3core raises ISI as real hardware does.

Floating point so far (the part an OS needs to manage FP state): the 32 FPRs,
FPSCR, `lfd`/`stfd` in all addressing forms, `stfiwx`, `fmr`/`fneg`/`fabs`/
`fnabs`, `mffs`/`mtfsf`/`mtfsfi`/`mtfsb0`/`mtfsb1`. FP arithmetic, compares,
conversions and single-precision load/store raise a program exception, so user
programs that use floating point do not work yet. The FPRs live in the same
register file as the GPRs as 32-bit halves.

Not yet implemented: machine check, trace/single-step, alignment exception.

## Layout

```
rtl/ppc_pkg.sv      shared helpers
rtl/ppc_exec.sv     decode + execute (combinational, shared by both cores)
rtl/ppc_fpu.sv      floating-point unit
rtl/ppc_mmu.sv      BATs, segments, TLBs, page table walker
rtl/ppc_core.sv     single-cycle reference core
rtl/ppc_pipe.sv     5-stage pipeline
rtl/soc_top.sv      simulation SoC: 1 MiB RAM, UART + exit MMIO at 0xF0000000; CORE=0/1 picks the core
rtl/lockstep_top.sv both SoCs side by side for trace comparison
sim/tb.cpp          Verilator driver (prints cycles, CPI, stalls, flushes)
sim/tb_lockstep.cpp lockstep trace checker
sw/rand/rand.c      driver for generated random tests
tools/gen_random.py random instruction-sequence generator
tools/gen_fprand.py random and boundary-directed floating-point test generator
sw/common/          crt0 + exception vectors, handler framework (exc.h), linker script, tiny printf, backends
sw/sys/             supervisor-mode tests (exceptions, user mode, interrupts)
sw/tests/           test programs (C, plus optional same-named .S)
tools/difftest.sh   runs each test on a sim and under qemu-ppc, diffs output
tools/lockstep.sh   runs each test in lockstep
tools/randtest.sh   generate, build and check random tests
tools/systest.sh    supervisor tests: both cores vs QEMU system, plus lockstep
tools/qemu_sys.py   runs a bare-metal ELF on QEMU's 750 (machine 40p), captures the UART
linux/              Linux bring-up: platform file, device trees, boot stub, init, build script
tools/linuxtest.sh  boots Linux on QEMU and both simulators and compares
tools/linux_qemu.py runs the Linux image on QEMU's 750
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

### Linux

```
sudo apt install linux-source flex bison bc device-tree-compiler libssl-dev libelf-dev
tar xf /usr/src/linux-source-6.8.0.tar.bz2 -C ..
linux/build.sh ../linux-source-6.8.0 ../linux-build/out   # ~10 minutes on 2 cores
make linux-test LINUX_OUT=../linux-build/out
```

`linux/build.sh` copies `linux/g3core.c` into the kernel tree as a new
embedded6xx platform, configures from `tinyconfig` plus `linux/g3core.config`,
builds `vmlinux` with `linux/init.c` as the only user-space program, and
assembles a flat RAM image (kernel at 0, device tree at 0x01E00000, boot stub
at 0x01F00000). The simulated SoC for Linux has 32 MiB of RAM and a
transmit-only 16550 UART at 0xF0001000 used in polling mode; there is no
interrupt controller, only the decrementer. In simulation the time base counts
instructions, and the device tree declares 2 MHz, so "kernel time" is not wall
time.

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
| **2b** (done) | BATs, segments, hardware page table walk, TLBs, DSI/ISI, atomics, `dcbz`, string ops, page-crossing accesses, FP state instructions; Linux 6.8 boots to user space |
| 3 | FPU: IEEE double, fused multiply-add, FPSCR; pass IEEE test vectors |
| 4 | Caches, DDR3 (LiteDRAM), FPGA bring-up on Artix-7 |
| 5 | mac99-style platform (OpenPIC, MacIO/KeyLargo subset, framebuffer + NDRV), OpenBIOS, Mac OS 9 |

## Next steps

1. Hardware realism (phase 4): synchronous block-RAM memories with fetch and
   load latency, caches, an iterative FPU and divider, a real-time time base,
   split GPR/FPR register files, 2-way TLBs; then synthesis and FPGA bring-up
   on an Artix-7 board.
2. A fuller Linux user space as a harder test: BusyBox or a small glibc/musl
   program set, UART receive for an interactive console, an external interrupt
   controller.
3. Remaining FP items: `fres`/`frsqrte`, enabled-exception traps, an FR check
   against IEEE test vectors or real hardware.
4. Performance: branch target buffer (CPI is 1.34 on the Linux boot).
5. Mac OS 9 platform (phase 5).
