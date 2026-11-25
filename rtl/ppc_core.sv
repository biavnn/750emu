// g3core - stage 0 reference core
//
// Single-cycle: one instruction (or one lmw/stmw step) per clock, with
// combinational instruction and data memory. All instruction semantics live in
// ppc_exec; this module only holds architectural state. It is the golden RTL
// model the pipelined core is checked against in lockstep.
//
// Not yet implemented (trap=1): FPU, MMU/exceptions, string ops,
// lwarx/stwcx., dcbz, tw/twi, sc, rfi.

module ppc_core #(
    parameter logic [31:0] RESET_PC = 32'h0000_0100,
    parameter logic [31:0] PVR      = 32'h0008_0200
) (
    input  logic        clk,
    input  logic        rst,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic [31:0] dmem_addr,
    output logic [1:0]  dmem_size,    // 0=byte 1=half 2=word
    output logic        dmem_re,
    output logic        dmem_we,
    output logic [31:0] dmem_wdata,   // right-aligned
    input  logic [31:0] dmem_rdata,   // right-aligned, zero-extended
    output logic        trap,
    output logic [31:0] trap_pc,
    output logic [31:0] trap_insn,
    output logic [63:0] instret,
    output logic [63:0] cycles,
    // retire trace: describes the step that commits at the next clock edge
    output logic        tr_valid,
    output logic [31:0] tr_pc, tr_insn,
    output logic        tr_rf_we,  output logic [4:0] tr_rf_idx, output logic [31:0] tr_rf_val,
    output logic        tr_up_we,  output logic [4:0] tr_up_idx, output logic [31:0] tr_up_val,
    output logic [31:0] tr_cr, tr_xer, tr_lr, tr_ctr,
    output logic        tr_st,     output logic [31:0] tr_st_addr, tr_st_data,
    output logic [1:0]  tr_st_size
);
    logic [31:0] pc;
    logic [31:0] gpr [32];
    logic [31:0] cr, xer, lr, ctr, msr, srr0, srr1, dec_r, hid0, hid1;
    logic [31:0] sprg [4];
    logic [63:0] tb;
    logic        ms_active;
    logic [4:0]  ms_reg;

    wire [31:0] insn = imem_rdata;
    assign imem_addr = pc;

    // execute outputs
    logic [31:0] next_pc, wa_val, wb_val, cr_n, xer_n, lr_n, ctr_n, spr_val, ea, st_data;
    logic        wa_en, wb_en, spr_we, msr_we, illegal, retire, ms_active_n;
    logic        ld, st, ld_sext, ld_brev;
    logic [4:0]  wa_idx, ms_reg_n, ms_cur;
    logic [9:0]  spr_idx;
    logic [1:0]  msize;

    ppc_exec #(.PVR(PVR)) u_exec (
        .insn, .pc,
        .va(gpr[insn[20:16]]), .vb(gpr[insn[15:11]]), .vs(gpr[insn[25:21]]), .v_ms(gpr[ms_cur]),
        .ms_active, .ms_reg,
        .cr, .xer, .lr, .ctr, .msr, .srr0, .srr1, .dec_r, .hid0, .hid1,
        .sprg0(sprg[0]), .sprg1(sprg[1]), .sprg2(sprg[2]), .sprg3(sprg[3]), .tb,
        .next_pc, .wa_en, .wa_idx, .wa_val, .wb_en, .wb_val,
        .cr_n, .xer_n, .lr_n, .ctr_n, .spr_we, .spr_idx, .spr_val, .msr_we,
        .illegal, .retire, .ms_active_n, .ms_reg_n, .ms_cur,
        .ld, .st, .ld_sext, .ld_brev, .msize, .ea, .st_data
    );

    wire [31:0] ld_val = ppc_pkg::ld_format(dmem_rdata, msize, ld_sext, ld_brev);
    wire        rf_we  = wa_en | ld;
    wire [31:0] rf_val = ld ? ld_val : wa_val;
    wire        commit = ~rst & ~trap & ~illegal;

    assign dmem_addr  = ea;
    assign dmem_size  = msize;
    assign dmem_re    = ld & commit;
    assign dmem_we    = st & commit;
    assign dmem_wdata = st_data;

    // trace
    assign tr_valid   = commit;
    assign tr_pc      = pc;
    assign tr_insn    = insn;
    assign tr_rf_we   = rf_we;  assign tr_rf_idx = wa_idx;      assign tr_rf_val = rf_val;
    assign tr_up_we   = wb_en;  assign tr_up_idx = insn[20:16]; assign tr_up_val = wb_val;
    assign tr_cr = cr_n; assign tr_xer = xer_n; assign tr_lr = lr_n; assign tr_ctr = ctr_n;
    assign tr_st = st; assign tr_st_addr = ea; assign tr_st_data = st_data; assign tr_st_size = msize;

    always_ff @(posedge clk) begin
        if (rst) begin
            pc <= RESET_PC;
            cr <= 0; xer <= 0; lr <= 0; ctr <= 0; msr <= 0;
            srr0 <= 0; srr1 <= 0; dec_r <= 0; hid0 <= 0; hid1 <= 0;
            for (int i = 0; i < 4; i++) sprg[i] <= 0;
            for (int i = 0; i < 32; i++) gpr[i] <= 0;
            tb <= 0;
            ms_active <= 0; ms_reg <= 0;
            trap <= 0; trap_pc <= 0; trap_insn <= 0;
            instret <= 0; cycles <= 0;
        end else if (!trap) begin
            cycles <= cycles + 64'd1;
            tb <= tb + 64'd1;
            dec_r <= dec_r - 32'd1;
            if (illegal) begin
                trap <= 1; trap_pc <= pc; trap_insn <= insn;
            end else begin
                pc  <= next_pc;
                cr  <= cr_n;  xer <= xer_n;  lr <= lr_n;  ctr <= ctr_n;
                if (wb_en) gpr[insn[20:16]] <= wb_val;
                if (rf_we) gpr[wa_idx] <= rf_val;   // load result wins over update (invalid form)
                if (msr_we) msr <= gpr[insn[25:21]];
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
                ms_active <= ms_active_n; ms_reg <= ms_reg_n;
                if (retire) instret <= instret + 64'd1;
            end
        end
    end
endmodule
