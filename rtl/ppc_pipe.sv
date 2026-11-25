// g3core pipelined core
//
// Six stages, in order:
//
//   F1   PC, instruction TLB lookup, fetch request
//   F2   wait for the fetch response
//   ID   static branch prediction: b, unconditional bc/bclr/bcctr and
//        backward bc are predicted taken and redirect fetch from here
//   EX   register read + forwarding, ppc_exec, data TLB lookup, data request,
//        all architectural state except the register file, branch resolve
//   MEM  wait for the data response
//   WB   register file write, retire
//
// Memory is reached through two request/response buses (ibus, dbus): a
// request is accepted in a cycle where gnt is high and its response arrives
// one or more cycles later with rvalid. One request per bus may be
// outstanding. This matches block RAM (response the next cycle) and leaves
// room for caches or a slower bus, which simply delay gnt or rvalid.
//
// Design notes
// - The register file is read in EX with forwarding from MEM and WB. A load's
//   data is not available until WB, so an instruction that needs it waits in
//   EX while the load is in MEM.
// - CR/XER/LR/CTR/MSR/SPRs are committed in EX, and every exception is
//   recognised there, so exceptions are precise without undo logic. A store
//   is committed when its bus request is accepted.
// - Time base and decrementer advance once per EX step, matching ppc_core.
// - MMU: a fetch that misses the TLB or faults is not acted on speculatively;
//   it travels down the pipe as a marker and is resolved when it reaches EX
//   (page walk then refetch, or ISI). Data addresses are translated in EX.
//   The walker uses the data bus while EX is stalled and MEM is empty.
//   Instructions that change the translation context flush younger fetches.
// - A redirect while a fetch is outstanding marks that fetch as killed; its
//   response is dropped when it arrives.
// - Multi-step instructions stay in EX, one step per data request.
// - The retire trace has exactly the same meaning as ppc_core's, so the two
//   cores can be compared step by step whatever the bus timing.

module ppc_pipe #(
    parameter logic [31:0] RESET_PC = 32'h0000_0100,
    parameter logic [31:0] PVR      = 32'h0008_0301
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        irq,
    // instruction bus (physical addresses, word reads)
    output logic        ibus_req,
    input  logic        ibus_gnt,
    output logic [31:0] ibus_addr,
    input  logic        ibus_rvalid,
    input  logic [31:0] ibus_rdata,
    output logic        icache_flush,   // icbi executed or HID0[ICFI] written
    // data bus (physical addresses; size 0/1/2 = byte/half/word, data right-aligned)
    output logic        dbus_req,
    input  logic        dbus_gnt,
    output logic [31:0] dbus_addr,
    output logic [1:0]  dbus_size,
    output logic        dbus_we,
    output logic [31:0] dbus_wdata,
    input  logic        dbus_rvalid,
    input  logic [31:0] dbus_rdata,
    output logic [63:0] instret,
    output logic [63:0] cycles,
    output logic        tr_valid,
    output logic [31:0] tr_pc, tr_insn,
    output logic        tr_rf_we,  output logic [6:0] tr_rf_idx, output logic [31:0] tr_rf_val,
    output logic        tr_up_we,  output logic [4:0] tr_up_idx, output logic [31:0] tr_up_val,
    output logic [31:0] tr_cr, tr_xer, tr_lr, tr_ctr, tr_msr,
    output logic        tr_exc,
    output logic        tr_st,     output logic [31:0] tr_st_addr, tr_st_data,
    output logic [1:0]  tr_st_size,
    // performance counters
    output logic [63:0] stall_ld_use,
    output logic [63:0] flush_branch
);
    // ------------------------------------------------------------------
    // Architectural state
    // ------------------------------------------------------------------
    // Register file: 0-31 GPRs, 32 hidden temporary (page-crossing loads),
    // 64-127 the FPRs as 32-bit halves (64+2n high word, 65+2n low word).
    logic [31:0] gpr [128];
    logic [31:0] fpscr, fpscr_n;
    logic [63:0] fp_a, fp_b, fpt_a, fpt_b;
    logic [31:0] fp_lo, fplo;
    logic        fpt_we, fplo_we;
    logic [6:0]  ra_idx, rb_idx, rs_idx;
    logic [1:0]  ld_s2d;
    // not cleared by reset (it will be block RAM); zeroed at time 0 for simulation
    initial for (int i = 0; i < 128; i++) gpr[i] = 32'd0;
    logic [31:0] cr, xer, lr, ctr, msr, srr0, srr1, dec_r, hid0, hid1;
    logic [31:0] sprg [4];
    logic [63:0] tb;

    // ------------------------------------------------------------------
    // Pipeline registers
    // ------------------------------------------------------------------
    logic [31:0] pc_f;

    // F2: one fetch in flight or waiting for ID
    logic        f2_valid;
    logic        f2_pend;                                         //   response not received yet
    logic        f2_have;                                         //   response held in f2_insn
    logic        f2_kill;                                         //   wrong path: drop the response
    logic        f2_imiss, f2_iflt;
    logic [31:0] f2_pc, f2_insn, f2_ifbits;

    logic        d_valid;  logic [31:0] d_pc, d_insn;            // F2/ID
    logic        d_imiss, d_iflt; logic [31:0] d_ifbits;          //   fetch marker
    logic        e_valid;  logic [31:0] e_pc, e_insn;            // ID/EX
    logic        e_imiss, e_iflt; logic [31:0] e_ifbits;
    logic        e_nf_i, e_nf_d;                                  // walker found no PTE
    logic [31:0] e_pred_pc;                                       // predicted next PC
    logic        e_ms_active; logic [6:0] e_ms_reg;               // multi-step sequencer
    logic        resv;        logic [31:0] resv_addr;             // lwarx reservation

    typedef struct packed {
        logic        valid;
        logic [31:0] pc, insn;
        logic        rf_we, ld;  logic [6:0] rf_idx; logic [31:0] rf_val;
        logic        mrg, acc;   logic [1:0] pos, fsize, s2d;
        logic        up_we;      logic [4:0] up_idx; logic [31:0] up_val;
        logic        st;         logic [31:0] ea, pa, st_data;
        logic [1:0]  size;       logic sext, brev;
        logic        retire;
        logic [31:0] cr, xer, lr, ctr, msr;   // trace snapshot after this step
        logic        exc;
    } stage_t;

    stage_t m, w;                                                 // EX/MEM, MEM/WB

    logic dec_pend;

    // ------------------------------------------------------------------
    // IF
    // ------------------------------------------------------------------
    logic [31:0] i_pa, i_fbits, d_pa, d_fbits, wk_addr, wk_wdata, xspr_rdata, sr_rdata;
    logic        i_ok, i_miss, i_flt, d_ok, d_miss, d_flt;
    logic        wk_start, wk_busy, wk_done, wk_nf, wk_req, wk_we, xspr_valid;

    // ------------------------------------------------------------------
    // ID: static branch prediction
    // ------------------------------------------------------------------
    wire [5:0]  d_opcd = d_insn[31:26];
    wire [4:0]  d_bo   = d_insn[25:21];
    wire [31:0] d_base = d_insn[1] ? 32'd0 : d_pc;
    logic        id_taken;
    logic [31:0] id_target;
    always_comb begin
        id_taken = 1'b0; id_target = d_pc + 32'd4;
        case (d_opcd)
            6'd18: begin id_taken = 1'b1;                                  // b
                         id_target = d_base + {{6{d_insn[25]}}, d_insn[25:2], 2'b00}; end
            6'd16: begin id_taken = (d_bo[4] & d_bo[2]) | d_insn[15];      // always, or backward
                         id_target = d_base + {{16{d_insn[15]}}, d_insn[15:2], 2'b00}; end
            6'd19: if (d_insn[10:1] == 10'd16 && d_bo[4] && d_bo[2]) begin  // blr (unconditional)
                         id_taken = 1'b1; id_target = {lr[31:2], 2'b00}; end
                   else if (d_insn[10:1] == 10'd528 && d_bo[4]) begin       // bctr (unconditional)
                         id_taken = 1'b1; id_target = {ctr[31:2], 2'b00}; end
            default: ;
        endcase
        if (!d_valid) id_taken = 1'b0;
    end

    // ------------------------------------------------------------------
    // EX: operand fetch with forwarding
    // ------------------------------------------------------------------
    wire [5:0] e_opcd = e_insn[31:26];
    wire [4:0] e_rs   = e_insn[25:21];
    wire [4:0] e_ra   = e_insn[20:16];
    wire [4:0] e_rb   = e_insn[15:11];
    wire [9:0] e_xo10 = e_insn[10:1];
    wire [8:0] e_xo9  = e_insn[9:1];

    function automatic logic [31:0] fwd(input logic [6:0] idx);
        if      (m.valid && m.rf_we && !m.ld && m.rf_idx == idx) fwd = m.rf_val;
        else if (m.valid && m.up_we && {2'b0, m.up_idx} == idx)  fwd = m.up_val;
        else if (w.valid && w.rf_we && w.rf_idx == idx)          fwd = w.rf_val;
        else if (w.valid && w.up_we && {2'b0, w.up_idx} == idx)  fwd = w.up_val;
        else                                                     fwd = gpr[idx];
    endfunction

    logic [6:0] ms_ridx;
    logic       ms_ruse;
    wire [31:0] e_va = fwd(ra_idx);
    wire [31:0] e_vb = fwd(rb_idx);
    wire [31:0] e_vs = fwd(rs_idx);
    wire [31:0] e_vm = fwd(ms_ridx);

    // Which GPR fields does the EX instruction actually read? (for load-use stalls)
    logic uses_ra, uses_rb, uses_rs;
    always_comb begin
        uses_ra = 1'b1; uses_rb = 1'b0; uses_rs = 1'b1;
        case (e_opcd)
            6'd16, 6'd18, 6'd19: begin uses_ra = 0; uses_rs = 0; end               // branches, CR ops
            6'd14, 6'd15, 6'd12, 6'd13, 6'd8, 6'd7, 6'd11, 6'd10,                  // D-form arith/cmp
            6'd32, 6'd33, 6'd34, 6'd35, 6'd40, 6'd41, 6'd42, 6'd43,                // D-form loads
            6'd46, 6'd47: uses_rs = 0;                                             // lmw / stmw (stmw uses ms_cur)
            6'd23: uses_rb = 1;                                                    // rlwnm
            6'd59, 6'd63: uses_rb = 1;                                             // FP: all ports may be read
            6'd31: begin
                uses_rb = 1;
                case (e_xo9)
                    9'd266, 9'd10, 9'd138, 9'd234, 9'd202, 9'd40, 9'd8, 9'd136, 9'd232,
                    9'd200, 9'd104, 9'd235, 9'd75, 9'd11, 9'd491, 9'd459: uses_rs = 0;
                    default: case (e_xo10)
                        10'd0, 10'd32, 10'd19, 10'd83, 10'd339, 10'd371, 10'd512,
                        10'd23, 10'd55, 10'd87, 10'd119, 10'd279, 10'd311, 10'd343, 10'd375,
                        10'd534, 10'd790: uses_rs = 0;
                        default: ;
                    endcase
                endcase
            end
            default: ;
        endcase
    end

    wire ld_use = e_valid && m.valid && m.ld &&
                  ((uses_ra && m.rf_idx == ra_idx) || (uses_rb && m.rf_idx == rb_idx) ||
                   (uses_rs && m.rf_idx == rs_idx) || (ms_ruse && m.rf_idx == ms_ridx));

    // ------------------------------------------------------------------
    // EX: execute
    // ------------------------------------------------------------------
    logic [31:0] next_pc, wa_val, wb_val, cr_n, xer_n, lr_n, ctr_n, spr_val, ea, st_data;
    logic [31:0] msr_n, srr0_n, srr1_n;
    logic        wa_en, wb_en, spr_we, srr_we, exc, int_ack_dec, retire, ms_active_n;
    logic        take_int, ctx_sync, sr_we, tlbie, mc_busy, icbi;
    logic [3:0]  sr_idx;
    logic        ld, st, ld_sext, ld_brev, ld_mrg, ld_acc, resv_set, resv_clr;
    logic [6:0]  wa_idx;
    logic [6:0]  ms_reg_n;
    logic [1:0]  ld_pos, fsize;
    logic [9:0]  spr_idx;
    logic [1:0]  msize;

    ppc_exec #(.PVR(PVR)) u_exec (
        .clk, .rst, .ex_en(base_go), .step(ex_go), .busy(mc_busy),
        .insn(e_insn), .pc(e_pc),
        .va(e_va), .vb(e_vb), .vs(e_vs), .v_ms(e_vm),
        .ms_active(e_ms_active), .ms_reg(e_ms_reg), .resv, .resv_addr, .fpscr, .fpscr_n,
        .fp_a, .fp_b, .fp_lo, .fpt_we, .fpt_a, .fpt_b, .fplo_we, .fplo, .ra_idx, .rb_idx, .rs_idx, .ld_s2d,
        .cr, .xer, .lr, .ctr, .msr, .srr0, .srr1, .dec_r, .hid0, .hid1,
        .sprg0(sprg[0]), .sprg1(sprg[1]), .sprg2(sprg[2]), .sprg3(sprg[3]), .tb,
        .int_ext(irq), .int_dec(dec_pend),
        .isi(e_iflt | (e_imiss & e_nf_i)), .isi_bits(e_iflt ? e_ifbits : 32'h4000_0000),
        .xspr_valid, .xspr_rdata, .sr_rdata,
        .take_int, .ctx_sync, .sr_we, .sr_idx, .tlbie, .icbi,
        .msr_n, .srr_we, .srr0_n, .srr1_n, .exc, .int_ack_dec,
        .next_pc, .wa_en, .wa_idx, .wa_val, .wb_en, .wb_val,
        .cr_n, .xer_n, .lr_n, .ctr_n, .spr_we, .spr_idx, .spr_val,
        .retire, .ms_active_n, .ms_reg_n, .ms_ridx, .ms_ruse,
        .ld, .st, .ld_sext, .ld_brev, .ld_mrg, .ld_pos, .ld_acc, .fsize, .resv_set, .resv_clr,
        .msize, .ea, .st_data
    );

    wire e_iwalk   = e_imiss & ~e_nf_i & ~take_int;
    wire mem       = ld | st;
    wire e_dflt    = mem & (d_flt | (d_miss & e_nf_d));
    wire e_dwalk   = mem & d_miss & ~e_nf_d;
    wire mem_need  = mem & ~e_dflt;               // this step makes a data bus request
    wire base_go   = e_valid && !ld_use;
    wire need_walk = base_go && (e_iwalk | e_dwalk);

    // MEM completes when its response arrives (or at once if it made no request)
    wire m_memop   = m.valid && (m.ld || m.st);
    wire m_done    = !m_memop || dbus_rvalid;
    wire m_free    = !m.valid || m_done;

    // The walker may only start once MEM is empty, so the data bus is idle.
    assign wk_start = need_walk && !wk_busy && !m.valid;
    wire ex_try    = base_go && !need_walk && !wk_busy && !mc_busy && m_free;
    wire ex_go     = ex_try && (!mem_need || dbus_gnt);   // one architectural step happens this cycle
    wire dsi       = ex_go && e_dflt;
    wire ex_commit = ex_go && !e_dflt;
    wire [31:0] dec_n = (spr_we && ex_commit && spr_idx == 10'd22) ? spr_val : dec_r - 32'd1;
    wire ms_cont   = ex_commit && ms_active_n;                    // multi-step instruction continues
    wire redirect  = ex_go && (dsi || exc || ctx_sync || (retire && next_pc != e_pred_pc));
    wire [31:0] redirect_pc = dsi ? ppc_pkg::exc_vector(msr, 20'h00300) : next_pc;
    wire irefetch  = wk_done && !wk_nf && e_iwalk;                // page now in the ITLB: fetch again
    wire hold      = e_valid && (!ex_go || ms_cont);              // EX keeps its instruction

    assign icache_flush = ex_commit && (icbi || (spr_we && spr_idx == 10'd1008 && spr_val[11]));

    assign dbus_req   = wk_busy ? wk_req   : (ex_try && mem_need);
    assign dbus_addr  = wk_busy ? wk_addr  : d_pa;
    assign dbus_size  = wk_busy ? 2'd2     : msize;
    assign dbus_we    = wk_busy ? wk_we    : st;
    assign dbus_wdata = wk_busy ? wk_wdata : st_data;

    // ------------------------------------------------------------------
    // Front end
    // ------------------------------------------------------------------
    wire adv        = !hold && !redirect && !irefetch;            // ID moves to EX
    wire kill_front = redirect || irefetch || (adv && id_taken);  // everything younger than ID/EX is wrong-path
    wire f2_resp    = f2_valid && f2_pend && ibus_rvalid;
    wire f2_ready   = f2_valid && !f2_kill && (!f2_pend || ibus_rvalid);
    wire f2_take    = adv && !id_taken && f2_ready;               // F2 moves to ID
    wire [31:0] f2_insn_now = (f2_imiss | f2_iflt) ? 32'd0 : f2_have ? f2_insn : ibus_rdata;
    wire f1_can     = !kill_front && (!f2_valid || f2_take);
    assign ibus_req  = f1_can && i_ok;
    assign ibus_addr = i_pa;
    wire f1_go      = f1_can && (!i_ok || ibus_gnt);              // fetch issued, or marker created

    wire [31:0] d_fbits_x = d_flt ? d_fbits : 32'h4000_0000;

    ppc_mmu u_mmu (
        .clk, .rst, .msr,
        .i_ea(pc_f), .i_pa, .i_ok, .i_miss, .i_flt, .i_fbits,
        .d_ea(ea), .d_store(st), .d_pa, .d_ok, .d_miss, .d_flt, .d_fbits,
        .wk_start, .wk_instr(e_iwalk), .wk_store(st), .wk_ea(e_iwalk ? e_pc : ea),
        .wk_busy, .wk_done, .wk_nf, .wk_req, .wk_we, .wk_addr, .wk_wdata,
        .wk_gnt(dbus_gnt), .wk_rvalid(dbus_rvalid), .wk_rdata(dbus_rdata),
        .spr_idx, .spr_rdata(xspr_rdata), .spr_rvalid(xspr_valid),
        .spr_we(spr_we & ex_commit), .spr_wdata(spr_val),
        .sr_idx, .sr_rdata, .sr_we(sr_we & ex_commit), .sr_wdata(e_vs),
        .tlbie(tlbie & ex_commit), .tlbie_ea(e_vb),
        .dsi_we(dsi), .dsisr_in(d_fbits_x | (st ? 32'h0200_0000 : 32'h0)), .dar_in(ea)
    );

    // ------------------------------------------------------------------
    // MEM
    // ------------------------------------------------------------------
    wire [31:0] m_ld_val = ppc_pkg::ld_result(dbus_rdata, m.fsize, m.sext, m.brev, m.mrg, m.pos, m.acc, m.rf_val, m.s2d);

    // ------------------------------------------------------------------
    // WB / trace
    // ------------------------------------------------------------------
    assign tr_valid  = w.valid;
    assign tr_pc     = w.pc;      assign tr_insn   = w.insn;
    assign tr_rf_we  = w.rf_we;   assign tr_rf_idx = w.rf_idx;  assign tr_rf_val = w.rf_val;
    assign tr_up_we  = w.up_we;   assign tr_up_idx = w.up_idx;  assign tr_up_val = w.up_val;
    assign tr_cr = w.cr; assign tr_xer = w.xer; assign tr_lr = w.lr; assign tr_ctr = w.ctr;
    assign tr_msr = w.msr; assign tr_exc = w.exc;
    assign tr_st = w.st; assign tr_st_addr = w.ea; assign tr_st_data = w.st_data; assign tr_st_size = w.size;

    // ------------------------------------------------------------------
    // Sequential
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            pc_f <= RESET_PC;
            f2_valid <= 0; f2_pend <= 0; f2_have <= 0; f2_kill <= 0; f2_imiss <= 0; f2_iflt <= 0;
            f2_pc <= 0; f2_insn <= 0; f2_ifbits <= 0;
            d_valid <= 0; d_pc <= 0; d_insn <= 0; d_imiss <= 0; d_iflt <= 0; d_ifbits <= 0;
            e_valid <= 0; e_pc <= 0; e_insn <= 0; e_pred_pc <= 0;
            e_imiss <= 0; e_iflt <= 0; e_ifbits <= 0; e_nf_i <= 0; e_nf_d <= 0;
            e_ms_active <= 0; e_ms_reg <= 0;
            m <= '0; w <= '0;
            cr <= 0; xer <= 0; lr <= 0; ctr <= 0; msr <= 0;
            srr0 <= 0; srr1 <= 0; dec_r <= 32'hFFFF_FFFF; hid0 <= 0; hid1 <= 0;
            for (int i = 0; i < 4; i++) sprg[i] <= 0;
            fpscr <= 0;
            resv <= 0; resv_addr <= 0; fp_a <= 0; fp_b <= 0; fp_lo <= 0;
            tb <= 0; dec_pend <= 0;
            instret <= 0; cycles <= 0; stall_ld_use <= 0; flush_branch <= 0;
        end else begin
            cycles <= cycles + 64'd1;
            if (ld_use)   stall_ld_use <= stall_ld_use + 64'd1;
            if (redirect) flush_branch <= flush_branch + 64'd1;

            // ---- WB ----
            if (w.valid) begin
                if (w.up_we) gpr[{2'b0, w.up_idx}] <= w.up_val;
                if (w.rf_we) gpr[w.rf_idx] <= w.rf_val;
                if (w.retire && !w.exc) instret <= instret + 64'd1;
            end

            // ---- MEM -> WB ----
            w <= m;
            w.valid <= m.valid && m_done;
            if (m.ld) w.rf_val <= m_ld_val;

            // ---- EX -> MEM ----
            if (m_free) begin
                m.valid   <= ex_go;
                m.pc      <= e_pc;       m.insn   <= e_insn;
                m.rf_we   <= (wa_en | ld) & ~dsi;   m.ld <= ld & ~dsi;
                m.rf_idx  <= wa_idx;     m.rf_val <= wa_val;
                m.up_we   <= wb_en & ~dsi;  m.up_idx <= e_ra;    m.up_val <= wb_val;
                m.st      <= st & ~dsi;  m.ea     <= ea;      m.pa <= d_pa;  m.st_data <= st_data;
                m.size    <= msize;      m.sext   <= ld_sext; m.brev    <= ld_brev;
                m.mrg     <= ld_mrg;     m.pos    <= ld_pos;  m.acc     <= ld_acc;   m.fsize <= fsize;   m.s2d <= ld_s2d;
                m.retire  <= retire;
                m.cr  <= dsi ? cr  : cr_n;   m.xer <= dsi ? xer : xer_n;
                m.lr  <= dsi ? lr  : lr_n;   m.ctr <= dsi ? ctr : ctr_n;
                m.msr <= dsi ? ppc_pkg::exc_msr(msr) : msr_n;
                m.exc <= exc | dsi;
            end

            if (wk_done && wk_nf) begin
                if (e_iwalk) e_nf_i <= 1; else e_nf_d <= 1;
            end
            if (ex_go) begin
                e_nf_i <= 0; e_nf_d <= 0;
                tb <= tb + 64'd1;
                dec_r <= dec_n;
                if (int_ack_dec) dec_pend <= 0;
                if (!dec_r[31] && dec_n[31]) dec_pend <= 1;
            end
            if (dsi) begin
                srr0 <= e_pc;
                srr1 <= ppc_pkg::exc_srr1(msr);
                msr  <= ppc_pkg::exc_msr(msr);
                e_ms_active <= 0; e_ms_reg <= 0;
            end else if (ex_commit) begin
                cr <= cr_n; xer <= xer_n; lr <= lr_n; ctr <= ctr_n; msr <= msr_n; fpscr <= fpscr_n;
                if (spr_we) case (spr_idx)
                    10'd26:  srr0 <= spr_val;
                    10'd27:  srr1 <= spr_val;
                    10'd272, 10'd273, 10'd274, 10'd275: sprg[spr_idx[1:0]] <= spr_val;
                    10'd284: tb[31:0]  <= spr_val;
                    10'd285: tb[63:32] <= spr_val;
                    10'd1008: hid0 <= spr_val;
                    10'd1009: hid1 <= spr_val;
                    default: ;
                endcase
                if (srr_we) begin srr0 <= srr0_n; srr1 <= srr1_n; end
                e_ms_active <= ms_active_n;
                e_ms_reg    <= ms_reg_n;
                if (resv_set) begin resv <= 1; resv_addr <= ea; end
                if (resv_clr) resv <= 0;
                if (fpt_we) begin fp_a <= fpt_a; fp_b <= fpt_b; end
                if (fplo_we) fp_lo <= fplo;
            end

            // ---- front end ----
            if (f2_resp) begin
                f2_pend <= 0;
                if (f2_kill) f2_valid <= 0;
                else begin f2_have <= 1; f2_insn <= ibus_rdata; end
            end
            if (kill_front) begin
                if (f2_valid && f2_pend && !ibus_rvalid) f2_kill <= 1;    // response still to come
                else f2_valid <= 0;
            end
            if (redirect || irefetch) begin
                pc_f <= redirect ? redirect_pc : e_pc;
                d_valid <= 0; e_valid <= 0;
            end else if (adv) begin
                e_valid <= d_valid; e_pc <= d_pc; e_insn <= d_insn;
                e_imiss <= d_imiss; e_iflt <= d_iflt; e_ifbits <= d_ifbits;
                e_pred_pc <= id_taken ? id_target : d_pc + 32'd4;
                if (id_taken) begin
                    pc_f <= id_target;
                    d_valid <= 0;
                end else if (f2_ready) begin
                    d_valid <= 1; d_pc <= f2_pc; d_insn <= f2_insn_now;
                    d_imiss <= f2_imiss; d_iflt <= f2_iflt; d_ifbits <= f2_ifbits;
                    f2_valid <= 0;
                end else begin
                    d_valid <= 0;
                end
            end
            if (f1_go) begin
                // a fetch that cannot be translated yet becomes a marker (no bus request)
                f2_valid <= 1; f2_pc <= pc_f; f2_pend <= i_ok; f2_have <= 0; f2_kill <= 0;
                f2_imiss <= i_miss; f2_iflt <= i_flt; f2_ifbits <= i_fbits;
                pc_f <= pc_f + 32'd4;
            end
        end
    end
endmodule
