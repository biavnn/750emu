// g3core - stage 0 reference core
//
// Single-cycle: one instruction (or one lmw/stmw step) per clock, with
// combinational instruction and data memory. All instruction semantics live in
// ppc_exec; this module only holds architectural state. It is the golden RTL
// model the pipelined core is checked against in lockstep.
//
// Time base and decrementer advance once per executed step (not per clock),
// so both cores see identical timer values and can be compared in lockstep.
//
// Address translation: both lookups are combinational. On a TLB miss the core
// stops, lets the MMU's walker use the data port, then retries the same step.
//
// Not yet implemented: FPU (raises FP-unavailable / program exceptions),
// string ops, lwarx/stwcx., dcbz (program exception).

module ppc_core #(
    parameter logic [31:0] RESET_PC = 32'h0000_0100,
    parameter logic [31:0] PVR      = 32'h0008_0301
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        irq,          // external interrupt (level)
    output logic [31:0] imem_addr,    // physical
    input  logic [31:0] imem_rdata,
    output logic [31:0] dmem_addr,    // physical
    output logic [1:0]  dmem_size,    // 0=byte 1=half 2=word
    output logic        dmem_re,
    output logic        dmem_we,
    output logic [31:0] dmem_wdata,   // right-aligned
    input  logic [31:0] dmem_rdata,   // right-aligned, zero-extended
    output logic [63:0] instret,
    output logic [63:0] cycles,
    // retire trace: describes the step that commits at the next clock edge
    output logic        tr_valid,
    output logic [31:0] tr_pc, tr_insn,
    output logic        tr_rf_we,  output logic [6:0] tr_rf_idx, output logic [31:0] tr_rf_val,
    output logic        tr_up_we,  output logic [4:0] tr_up_idx, output logic [31:0] tr_up_val,
    output logic [31:0] tr_cr, tr_xer, tr_lr, tr_ctr, tr_msr,
    output logic        tr_exc,
    output logic        tr_st,     output logic [31:0] tr_st_addr, tr_st_data,
    output logic [1:0]  tr_st_size
);
    logic [31:0] pc;
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
    logic        ms_active;
    logic [6:0]  ms_reg;
    logic        dec_pend;
    logic        resv;
    logic [31:0] resv_addr;
    logic        nf_i, nf_d;          // the walker found no PTE for this step's fetch / data access

    // ------------------------------------------------------------------
    // MMU
    // ------------------------------------------------------------------
    logic [31:0] i_pa, i_fbits, d_pa, d_fbits, wk_addr, wk_wdata, xspr_rdata, sr_rdata;
    logic        i_ok, i_miss, i_flt, d_ok, d_miss, d_flt;
    logic        wk_start, wk_busy, wk_done, wk_nf, wk_req, wk_we, xspr_valid;
    // the walker speaks a request/response bus; this core's memory answers in
    // the same cycle, so the response is simply registered
    logic        wk_rv;
    logic [31:0] wk_rd;

    // execute outputs
    logic [31:0] next_pc, wa_val, wb_val, cr_n, xer_n, lr_n, ctr_n, spr_val, ea, st_data;
    logic [31:0] msr_n, srr0_n, srr1_n;
    logic        wa_en, wb_en, spr_we, srr_we, exc, int_ack_dec, retire, ms_active_n;
    logic        take_int, ctx_sync, sr_we, tlbie;
    logic        ld, st, ld_sext, ld_brev, ld_mrg, ld_acc, ms_ruse, resv_set, resv_clr;
    logic [6:0]  wa_idx, ms_ridx;
    logic [6:0]  ms_reg_n;
    logic [1:0]  ld_pos, fsize;
    logic [9:0]  spr_idx;
    logic [3:0]  sr_idx;
    logic [1:0]  msize;

    wire [31:0] insn = i_ok ? imem_rdata : 32'd0;
    assign imem_addr = i_pa;

    wire i_fault = i_flt | (i_miss & nf_i);
    wire i_walk  = i_miss & ~nf_i & ~take_int;
    wire mem     = ld | st;
    wire d_fault = mem & (d_flt | (d_miss & nf_d));
    wire d_walk  = mem & d_miss & ~nf_d;
    wire walk    = i_walk | d_walk;
    wire step    = ~rst & ~walk & ~wk_busy;       // one architectural step completes this cycle
    wire dsi     = step & d_fault;
    wire commit  = step & ~d_fault;
    assign wk_start = ~rst & walk & ~wk_busy;

    ppc_mmu u_mmu (
        .clk, .rst, .msr,
        .i_ea(pc), .i_pa, .i_ok, .i_miss, .i_flt, .i_fbits,
        .d_ea(ea), .d_store(st), .d_pa, .d_ok, .d_miss, .d_flt, .d_fbits,
        .wk_start, .wk_instr(i_walk), .wk_store(st), .wk_ea(i_walk ? pc : ea),
        .wk_busy, .wk_done, .wk_nf, .wk_req, .wk_we, .wk_addr, .wk_wdata,
        .wk_gnt(1'b1), .wk_rvalid(wk_rv), .wk_rdata(wk_rd),
        .spr_idx, .spr_rdata(xspr_rdata), .spr_rvalid(xspr_valid),
        .spr_we(spr_we & commit), .spr_wdata(spr_val),
        .sr_idx, .sr_rdata, .sr_we(sr_we & commit), .sr_wdata(gpr[rs_idx]),
        .tlbie(tlbie & commit), .tlbie_ea(gpr[rb_idx]),
        .dsi_we(dsi), .dsisr_in(d_fbits_x | (st ? 32'h0200_0000 : 32'h0)), .dar_in(ea)
    );
    wire [31:0] d_fbits_x = d_flt ? d_fbits : 32'h4000_0000;

    ppc_exec #(.PVR(PVR)) u_exec (
        .insn, .pc,
        .va(gpr[ra_idx]), .vb(gpr[rb_idx]), .vs(gpr[rs_idx]), .v_ms(gpr[ms_ridx]),
        .ms_active, .ms_reg, .resv, .resv_addr, .fpscr, .fpscr_n,
        .fp_a, .fp_b, .fp_lo, .fpt_we, .fpt_a, .fpt_b, .fplo_we, .fplo, .ra_idx, .rb_idx, .rs_idx, .ld_s2d,
        .cr, .xer, .lr, .ctr, .msr, .srr0, .srr1, .dec_r, .hid0, .hid1,
        .sprg0(sprg[0]), .sprg1(sprg[1]), .sprg2(sprg[2]), .sprg3(sprg[3]), .tb,
        .int_ext(irq), .int_dec(dec_pend),
        .isi(i_fault), .isi_bits(i_flt ? i_fbits : 32'h4000_0000),
        .xspr_valid, .xspr_rdata, .sr_rdata,
        .take_int, .ctx_sync, .sr_we, .sr_idx, .tlbie,
        .msr_n, .srr_we, .srr0_n, .srr1_n, .exc, .int_ack_dec,
        .next_pc, .wa_en, .wa_idx, .wa_val, .wb_en, .wb_val,
        .cr_n, .xer_n, .lr_n, .ctr_n, .spr_we, .spr_idx, .spr_val,
        .retire, .ms_active_n, .ms_reg_n, .ms_ridx, .ms_ruse,
        .ld, .st, .ld_sext, .ld_brev, .ld_mrg, .ld_pos, .ld_acc, .fsize, .resv_set, .resv_clr,
        .msize, .ea, .st_data
    );

    wire [31:0] ld_val = ppc_pkg::ld_result(dmem_rdata, fsize, ld_sext, ld_brev, ld_mrg, ld_pos, ld_acc, wa_val, ld_s2d);
    wire        rf_we  = wa_en | ld;
    wire [31:0] rf_val = ld ? ld_val : wa_val;
    wire [31:0] dec_n  = (spr_we && commit && spr_idx == 10'd22) ? spr_val : dec_r - 32'd1;

    // the walker borrows the data port while it runs
    assign dmem_addr  = wk_busy ? wk_addr  : d_pa;
    assign dmem_size  = wk_busy ? 2'd2     : msize;
    assign dmem_re    = wk_busy ? (wk_req & ~wk_we) : ld & commit;
    assign dmem_we    = wk_busy ? (wk_req & wk_we)  : st & commit;
    assign dmem_wdata = wk_busy ? wk_wdata : st_data;

    // trace
    assign tr_valid   = step;
    assign tr_pc      = pc;
    assign tr_insn    = insn;
    assign tr_rf_we   = rf_we & ~dsi;  assign tr_rf_idx = wa_idx;      assign tr_rf_val = rf_val;
    assign tr_up_we   = wb_en & ~dsi;  assign tr_up_idx = insn[20:16]; assign tr_up_val = wb_val;
    assign tr_cr  = dsi ? cr  : cr_n;  assign tr_xer = dsi ? xer : xer_n;
    assign tr_lr  = dsi ? lr  : lr_n;  assign tr_ctr = dsi ? ctr : ctr_n;
    assign tr_msr = dsi ? ppc_pkg::exc_msr(msr) : msr_n;
    assign tr_exc = exc | dsi;
    assign tr_st = st & ~dsi; assign tr_st_addr = ea; assign tr_st_data = st_data; assign tr_st_size = msize;

    always_ff @(posedge clk) begin
        if (rst) begin
            pc <= RESET_PC;
            cr <= 0; xer <= 0; lr <= 0; ctr <= 0; msr <= 0;
            srr0 <= 0; srr1 <= 0; dec_r <= 32'hFFFF_FFFF; hid0 <= 0; hid1 <= 0;
            for (int i = 0; i < 4; i++) sprg[i] <= 0;
            fpscr <= 0;
            resv <= 0; resv_addr <= 0; fp_a <= 0; fp_b <= 0; fp_lo <= 0;
            tb <= 0; dec_pend <= 0;
            ms_active <= 0; ms_reg <= 0;
            nf_i <= 0; nf_d <= 0; wk_rv <= 0; wk_rd <= 0;
            instret <= 0; cycles <= 0;
        end else begin
            cycles <= cycles + 64'd1;
            wk_rv <= wk_req; wk_rd <= dmem_rdata;
            if (wk_done && wk_nf) begin
                if (i_walk) nf_i <= 1; else nf_d <= 1;
            end
            if (step) begin
                nf_i <= 0; nf_d <= 0;
                tb <= tb + 64'd1;
                dec_r <= dec_n;
                if (int_ack_dec) dec_pend <= 0;
                if (!dec_r[31] && dec_n[31]) dec_pend <= 1;     // decrementer passed zero
            end
            if (dsi) begin
                // data storage interrupt: nothing from this instruction commits
                pc   <= ppc_pkg::exc_vector(msr, 20'h00300);
                srr0 <= pc;
                srr1 <= ppc_pkg::exc_srr1(msr);
                msr  <= ppc_pkg::exc_msr(msr);
                ms_active <= 0; ms_reg <= 0;
            end else if (commit) begin
                pc  <= next_pc;
                cr  <= cr_n;  xer <= xer_n;  lr <= lr_n;  ctr <= ctr_n;  msr <= msr_n;  fpscr <= fpscr_n;
                if (wb_en) gpr[{2'b0, insn[20:16]}] <= wb_val;
                if (rf_we) gpr[wa_idx] <= rf_val;   // load result wins over update (invalid form)
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
                ms_active <= ms_active_n; ms_reg <= ms_reg_n;
                if (resv_set) begin resv <= 1; resv_addr <= ea; end
                if (resv_clr) resv <= 0;
                if (fpt_we) begin fp_a <= fpt_a; fp_b <= fpt_b; end
                if (fplo_we) fp_lo <= fplo;
                if (retire && !exc) instret <= instret + 64'd1;
            end
        end
    end
endmodule
