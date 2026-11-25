# g3core: working notes for Claude Code

An open 32-bit PowerPC 750-class ("G3") CPU core in SystemVerilog. Long-term
goal: boot classic Mac OS 9 on an FPGA (Artix-7 class), as part of a compact
retro-Mac box with real legacy ports. Current state and roadmap are in
`README.md` (keep its Status and Next steps sections up to date when you finish
a piece of work).

## First thing on a new machine

```
tools/setup.sh            # installs tools, builds, runs the whole test suite
tools/setup.sh --linux    # also builds the Linux image and boots it
```

Developed on Ubuntu 24.04 (Verilator 5.020, GCC 13 cross-compiler, QEMU 8.2).

## Everyday commands

```
make test                     # everything below except Linux and random tests (~5 min)
make randtest N=20            # random integer programs vs QEMU
make fprandtest N=10          # random + boundary floating-point programs vs QEMU
make linux-test LINUX_OUT=../linux-build/out     # boot Linux on QEMU, pipeline, and lockstep
make linux-jitter LINUX_OUT=../linux-build/out   # Linux boot in lockstep with random bus wait states
make run T=hello              # one program on the pipeline simulator
build/ls/Vlockstep_top +img=build/sys/mmu.hex    # one test in lockstep; prints the first divergence
```

## How the design is organised

- `rtl/ppc_exec.sv` holds all instruction semantics and is shared by both
  cores. `rtl/ppc_core.sv` is the simple reference core; `rtl/ppc_pipe.sv` is
  the real pipeline. `rtl/ppc_mmu.sv` and `rtl/ppc_fpu.sv` are shared too.
- The two cores are compared per *architectural step* (one instruction, or
  one step of a multi-step instruction), never per clock cycle. The time base
  and decrementer count steps in simulation for the same reason. Anything you
  add must keep "what happens in step N" identical in both cores; cycle timing
  is free to differ.
- Multi-step instructions (lmw/stmw, dcbz, string ops, page-crossing accesses,
  FP ops) run on the sequencer in `ppc_exec` (`ms_active`/`ms_reg`).
- The register file has 128 32-bit entries: 0-31 GPRs, 32 a hidden temporary,
  64-127 the FPRs as halves.
- All exceptions are recognised in EX, and all architectural state except the
  register file commits there. A store commits when its bus request is granted.
- The pipeline's memory buses are request/grant with a later `rvalid`; one
  request outstanding per bus.

## How changes are verified (please keep doing this)

1. QEMU is the reference: `qemu-ppc -cpu 750` for user-level tests
   (`sw/tests`, random tests) and `qemu-system-ppc -M 40p -cpu 750` for
   supervisor tests (`sw/sys`) and Linux.
2. The reference core is checked against QEMU; the pipeline is checked against
   QEMU and against the reference core in lockstep, with and without random
   bus wait states.
3. After adding a feature, plant two or three realistic bugs and confirm the
   tests fail. Several times the first version of a test missed a planted bug
   and had to be strengthened. Report honestly which ones were caught.
4. Where QEMU and the architecture disagree, follow the architecture and make
   the test avoid or mask the difference. The known cases are listed in the
   README (MSR[ME]/[IP] handling, FX and compare behaviour in the FPSCR, FR,
   negated multiply-add in directed rounding modes, partial multi-step stores).

## Pitfalls already hit

- Verilator needs `-fno-case` (in the Makefile). Without it the nested decode
  `case` statements expand into tens of MB of C++ and exhaust memory.
- Verilator reports UNOPTFLAT if a value fed back into the big decode
  `always_comb` in `ppc_exec` is selected by a signal assigned inside that same
  block. Keep selectors (`spr_idx`, `sr_idx`, `ms_ridx`, `ra_idx`, ...) as
  separate `assign`s.
- Large arrays cannot be cleared in a reset loop; the register file uses an
  `initial` block.
- In shell loops, `r="$(basename $t)=$?"` reads the exit code of `basename`,
  not of the simulator. Save `$?` into a variable first.
- QEMU's decrementer runs on host time, so anything counting interrupts under
  QEMU is nondeterministic; the tests avoid printing such counts on the QEMU side.
- QEMU does not model self-modifying translation contexts the way hardware
  does: put an `isync` after `mtsr`/`mtmsr` in tests.
- The simulators print the program's UART output on stdout and statistics on
  stderr; exit status is the program's exit code (101 bus error, 102 timeout,
  99 unhandled exception reported by the test's own handler).
- A kernel rebuild takes about 10 minutes on 2 cores; `linux/build.sh` is
  incremental after the first run.

## Not done yet (see README for detail)

Caches, synthesis and FPGA bring-up, a branch target buffer, `fres`/`frsqrte`,
trapping FP exceptions, an interactive Linux console, the Mac OS 9 platform.
Nothing has been synthesised: resource and timing numbers are unknown.
