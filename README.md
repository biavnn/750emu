# g3core

An open 32-bit PowerPC core (G3/750-class), with the long-term goal of booting
classic Mac OS 9 on an FPGA. The design target is "what Mac OS accepts as a G3",
not a clone of the real 750's out-of-order microarchitecture.

## Status: stage 0 (integer reference core)

`rtl/ppc_core.sv` is a single-cycle implementation of the 32-bit PowerPC user
integer ISA. It runs GCC-compiled C on a simulated SoC, and its output matches
QEMU (`qemu-ppc -cpu 750`) byte for byte on every test.

Implemented:
- integer arithmetic including all carrying/extended/overflow forms (`addc`, `adde`, `addme`, `addze`, `subf*`, `neg`, `o` and `.` variants)
- `mullw`, `mulhw`, `mulhwu`, `mulli`, `divw`, `divwu`
- logical ops, shifts (`slw`/`srw`/`sraw`/`srawi` with CA), rotates (`rlwinm`/`rlwnm`/`rlwimi`), `cntlzw`, `extsb`/`extsh`
- compares, all CR logical ops, `mcrf`, `mfcr`/`mtcrf`, `mcrxr`
- branches: `b`, `bc`, `bclr`, `bcctr` with CTR decrement and link forms
- loads/stores: byte/half/word, algebraic, update and indexed forms, byte-reversed, `lmw`/`stmw`
- `mfspr`/`mtspr` for XER, LR, CTR, SRR0/1, SPRG0-3, DEC, TB, PVR, HID0/1; `mfmsr`/`mtmsr`; `mftb`

Not yet implemented (the core traps on these): FPU, MMU, exceptions/`rfi`/`sc`,
string ops, `lwarx`/`stwcx.`, `dcbz`, `tw`/`twi`.

## Layout

```
rtl/ppc_core.sv     the core
rtl/soc_top.sv      simulation SoC: 1 MiB RAM, UART + exit MMIO at 0xF0000000
sim/tb.cpp          Verilator driver
sw/common/          crt0, linker script, tiny printf, bare-metal + Linux backends
sw/tests/           test programs (C, plus optional same-named .S)
tools/difftest.sh   runs each test on the sim and under qemu-ppc, diffs output
```

## Usage

Requires `verilator` (5.x), `gcc-powerpc-linux-gnu`, `qemu-user`.
On Ubuntu: `sudo apt install verilator gcc-powerpc-linux-gnu qemu-user`.
On macOS: `brew install verilator qemu`; the cross-compiler is easiest via a Linux VM or container.

```
make test          # build everything, run differential tests
make run T=hello   # run one program on the simulator
```

Every test is built twice from the same source: once for the bare-metal SoC
and once as a static Linux binary that runs under QEMU (the golden model). A
test passes when both produce identical output and exit codes.

## Roadmap

| Phase | Goal |
|---|---|
| **0** (done) | Single-cycle integer reference core, differential tests vs QEMU |
| 1 | 5-stage in-order pipeline (forwarding, branch handling, load-use stalls), lockstep trace compare against stage 0 |
| 2 | Exceptions, MSR, `sc`/`rfi`, decrementer interrupt; MMU (BATs, segments, TLB with 603-style software reload); boot 32-bit Linux |
| 3 | FPU: IEEE double, fused multiply-add, FPSCR; pass IEEE test vectors |
| 4 | Caches, DDR3 (LiteDRAM), FPGA bring-up on Artix-7 |
| 5 | mac99-style platform (OpenPIC, MacIO/KeyLargo subset, framebuffer + NDRV), OpenBIOS, Mac OS 9 |

## Next steps (phase 1)

1. Add a retire trace port (pc, insn, register write) to the stage-0 core and the testbench.
2. Build `rtl/ppc_pipe.sv`: IF / ID / EX / MEM / WB, reusing the stage-0 decode rules.
3. Run both cores in lockstep in one testbench and stop on the first mismatch.
4. Add riskier tests: a Dhrystone/CoreMark-style benchmark, a random instruction-sequence generator checked against QEMU.
