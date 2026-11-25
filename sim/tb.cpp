// Verilator driver for soc_top.
//   Vsoc_top +img=prog.hex [+max_cycles=N]
// Exit status: program's exit code, or 100 trap, 101 bus error, 102 timeout.
#include "Vsoc_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>

int main(int argc, char **argv) {
    auto *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    auto *top = new Vsoc_top{ctx};

    uint64_t max_cycles = 500000000ull;
    if (const char *m = ctx->commandArgsPlusMatch("max_cycles=")) {
        if (*m) max_cycles = strtoull(strchr(m, '=') + 1, nullptr, 0);
    }

    top->clk = 0;
    top->rst = 1;
    for (int i = 0; i < 4; i++) { top->clk = !top->clk; top->eval(); }
    top->rst = 0;

    auto t0 = std::chrono::steady_clock::now();
    uint64_t cyc = 0;
    while (!top->done && !top->trap && !top->bus_err && !ctx->gotFinish() && cyc < max_cycles) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        cyc++;
    }
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    fflush(stdout);

    int rc;
    if (top->done) {
        rc = (int)top->exit_code;
    } else if (top->trap) {
        fprintf(stderr, "TRAP: unimplemented/illegal insn %08x at pc %08x\n", top->trap_insn, top->trap_pc);
        rc = 100;
    } else if (top->bus_err) {
        fprintf(stderr, "BUS ERROR: access to %08x\n", top->bus_err_addr);
        rc = 101;
    } else {
        fprintf(stderr, "TIMEOUT after %llu cycles\n", (unsigned long long)cyc);
        rc = 102;
    }
    double cpi = top->instret ? (double)top->cycles / top->instret : 0.0;
    fprintf(stderr, "cycles=%llu instret=%llu CPI=%.3f ld_use_stalls=%llu branch_flushes=%llu (%.1f M cycles/s sim)\n",
            (unsigned long long)top->cycles, (unsigned long long)top->instret, cpi,
            (unsigned long long)top->stall_ld_use, (unsigned long long)top->flush_branch,
            secs > 0 ? cyc / secs / 1e6 : 0.0);

    top->final();
    delete top;
    delete ctx;
    return rc;
}
