// Lockstep checker: runs the reference core and the pipeline side by side on
// the same image and compares every retire-trace record (PC, instruction,
// register writes, CR/XER/LR/CTR, stores). Stops at the first mismatch.
//   Vlockstep +img=prog.hex [+max_cycles=N]
// Exit status: 0 = traces matched and program exited 0; 1 = mismatch;
// otherwise the program's exit code or 100/101/102 as in tb.cpp.
#include "Vlockstep_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>

struct Rec {
    uint32_t pc, insn;
    bool rf_we; uint32_t rf_idx, rf_val;
    bool up_we; uint32_t up_idx, up_val;
    uint32_t cr, xer, lr, ctr;
    bool st; uint32_t st_addr, st_data, st_size;
    uint64_t seq;
};

#define SAMPLE(p) Rec{ top->p##_tr_pc, top->p##_tr_insn, \
    (bool)top->p##_tr_rf_we, top->p##_tr_rf_idx, top->p##_tr_rf_val, \
    (bool)top->p##_tr_up_we, top->p##_tr_up_idx, top->p##_tr_up_val, \
    top->p##_tr_cr, top->p##_tr_xer, top->p##_tr_lr, top->p##_tr_ctr, \
    (bool)top->p##_tr_st, top->p##_tr_st_addr, top->p##_tr_st_data, top->p##_tr_st_size, 0 }

// Instructions whose results depend on cycle timing (time base, decrementer).
static bool timing_dependent(uint32_t insn) {
    uint32_t op = insn >> 26, xo = (insn >> 1) & 0x3ff;
    uint32_t spr = ((insn >> 6) & 0x3e0) | ((insn >> 16) & 0x1f);
    if (op != 31) return false;
    if (xo == 371) return true;                                   // mftb
    if (xo == 339 && (spr == 268 || spr == 269 || spr == 22)) return true;
    return false;
}

static void print_rec(const char *who, const Rec &r) {
    fprintf(stderr, "  %s #%llu pc=%08x insn=%08x", who, (unsigned long long)r.seq, r.pc, r.insn);
    if (r.rf_we) fprintf(stderr, " r%u=%08x", r.rf_idx, r.rf_val);
    if (r.up_we) fprintf(stderr, " r%u(upd)=%08x", r.up_idx, r.up_val);
    if (r.st) fprintf(stderr, " st[%08x]/%u=%08x", r.st_addr, 1u << r.st_size, r.st_data);
    fprintf(stderr, " cr=%08x xer=%08x lr=%08x ctr=%08x\n", r.cr, r.xer, r.lr, r.ctr);
}

static bool same(const Rec &a, const Rec &b) {
    if (a.pc != b.pc || a.insn != b.insn) return false;
    if (a.rf_we != b.rf_we || a.up_we != b.up_we || a.st != b.st) return false;
    bool tdep = timing_dependent(a.insn);
    if (a.rf_we && (a.rf_idx != b.rf_idx || (!tdep && a.rf_val != b.rf_val))) return false;
    if (a.up_we && (a.up_idx != b.up_idx || a.up_val != b.up_val)) return false;
    if (a.cr != b.cr || a.xer != b.xer || a.lr != b.lr || a.ctr != b.ctr) return false;
    if (a.st && (a.st_addr != b.st_addr || a.st_data != b.st_data || a.st_size != b.st_size)) return false;
    return true;
}

int main(int argc, char **argv) {
    auto *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    auto *top = new Vlockstep_top{ctx};

    uint64_t max_cycles = 500000000ull;
    if (const char *m = ctx->commandArgsPlusMatch("max_cycles="))
        if (*m) max_cycles = strtoull(strchr(m, '=') + 1, nullptr, 0);

    top->clk = 0; top->rst = 1;
    for (int i = 0; i < 4; i++) { top->clk = !top->clk; top->eval(); }
    top->rst = 0;

    std::deque<Rec> qref, qdut, hist;
    uint64_t nref = 0, ndut = 0, matched = 0, cyc = 0;
    bool ref_stop = false, mismatch = false;
    int dut_drain = -1;   // cycles left after the DUT signals done/trap

    while (cyc < max_cycles && !mismatch) {
        top->clk = 0; top->eval();
        if (!ref_stop && top->ref_tr_valid) { Rec r = SAMPLE(ref); r.seq = nref++; qref.push_back(r); }
        if (top->dut_tr_valid)              { Rec r = SAMPLE(dut); r.seq = ndut++; qdut.push_back(r); }
        top->clk = 1; top->eval();
        cyc++;

        if (top->ref_done || top->ref_trap || top->ref_bus_err) ref_stop = true;
        bool dut_end = top->dut_done || top->dut_trap || top->dut_bus_err;
        if (dut_end && dut_drain < 0) dut_drain = 4;

        while (!qref.empty() && !qdut.empty()) {
            const Rec &a = qref.front(), &b = qdut.front();
            if (!same(a, b)) {
                fprintf(stderr, "LOCKSTEP MISMATCH after %llu matching steps (cycle %llu)\n",
                        (unsigned long long)matched, (unsigned long long)cyc);
                print_rec("ref", a);
                print_rec("dut", b);
                fprintf(stderr, "  last matching steps:\n");
                for (auto &h : hist) print_rec("   ", h);
                mismatch = true;
                break;
            }
            hist.push_back(a);
            if (hist.size() > 8) hist.pop_front();
            qref.pop_front(); qdut.pop_front();
            matched++;
        }
        if (dut_drain >= 0 && dut_drain-- == 0) break;
    }
    fflush(stdout);

    int rc;
    if (mismatch) rc = 1;
    else if (top->dut_done) rc = (int)top->dut_exit_code;
    else if (top->dut_trap) {
        fprintf(stderr, "TRAP: unimplemented/illegal insn %08x at pc %08x\n", top->dut_trap_insn, top->dut_trap_pc);
        rc = 100;
    } else if (top->dut_bus_err) { fprintf(stderr, "BUS ERROR: %08x\n", top->dut_bus_err_addr); rc = 101; }
    else { fprintf(stderr, "TIMEOUT after %llu cycles\n", (unsigned long long)cyc); rc = 102; }

    if (!mismatch && !qref.empty() && !ref_stop) {
        fprintf(stderr, "LOCKSTEP: reference still has %zu unmatched steps\n", qref.size());
    }
    fprintf(stderr, "lockstep: %llu steps matched; dut cycles=%llu instret=%llu\n",
            (unsigned long long)matched, (unsigned long long)top->dut_cycles,
            (unsigned long long)top->dut_instret);

    top->final();
    delete top; delete ctx;
    return rc;
}
