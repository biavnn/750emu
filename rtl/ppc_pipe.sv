// g3core - phase 1 pipelined core
//
// Classic 5-stage in-order pipeline:
//
//   IF   fetch at pc_f, predict pc+4
//   ID   static branch prediction: b, unconditional bc/bclr/bcctr and
//        backward bc are predicted taken and redirect fetch from ID
//   EX   register read + forwarding, ppc_exec, SPR commit, branch resolve
//   MEM  data memory access
//   WB   GPR write, retire
//
// Design notes
// - GPRs are read in EX with forwarding from MEM and WB, so the only data
//   hazard is load-use: the EX instruction waits one cycle when it needs the
//   result of a load in MEM.
// - CR/XER/LR/CTR/SPRs are committed in EX. Nothing after EX can fault yet,
//   so this is safe; when data-access exceptions arrive (phase 2) MEM-stage
//   faults will need these writes to move later or be undone.
// - Correctly predicted taken branches cost 1 cycle (the wrong-path fetch);
//   mispredictions are fixed in EX and flush IF/ID and ID/EX (2 cycles).
// - lmw/stmw stay in EX for one micro-op per register; the front end holds.
// - The retire trace has exactly the same meaning as ppc_core's, so the two
//   cores can be compared step by step.

module ppc_pipe #(
    parameter logic [31:0] RESET_PC = 32'h0000_0100,
    parameter logic [31:0] PVR      = 32'h0008_0200
) (
    input  logic        clk,
    input  logic        rst,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic [31:0] dmem_addr,
    output logic [1:0]  dmem_size,
    output logic        dmem_re,
    output logic        dmem_we,
    output logic [31:0] dmem_wdata,
    input  logic [31:0] dmem_rdata,
    output logic        trap,
    output logic [31:0] trap_pc,
    output logic [31:0] trap_insn,
    output logic [63:0] instret,
    output logic [63:0] cycles,
    output logic        tr_valid,
    output logic [31:0] tr_pc, tr_insn,
    output logic        tr_rf_we,  output logic [4:0] tr_rf_idx, output logic [31:0] tr_rf_val,
    output logic        tr_up_we,  output logic [4:0] tr_up_idx, output logic [31:0] tr_up_val,
    output logic [31:0] tr_cr, tr_xer, tr_lr, tr_ctr,
    output logic        tr_st,     output logic [31:0] tr_st_addr, tr_st_data,
    output logic [1:0]  tr_st_size,
    // performance counters
    output logic [63:0] stall_ld_use,
    output logic [63:0] flush_branch
);
    // ------------------------------------------------------------------
    // Architectural state
    // ------------------------------------------------------------------
    logic [31:0] gpr [32];
    logic [31:0] cr, xer, lr, ctr, msr, srr0, srr1, dec_r, hid0, hid1;
    logic [31:0] sprg [4];
    logic [63:0] tb;

    // ------------------------------------------------------------------
    // Pipeline registers
    // ------------------------------------------------------------------
    logic [31:0] pc_f;

    logic        d_valid;  logic [31:0] d_pc, d_insn;            // IF/ID
    logic        e_valid;  logic [31:0] e_pc, e_insn;            // ID/EX
    logic [31:0] e_pred_pc;                                       // predicted next PC
    logic        e_ms_active; logic [4:0] e_ms_reg;               // lmw/stmw sequencer

    typedef struct packed {
        logic        valid;
        logic [31:0] pc, insn;
        logic        rf_we, ld;  logic [4:0] rf_idx; logic [31:0] rf_val;
        logic        up_we;      logic [4:0] up_idx; logic [31:0] up_val;
        logic        st;         logic [31:0] ea, st_data;
        logic [1:0]  size;       logic sext, brev;
        logic        retire;
        logic [31:0] cr, xer, lr, ctr;   // trace snapshot after this step
    } stage_t;

    stage_t m, w;                                                 // EX/MEM, MEM/WB

    logic trapping;
    logic [1:0] drain;

    // ------------------------------------------------------------------
    // IF
    // ------------------------------------------------------------------
    assign imem_addr = pc_f;

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
    wire [4:0] e_ms_cur = e_ms_active ? e_ms_reg : e_rs;

    function automatic logic [31:0] fwd(input logic [4:0] idx);
        if      (m.valid && m.rf_we && !m.ld && m.rf_idx == idx) fwd = m.rf_val;
        else if (m.valid && m.up_we && m.up_idx == idx)          fwd = m.up_val;
        else if (w.valid && w.rf_we && w.rf_idx == idx)          fwd = w.rf_val;
        else if (w.valid && w.up_we && w.up_idx == idx)          fwd = w.up_val;
        else                                                     fwd = gpr[idx];
    endfunction

    wire [31:0] e_va = fwd(e_ra);
    wire [31:0] e_vb = fwd(e_rb);
    wire [31:0] e_vs = fwd(e_rs);
    wire [31:0] e_vm = fwd(e_ms_cur);

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
                  ((uses_ra && m.rf_idx == e_ra) || (uses_rb && m.rf_idx == e_rb) ||
                   (uses_rs && m.rf_idx == e_rs) || (e_opcd == 6'd47 && m.rf_idx == e_ms_cur));

    // ------------------------------------------------------------------
    // EX: execute
    // ------------------------------------------------------------------
    logic [31:0] next_pc, wa_val, wb_val, cr_n, xer_n, lr_n, ctr_n, spr_val, ea, st_data;
    logic        wa_en, wb_en, spr_we, msr_we, illegal, retire, ms_active_n;
    logic        ld, st, ld_sext, ld_brev;
    logic [4:0]  wa_idx, ms_reg_n, ms_cur_unused;
    logic [9:0]  spr_idx;
    logic [1:0]  msize;

    ppc_exec #(.PVR(PVR)) u_exec (
        .insn(e_insn), .pc(e_pc),
        .va(e_va), .vb(e_vb), .vs(e_vs), .v_ms(e_vm),
        .ms_active(e_ms_active), .ms_reg(e_ms_reg),
        .cr, .xer, .lr, .ctr, .msr, .srr0, .srr1, .dec_r, .hid0, .hid1,
        .sprg0(sprg[0]), .sprg1(sprg[1]), .sprg2(sprg[2]), .sprg3(sprg[3]), .tb,
        .next_pc, .wa_en, .wa_idx, .wa_val, .wb_en, .wb_val,
        .cr_n, .xer_n, .lr_n, .ctr_n, .spr_we, .spr_idx, .spr_val, .msr_we,
        .illegal, .retire, .ms_active_n, .ms_reg_n, .ms_cur(ms_cur_unused),
        .ld, .st, .ld_sext, .ld_brev, .msize, .ea, .st_data
    );

    wire ex_go     = e_valid && !ld_use && !trapping;
    wire ex_commit = ex_go && !illegal;
    wire ms_cont   = ex_commit && ms_active_n;                    // lmw/stmw has more steps
    wire redirect  = ex_commit && retire && (next_pc != e_pred_pc);
    wire hold      = ld_use || ms_cont;

    // ------------------------------------------------------------------
    // MEM
    // ------------------------------------------------------------------
    assign dmem_addr  = m.ea;
    assign dmem_size  = m.size;
    assign dmem_re    = m.valid && m.ld;
    assign dmem_we    = m.valid && m.st;
    assign dmem_wdata = m.st_data;

    wire [31:0] m_ld_val = ppc_pkg::ld_format(dmem_rdata, m.size, m.sext, m.brev);

    // ------------------------------------------------------------------
    // WB / trace
    // ------------------------------------------------------------------
    assign tr_valid  = w.valid;
    assign tr_pc     = w.pc;      assign tr_insn   = w.insn;
    assign tr_rf_we  = w.rf_we;   assign tr_rf_idx = w.rf_idx;  assign tr_rf_val = w.rf_val;
    assign tr_up_we  = w.up_we;   assign tr_up_idx = w.up_idx;  assign tr_up_val = w.up_val;
    assign tr_cr = w.cr; assign tr_xer = w.xer; assign tr_lr = w.lr; assign tr_ctr = w.ctr;
    assign tr_st = w.st; assign tr_st_addr = w.ea; assign tr_st_data = w.st_data; assign tr_st_size = w.size;

    // ------------------------------------------------------------------
    // Sequential
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            pc_f <= RESET_PC;
            d_valid <= 0; d_pc <= 0; d_insn <= 0;
            e_valid <= 0; e_pc <= 0; e_insn <= 0; e_pred_pc <= 0;
            e_ms_active <= 0; e_ms_reg <= 0;
            m <= '0; w <= '0;
            cr <= 0; xer <= 0; lr <= 0; ctr <= 0; msr <= 0;
            srr0 <= 0; srr1 <= 0; dec_r <= 0; hid0 <= 0; hid1 <= 0;
            for (int i = 0; i < 4; i++) sprg[i] <= 0;
            for (int i = 0; i < 32; i++) gpr[i] <= 0;
            tb <= 0;
            trapping <= 0; drain <= 0;
            trap <= 0; trap_pc <= 0; trap_insn <= 0;
            instret <= 0; cycles <= 0; stall_ld_use <= 0; flush_branch <= 0;
        end else if (!trap) begin
            cycles <= cycles + 64'd1;
            tb <= tb + 64'd1;
            dec_r <= dec_r - 32'd1;
            if (ld_use)   stall_ld_use <= stall_ld_use + 64'd1;
            if (redirect) flush_branch <= flush_branch + 64'd1;

            // ---- WB ----
            if (w.valid) begin
                if (w.up_we) gpr[w.up_idx] <= w.up_val;
                if (w.rf_we) gpr[w.rf_idx] <= w.rf_val;
                if (w.retire) instret <= instret + 64'd1;
            end

            // ---- MEM -> WB ----
            w <= m;
            if (m.ld) w.rf_val <= m_ld_val;

            // ---- EX -> MEM ----
            m.valid   <= ex_commit;
            m.pc      <= e_pc;       m.insn   <= e_insn;
            m.rf_we   <= wa_en | ld; m.ld     <= ld;
            m.rf_idx  <= wa_idx;     m.rf_val <= wa_val;
            m.up_we   <= wb_en;      m.up_idx <= e_ra;    m.up_val <= wb_val;
            m.st      <= st;         m.ea     <= ea;      m.st_data <= st_data;
            m.size    <= msize;      m.sext   <= ld_sext; m.brev    <= ld_brev;
            m.retire  <= retire;
            m.cr <= cr_n; m.xer <= xer_n; m.lr <= lr_n; m.ctr <= ctr_n;

            if (ex_commit) begin
                cr <= cr_n; xer <= xer_n; lr <= lr_n; ctr <= ctr_n;
                if (msr_we) msr <= e_vs;
                if (spr_we) case (spr_idx)
                    10'd22:  dec_r <= spr_val;
                    10'd26:  srr0 <= spr_val;
                    10'd27:  srr1 <= spr_val;
                    10'd272, 10'd273, 10'd274, 10'd275: sprg[spr_idx[1:0]] <= spr_val;
                    10'd284: tb[31:0]  <= spr_val;
                    10'd285: tb[63:32] <= spr_val;
                    10'd1008: hid0 <= spr_val;
                    10'd1009: hid1 <= spr_val;
                    default: ;
                endcase
                e_ms_active <= ms_active_n;
                e_ms_reg    <= ms_reg_n;
            end

            // ---- trap: stop the front end, let MEM and WB drain ----
            if (ex_go && illegal) begin
                trapping <= 1; trap_pc <= e_pc; trap_insn <= e_insn; drain <= 2'd2;
            end
            if (trapping) begin
                if (drain == 0) trap <= 1;
                else drain <= drain - 2'd1;
            end

            // ---- front end ----
            if (trapping || (ex_go && illegal)) begin
                d_valid <= 0; e_valid <= 0;
            end else if (redirect) begin
                pc_f <= next_pc;
                d_valid <= 0; e_valid <= 0;
            end else if (!hold) begin
                e_valid <= d_valid; e_pc <= d_pc; e_insn <= d_insn;
                e_pred_pc <= id_taken ? id_target : d_pc + 32'd4;
                if (id_taken) begin
                    pc_f <= id_target;                // drop the sequential fetch
                    d_valid <= 0;
                end else begin
                    d_valid <= 1; d_pc <= pc_f; d_insn <= imem_rdata;
                    pc_f <= pc_f + 32'd4;
                end
            end
        end
    end
endmodule
