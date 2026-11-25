// Shared decode + execute logic for g3core.
//
// Purely combinational: given one instruction, its operand values and the
// current special-register state, produce every architectural side effect.
// Used unchanged by the single-cycle reference core (ppc_core) and the EX stage
// of the pipelined core (ppc_pipe), so both implement identical semantics.
//
// Bit numbering note: PowerPC documents number bits 0 (MSB) .. 31 (LSB).
// Here IBM bit i is [31-i].

module ppc_exec #(
    parameter logic [31:0] PVR = 32'h0008_0200
) (
    input  logic [31:0] insn,
    input  logic [31:0] pc,
    input  logic [31:0] va,        // GPR[RA]
    input  logic [31:0] vb,        // GPR[RB]
    input  logic [31:0] vs,        // GPR[RS/RT]
    input  logic [31:0] v_ms,      // GPR[ms_ridx]
    input  logic        ms_active, // multi-step instruction in progress
    input  logic [6:0]  ms_reg,    //   its step counter (register number for lmw/stmw)
    input  logic        resv,      // reservation from lwarx
    input  logic [31:0] resv_addr,
    input  logic [31:0] cr, xer, lr, ctr, msr, srr0, srr1, dec_r, hid0, hid1,
    input  logic [31:0] sprg0, sprg1, sprg2, sprg3,
    input  logic [63:0] tb,

    output logic [31:0] next_pc,
    output logic        wa_en,      // non-load GPR result
    output logic [5:0]  wa_idx,     // destination for result or load data (32 = hidden temporary)
    output logic [31:0] wa_val,
    output logic        wb_en,      // RA <- EA (update forms)
    output logic [31:0] wb_val,
    output logic [31:0] cr_n, xer_n, lr_n, ctr_n,
    output logic        spr_we,
    output logic [9:0]  spr_idx,
    output logic [31:0] spr_val,
    input  logic        int_ext,    // external interrupt request (level)
    input  logic        int_dec,    // decrementer interrupt pending
    input  logic        isi,        // instruction fetch faulted (insn is not valid)
    input  logic [31:0] isi_bits,   // SRR1 reason bits for the ISI
    input  logic        xspr_valid, // f_spr names a register held outside (MMU)
    input  logic [31:0] xspr_rdata,
    input  logic [31:0] sr_rdata,   // SR[sr_idx]
    output logic        take_int,   // this step takes an asynchronous interrupt
    output logic        ctx_sync,   // translation context changed: refetch what follows
    output logic        sr_we,      // SR[sr_idx] <- vs
    output logic [3:0]  sr_idx,
    output logic        tlbie,      // invalidate TLB entries for EA = vb
    output logic [31:0] msr_n,      // MSR after this step
    output logic        srr_we,     // exception entry: write SRR0/SRR1
    output logic [31:0] srr0_n, srr1_n,
    output logic        exc,        // this step enters an exception (no other side effects)
    output logic        int_ack_dec,
    output logic        retire,     // 0 for non-final steps of a multi-step instruction
    output logic        ms_active_n,
    output logic [6:0]  ms_reg_n,
    output logic [5:0]  ms_ridx,    // register the sequencer reads this step (v_ms)
    output logic        ms_ruse,    //   and whether it may be read at all
    output logic        ld, st, ld_sext, ld_brev,
    output logic        ld_mrg,     // string load: merge byte into wa_val at ld_pos
    output logic [1:0]  ld_pos,
    output logic        ld_acc,     // page-crossing load: shift byte into wa_val
    output logic [1:0]  fsize,      // size used to format the loaded value
    output logic        resv_set, resv_clr,
    output logic [1:0]  msize,      // size of this step's memory access
    output logic [31:0] ea, st_data
);

    logic [31:0] sprg [4];
    assign sprg = '{sprg0, sprg1, sprg2, sprg3};

    // Implemented MSR bits: EE PR FP ME FE0 SE BE FE1 IP IR DR RI
    localparam logic [31:0] MSR_MASK = 32'h0000_FF72;

    logic        upd, nonplain, xpage, c_last;
    logic [31:0] ea_base;
    logic [2:0]  c_nb;
    logic [1:0]  ck;
    logic [6:0]  sk, sn;
    logic [4:0]  ms_cur;
    logic        msr_we, illegal, priv, trapc, fpu, sc_c, rfi_c;
    logic [19:0] exc_vec;
    wire         pr = msr[14];
    logic        rec_en; logic [31:0] rec_val;   // Rc=1 -> CR0
    logic        oe_en;  logic oe_ov;            // OE=1 -> XER[OV,SO]

    // ------------------------------------------------------------------
    // Instruction fields
    // ------------------------------------------------------------------
    wire [5:0]  opcd  = insn[31:26];
    wire [4:0]  f_rt  = insn[25:21];      // RT / RS / BO
    wire [4:0]  f_ra  = insn[20:16];      // RA / BI
    wire [4:0]  f_rb  = insn[15:11];      // RB / SH
    wire [9:0]  xo10  = insn[10:1];
    wire [8:0]  xo9   = insn[9:1];
    wire        f_oe  = insn[10];
    wire        f_rc  = insn[0];
    wire [31:0] simm  = {{16{insn[15]}}, insn[15:0]};
    wire [31:0] uimm  = {16'b0, insn[15:0]};
    wire [4:0]  f_mb  = insn[10:6];
    wire [4:0]  f_me  = insn[5:1];
    wire [2:0]  f_crfd = insn[25:23];
    wire [2:0]  f_crfs = insn[20:18];
    wire [9:0]  f_spr = {insn[15:11], insn[20:16]};
    wire [7:0]  f_crm = insn[19:12];

    wire [31:0] va0 = (f_ra == 5'd0) ? 32'd0 : va;
    // register selectors are kept out of the main decode block: the values they
    // select (sr_rdata, xspr_rdata) feed back into it
    // Multi-step sequencer register selection (also outside the main block).
    //   lmw/stmw: the register being moved; string ops: the register holding
    //   byte sk; anything else: the hidden temporary used by page-crossing loads.
    wire is_mw  = (opcd == 6'd46 || opcd == 6'd47);
    wire is_str = (opcd == 6'd31) && (xo10 == 10'd597 || xo10 == 10'd533 || xo10 == 10'd725 || xo10 == 10'd661);
    assign sk      = ms_active ? ms_reg : 7'd0;
    assign ms_cur  = ms_active ? ms_reg[4:0] : f_rt;
    assign ms_ridx = is_mw ? {1'b0, ms_cur} : is_str ? {1'b0, f_rt + sk[6:2]} : 6'd32;
    assign ms_ruse = ms_active | is_mw | is_str;

    assign spr_idx = f_spr;
    assign sr_idx  = (opcd == 6'd31 && (xo10 == 10'd242 || xo10 == 10'd659)) ? vb[31:28] : insn[19:16];

    wire xer_so = xer[31];
    wire xer_ca = xer[29];

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    function automatic logic [31:0] rotl32(input logic [31:0] x, input logic [4:0] n);
        rotl32 = (x << n) | (x >> (6'd32 - {1'b0, n}));
    endfunction

    // MASK(mb, me) with IBM bit numbering, wrapping when mb > me
    function automatic logic [31:0] ppc_mask(input logic [4:0] mb, input logic [4:0] me);
        logic [31:0] m1, m2;
        m1 = 32'hFFFF_FFFF >> mb;
        m2 = 32'hFFFF_FFFF << (5'd31 - me);
        ppc_mask = (mb <= me) ? (m1 & m2) : (m1 | m2);
    endfunction

    function automatic logic [3:0] cmp4(input logic [31:0] a, input logic [31:0] b,
                                        input logic is_signed, input logic so);
        logic lt, gt;
        lt = is_signed ? ($signed(a) < $signed(b)) : (a < b);
        gt = is_signed ? ($signed(a) > $signed(b)) : (a > b);
        cmp4 = {lt, gt, a == b, so};
    endfunction

    function automatic logic [31:0] clz32(input logic [31:0] x);
        clz32 = 32'd32;
        for (int i = 0; i < 32; i++)
            if (x[i]) clz32 = 32'(31 - i);
    endfunction

    // tw/twi condition: TO = {lt, gt, eq, ltu, gtu}
    function automatic logic trap_cond(input logic [31:0] a, input logic [31:0] b,
                                       input logic [4:0] to);
        trap_cond = (to[4] & ($signed(a) < $signed(b))) | (to[3] & ($signed(a) > $signed(b))) |
                    (to[2] & (a == b)) | (to[1] & (a < b)) | (to[0] & (a > b));
    endfunction

    function automatic logic crbit(input logic [31:0] c, input logic [4:0] i);
        crbit = c[5'd31 - i];
    endfunction

    // ------------------------------------------------------------------
    // Shared adder (add/sub/carry/extended forms)
    // ------------------------------------------------------------------
    logic [31:0] add_a, add_b;
    logic        add_cin;

    always_comb begin
        add_a = va;  add_b = vb;  add_cin = 1'b0;
        case (opcd)
            6'd12, 6'd13: begin add_a = va;  add_b = simm; end               // addic, addic.
            6'd8:         begin add_a = ~va; add_b = simm; add_cin = 1'b1; end // subfic
            6'd31: case (xo9)
                9'd266, 9'd10: ;                                              // add, addc
                9'd138: add_cin = xer_ca;                                     // adde
                9'd234: begin add_b = 32'hFFFF_FFFF; add_cin = xer_ca; end    // addme
                9'd202: begin add_b = 32'd0;         add_cin = xer_ca; end    // addze
                9'd40, 9'd8: begin add_a = ~va; add_cin = 1'b1; end           // subf, subfc
                9'd136: begin add_a = ~va; add_cin = xer_ca; end              // subfe
                9'd232: begin add_a = ~va; add_b = 32'hFFFF_FFFF; add_cin = xer_ca; end // subfme
                9'd200: begin add_a = ~va; add_b = 32'd0; add_cin = xer_ca; end         // subfze
                9'd104: begin add_a = ~va; add_b = 32'd0; add_cin = 1'b1; end           // neg
                default: ;
            endcase
            default: ;
        endcase
    end

    wire [32:0] add_full = {1'b0, add_a} + {1'b0, add_b} + {32'd0, add_cin};
    wire [31:0] add_sum  = add_full[31:0];
    wire        add_ca   = add_full[32];
    wire        add_ov   = (add_a[31] == add_b[31]) && (add_sum[31] != add_a[31]);

    // ------------------------------------------------------------------
    // Multiply / divide / shift units
    // ------------------------------------------------------------------
    wire signed [63:0] mul_ss = 64'($signed(va)) * 64'($signed(vb));
    wire        [63:0] mul_uu = {32'd0, va} * {32'd0, vb};
    wire signed [63:0] mul_si = 64'($signed(va)) * 64'($signed(simm));
    wire        mullw_ov = (mul_ss[63:32] != {32{mul_ss[31]}});

    wire        div_zero = (vb == 32'd0);
    wire        div_sovf = (va == 32'h8000_0000) && (vb == 32'hFFFF_FFFF);
    wire [31:0] divw_r   = (div_zero || div_sovf) ? 32'd0 : 32'($signed(va) / $signed(vb));
    wire [31:0] divwu_r  = div_zero ? 32'd0 : va / vb;

    wire [5:0]  shn   = vb[5:0];
    wire [31:0] slw_r = shn[5] ? 32'd0 : (vs << shn[4:0]);
    wire [31:0] srw_r = shn[5] ? 32'd0 : (vs >> shn[4:0]);
    wire [4:0]  sraw_n = shn[5] ? 5'd31 : shn[4:0];
    wire [31:0] sraw_r = 32'($signed(vs) >>> sraw_n);
    wire        sraw_ca = vs[31] & (shn[5] | (|(vs & ~(32'hFFFF_FFFF << shn[4:0]))));
    wire [31:0] srawi_r = 32'($signed(vs) >>> f_rb);
    wire        srawi_ca = vs[31] & (|(vs & ~(32'hFFFF_FFFF << f_rb)));

    // ------------------------------------------------------------------
    // Branch condition
    // ------------------------------------------------------------------
    wire [4:0]  bo     = insn[25:21];   // bo[4]=BO_0 ... bo[0]=BO_4
    wire [4:0]  bi     = insn[20:16];
    wire [31:0] ctr_m1 = ctr - 32'd1;
    wire        ctr_ok = bo[2] | ((ctr_m1 != 32'd0) ^ bo[1]);
    wire        cond_ok = bo[4] | (crbit(cr, bi) == bo[3]);
    wire [31:0] bd_off = {{16{insn[15]}}, insn[15:2], 2'b00};
    wire [31:0] li_off = {{6{insn[25]}}, insn[25:2], 2'b00};

    // ------------------------------------------------------------------
    // Main decode / execute (combinational)
    // ------------------------------------------------------------------
    // lmw/stmw effective address
    wire [31:0] ms_ea  = va0 + simm + {25'd0, ms_cur - f_rt, 2'b00};

    always_comb begin
        next_pc = pc + 32'd4;
        wa_en = 1'b0; wa_idx = {1'b0, f_rt}; wa_val = 32'd0;
        nonplain = 1'b0; ld_mrg = 1'b0; ld_pos = 2'd0; ld_acc = 1'b0;
        resv_set = 1'b0; resv_clr = 1'b0;
        sn = 7'd0;
        wb_en = 1'b0; wb_val = 32'd0;
        cr_n = cr; xer_n = xer; lr_n = lr; ctr_n = ctr;
        rec_en = 1'b0; rec_val = 32'd0;
        oe_en = 1'b0; oe_ov = 1'b0;
        spr_we = 1'b0; spr_val = vs;
        msr_we = 1'b0;
        illegal = 1'b0; priv = 1'b0; trapc = 1'b0; fpu = 1'b0; sc_c = 1'b0; rfi_c = 1'b0;
        ctx_sync = 1'b0; sr_we = 1'b0; tlbie = 1'b0;
        retire = 1'b1;
        ms_active_n = 1'b0; ms_reg_n = 7'd0;
        ld = 1'b0; st = 1'b0; ld_sext = 1'b0; ld_brev = 1'b0; upd = 1'b0;
        msize = 2'd2; ea = va0 + simm; st_data = vs;

        case (opcd)
            // ---------------- immediate arithmetic ----------------
            6'd14: begin wa_en = 1; wa_val = va0 + simm; end                         // addi
            6'd15: begin wa_en = 1; wa_val = va0 + {insn[15:0], 16'd0}; end          // addis
            6'd12, 6'd13: begin                                                      // addic(.)
                wa_en = 1; wa_val = add_sum; xer_n[29] = add_ca;
                rec_en = opcd[0]; rec_val = add_sum;
            end
            6'd8:  begin wa_en = 1; wa_val = add_sum; xer_n[29] = add_ca; end        // subfic
            6'd7:  begin wa_en = 1; wa_val = mul_si[31:0]; end                       // mulli
            6'd11: cr_n[31 - 4*f_crfd -: 4] = cmp4(va, simm, 1'b1, xer_so);          // cmpi
            6'd10: cr_n[31 - 4*f_crfd -: 4] = cmp4(va, uimm, 1'b0, xer_so);          // cmpli

            // ---------------- immediate logical ----------------
            // (RS is in the RT field; the destination is RA)
            6'd24: begin wa_en = 1; wa_idx = {1'b0, f_ra}; wa_val = vs | uimm; end                  // ori
            6'd25: begin wa_en = 1; wa_idx = {1'b0, f_ra}; wa_val = vs | {insn[15:0], 16'd0}; end   // oris
            6'd26: begin wa_en = 1; wa_idx = {1'b0, f_ra}; wa_val = vs ^ uimm; end                  // xori
            6'd27: begin wa_en = 1; wa_idx = {1'b0, f_ra}; wa_val = vs ^ {insn[15:0], 16'd0}; end   // xoris
            6'd28: begin wa_en = 1; wa_idx = {1'b0, f_ra}; wa_val = vs & uimm;                      // andi.
                         rec_en = 1; rec_val = vs & uimm; end
            6'd29: begin wa_en = 1; wa_idx = {1'b0, f_ra}; wa_val = vs & {insn[15:0], 16'd0};       // andis.
                         rec_en = 1; rec_val = vs & {insn[15:0], 16'd0}; end

            // ---------------- rotates ----------------
            6'd21: begin                                                             // rlwinm
                wa_en = 1; wa_idx = {1'b0, f_ra};
                wa_val = rotl32(vs, f_rb) & ppc_mask(f_mb, f_me);
                rec_en = f_rc; rec_val = wa_val;
            end
            6'd23: begin                                                             // rlwnm
                wa_en = 1; wa_idx = {1'b0, f_ra};
                wa_val = rotl32(vs, vb[4:0]) & ppc_mask(f_mb, f_me);
                rec_en = f_rc; rec_val = wa_val;
            end
            6'd20: begin                                                             // rlwimi
                wa_en = 1; wa_idx = {1'b0, f_ra};
                wa_val = (rotl32(vs, f_rb) & ppc_mask(f_mb, f_me)) | (va & ~ppc_mask(f_mb, f_me));
                rec_en = f_rc; rec_val = wa_val;
            end

            // ---------------- branches ----------------
            6'd18: begin                                                             // b
                next_pc = (insn[1] ? 32'd0 : pc) + li_off;
                if (insn[0]) lr_n = pc + 32'd4;
            end
            6'd16: begin                                                             // bc
                if (!bo[2]) ctr_n = ctr_m1;
                if (ctr_ok && cond_ok) next_pc = (insn[1] ? 32'd0 : pc) + bd_off;
                if (insn[0]) lr_n = pc + 32'd4;
            end
            6'd19: case (xo10)
                10'd16: begin                                                        // bclr
                    if (!bo[2]) ctr_n = ctr_m1;
                    if (ctr_ok && cond_ok) next_pc = {lr[31:2], 2'b00};
                    if (insn[0]) lr_n = pc + 32'd4;
                end
                10'd528: begin                                                       // bcctr
                    if (cond_ok) next_pc = {ctr[31:2], 2'b00};
                    if (insn[0]) lr_n = pc + 32'd4;
                end
                10'd257: cr_n[31 - f_rt] =   crbit(cr, f_ra) &  crbit(cr, f_rb);   // crand
                10'd449: cr_n[31 - f_rt] =   crbit(cr, f_ra) |  crbit(cr, f_rb);   // cror
                10'd193: cr_n[31 - f_rt] =   crbit(cr, f_ra) ^  crbit(cr, f_rb);   // crxor
                10'd225: cr_n[31 - f_rt] = ~(crbit(cr, f_ra) &  crbit(cr, f_rb));  // crnand
                10'd33:  cr_n[31 - f_rt] = ~(crbit(cr, f_ra) |  crbit(cr, f_rb));  // crnor
                10'd289: cr_n[31 - f_rt] = ~(crbit(cr, f_ra) ^  crbit(cr, f_rb));  // creqv
                10'd129: cr_n[31 - f_rt] =   crbit(cr, f_ra) & ~crbit(cr, f_rb);   // crandc
                10'd417: cr_n[31 - f_rt] =   crbit(cr, f_ra) | ~crbit(cr, f_rb);   // crorc
                10'd0:   cr_n[31 - 4*f_crfd -: 4] = cr[31 - 4*f_crfs -: 4];         // mcrf
                10'd150: ;                                                           // isync
                10'd50:  if (pr) priv = 1; else rfi_c = 1;                           // rfi
                default: illegal = 1;
            endcase

            // ---------------- loads / stores (D-form) ----------------
            6'd32, 6'd33: begin ld = 1; msize = 2'd2; upd = opcd[0]; end             // lwz(u)
            6'd34, 6'd35: begin ld = 1; msize = 2'd0; upd = opcd[0]; end             // lbz(u)
            6'd40, 6'd41: begin ld = 1; msize = 2'd1; upd = opcd[0]; end             // lhz(u)
            6'd42, 6'd43: begin ld = 1; msize = 2'd1; ld_sext = 1; upd = opcd[0]; end // lha(u)
            6'd36, 6'd37: begin st = 1; msize = 2'd2; upd = opcd[0]; end             // stw(u)
            6'd38, 6'd39: begin st = 1; msize = 2'd0; upd = opcd[0]; end             // stb(u)
            6'd44, 6'd45: begin st = 1; msize = 2'd1; upd = opcd[0]; end             // sth(u)
            6'd46, 6'd47: begin                                                      // lmw / stmw
                ea = ms_ea; nonplain = 1;
                if (opcd == 6'd46) begin ld = 1; wa_idx = {1'b0, ms_cur}; end
                else begin st = 1; st_data = v_ms; end
                if (ms_cur != 5'd31) begin
                    next_pc = pc; retire = 1'b0;
                    ms_active_n = 1'b1; ms_reg_n = {2'b0, ms_cur} + 7'd1;
                end
            end

            // ---------------- opcode 31 ----------------
            6'd17: sc_c = 1;                                                         // sc
            6'd3:  trapc = trap_cond(va, simm, f_rt);                                // twi

            // floating point: not implemented yet. With MSR[FP]=0 these raise
            // "FP unavailable" exactly like a real CPU, so an OS can emulate them.
            6'd48, 6'd49, 6'd50, 6'd51, 6'd52, 6'd53, 6'd54, 6'd55, 6'd59, 6'd63: fpu = 1;

            6'd31: begin
                ea = va0 + vb;
                case (xo9)
                    // XO-form arithmetic (OE in bit 10)
                    9'd266, 9'd10, 9'd138, 9'd234, 9'd202,
                    9'd40,  9'd8,  9'd136, 9'd232, 9'd200, 9'd104: begin
                        wa_en = 1; wa_val = add_sum;
                        rec_en = f_rc; rec_val = add_sum;
                        oe_en = f_oe; oe_ov = add_ov;
                        if (xo9 != 9'd266 && xo9 != 9'd40 && xo9 != 9'd104)
                            xer_n[29] = add_ca;                 // carrying forms
                    end
                    9'd235: begin wa_en = 1; wa_val = mul_ss[31:0];                   // mullw
                                  rec_en = f_rc; rec_val = mul_ss[31:0];
                                  oe_en = f_oe; oe_ov = mullw_ov; end
                    9'd75:  begin wa_en = 1; wa_val = mul_ss[63:32];                  // mulhw
                                  rec_en = f_rc; rec_val = mul_ss[63:32]; end
                    9'd11:  begin wa_en = 1; wa_val = mul_uu[63:32];                  // mulhwu
                                  rec_en = f_rc; rec_val = mul_uu[63:32]; end
                    9'd491: begin wa_en = 1; wa_val = divw_r;                         // divw
                                  rec_en = f_rc; rec_val = divw_r;
                                  oe_en = f_oe; oe_ov = div_zero | div_sovf; end
                    9'd459: begin wa_en = 1; wa_val = divwu_r;                        // divwu
                                  rec_en = f_rc; rec_val = divwu_r;
                                  oe_en = f_oe; oe_ov = div_zero; end
                    default: begin
                        // X-form (full 10-bit XO)
                        case (xo10)
                            10'd0:  cr_n[31 - 4*f_crfd -: 4] = cmp4(va, vb, 1'b1, xer_so); // cmp
                            10'd32: cr_n[31 - 4*f_crfd -: 4] = cmp4(va, vb, 1'b0, xer_so); // cmpl

                            // logical: destination is RA
                            10'd28, 10'd60, 10'd444, 10'd124, 10'd316, 10'd476, 10'd284,
                            10'd412, 10'd24, 10'd536, 10'd792, 10'd824, 10'd26, 10'd954,
                            10'd922: begin
                                wa_en = 1; wa_idx = {1'b0, f_ra};
                                case (xo10)
                                    10'd28:  wa_val = vs & vb;              // and
                                    10'd60:  wa_val = vs & ~vb;             // andc
                                    10'd444: wa_val = vs | vb;              // or
                                    10'd124: wa_val = ~(vs | vb);           // nor
                                    10'd316: wa_val = vs ^ vb;              // xor
                                    10'd476: wa_val = ~(vs & vb);           // nand
                                    10'd284: wa_val = ~(vs ^ vb);           // eqv
                                    10'd412: wa_val = vs | ~vb;             // orc
                                    10'd24:  wa_val = slw_r;                // slw
                                    10'd536: wa_val = srw_r;                // srw
                                    10'd792: begin wa_val = sraw_r;  xer_n[29] = sraw_ca;  end // sraw
                                    10'd824: begin wa_val = srawi_r; xer_n[29] = srawi_ca; end // srawi
                                    10'd26:  wa_val = clz32(vs);            // cntlzw
                                    10'd954: wa_val = {{24{vs[7]}},  vs[7:0]};   // extsb
                                    10'd922: wa_val = {{16{vs[15]}}, vs[15:0]};  // extsh
                                    default: ;
                                endcase
                                rec_en = f_rc; rec_val = wa_val;
                            end

                            // indexed loads / stores
                            10'd23,  10'd55:  begin ld = 1; msize = 2'd2; upd = xo10[5]; end  // lwzx, lwzux
                            10'd87,  10'd119: begin ld = 1; msize = 2'd0; upd = xo10[5]; end  // lbzx, lbzux
                            10'd279, 10'd311: begin ld = 1; msize = 2'd1; upd = xo10[5]; end  // lhzx, lhzux
                            10'd343, 10'd375: begin ld = 1; msize = 2'd1; ld_sext = 1; upd = xo10[5]; end // lhax(u)
                            10'd151, 10'd183: begin st = 1; msize = 2'd2; upd = xo10[5]; end  // stwx, stwux
                            10'd215, 10'd247: begin st = 1; msize = 2'd0; upd = xo10[5]; end  // stbx, stbux
                            10'd407, 10'd439: begin st = 1; msize = 2'd1; upd = xo10[5]; end  // sthx, sthux
                            10'd534: begin ld = 1; msize = 2'd2; ld_brev = 1; end             // lwbrx
                            10'd790: begin ld = 1; msize = 2'd1; ld_brev = 1; end             // lhbrx
                            10'd662: begin st = 1; msize = 2'd2; st_data = ppc_pkg::bswap32(vs); end   // stwbrx
                            10'd918: begin st = 1; msize = 2'd1;                              // sthbrx
                                           st_data = {16'd0, vs[7:0], vs[15:8]}; end

                            // atomic update
                            10'd20: begin ld = 1; msize = 2'd2; nonplain = 1; resv_set = 1; end // lwarx
                            10'd150: begin                                                    // stwcx.
                                nonplain = 1; msize = 2'd2; resv_clr = 1;
                                st = resv && (resv_addr == ea);
                                cr_n[31:28] = {2'b00, st, xer_so};
                            end

                            // dcbz: zero the 32-byte block containing EA, one word per step
                            10'd1014: begin
                                nonplain = 1; st = 1; msize = 2'd2; st_data = 32'd0;
                                ea = {ea[31:5], sk[2:0], 2'b00};
                                if (sk[2:0] != 3'd7) begin
                                    next_pc = pc; retire = 1'b0;
                                    ms_active_n = 1'b1; ms_reg_n = sk + 7'd1;
                                end
                            end
                            10'd470: if (pr) priv = 1;                                        // dcbi

                            // string ops, one byte per step: lswi, lswx, stswi, stswx
                            10'd597, 10'd533, 10'd725, 10'd661: begin
                                nonplain = 1;
                                sn = xo10[6] ? ((f_rb == 5'd0) ? 7'd32 : {2'b0, f_rb}) : xer[6:0];
                                ea = (xo10[6] ? va0 : va0 + vb) + {25'd0, sk};
                                msize = 2'd0;
                                if (sn != 7'd0) begin
                                    if (!xo10[7]) begin                       // load
                                        ld = 1; ld_mrg = 1; ld_pos = sk[1:0];
                                        wa_idx = {1'b0, f_rt + sk[6:2]};
                                        wa_val = (sk[1:0] == 2'd0) ? 32'd0 : v_ms;
                                    end else begin                            // store
                                        st = 1;
                                        st_data = (v_ms >> (5'd24 - {sk[1:0], 3'b000})) & 32'h0000_00FF;
                                    end
                                    if (sk != sn - 7'd1) begin
                                        next_pc = pc; retire = 1'b0;
                                        ms_active_n = 1'b1; ms_reg_n = sk + 7'd1;
                                    end
                                end
                            end

                            // special registers
                            10'd19:  begin wa_en = 1; wa_val = cr; end                        // mfcr
                            10'd144: for (int i = 0; i < 8; i++)                              // mtcrf
                                         if (f_crm[7 - i]) cr_n[31 - 4*i -: 4] = vs[31 - 4*i -: 4];
                            10'd512: begin cr_n[31 - 4*f_crfd -: 4] = xer[31:28];            // mcrxr
                                           xer_n[31:28] = 4'd0; end
                            10'd4:   trapc = trap_cond(va, vb, f_rt);                         // tw
                            10'd535, 10'd567, 10'd599, 10'd631, 10'd663, 10'd695, 10'd727,
                            10'd759, 10'd983: fpu = 1;                                        // lfsx..stfiwx
                            10'd83:  if (pr) priv = 1;                                        // mfmsr
                                     else begin wa_en = 1; wa_val = msr; end
                            10'd146: if (pr) priv = 1;                                        // mtmsr
                                     else begin msr_we = 1; ctx_sync = 1; end
                            10'd210, 10'd242: if (pr) priv = 1; else begin                    // mtsr, mtsrin
                                sr_we = 1; ctx_sync = 1;
                            end
                            10'd595, 10'd659: if (pr) priv = 1; else begin                    // mfsr, mfsrin
                                wa_en = 1; wa_val = sr_rdata;
                            end
                            10'd306: if (pr) priv = 1;                                        // tlbie
                                     else begin tlbie = 1; ctx_sync = 1; end
                            10'd566: if (pr) priv = 1;                                        // tlbsync
                            10'd339, 10'd371: if (pr && f_spr[4]) priv = 1; else begin        // mfspr, mftb
                                wa_en = 1;
                                case (f_spr)
                                    10'd1:   wa_val = xer;
                                    10'd8:   wa_val = lr;
                                    10'd9:   wa_val = ctr;
                                    10'd22:  wa_val = dec_r;
                                    10'd26:  wa_val = srr0;
                                    10'd27:  wa_val = srr1;
                                    10'd268: wa_val = tb[31:0];
                                    10'd269: wa_val = tb[63:32];
                                    10'd272, 10'd273, 10'd274, 10'd275: wa_val = sprg[f_spr[1:0]];
                                    10'd287: wa_val = PVR;
                                    10'd1008: wa_val = hid0;
                                    10'd1009: wa_val = hid1;
                                    default: if (xspr_valid) wa_val = xspr_rdata; else illegal = 1;
                                endcase
                            end
                            10'd467: if (pr && f_spr[4]) priv = 1; else begin                 // mtspr
                                case (f_spr)
                                    10'd1:   xer_n = vs;
                                    10'd8:   lr_n  = vs;
                                    10'd9:   ctr_n = vs;
                                    10'd22, 10'd26, 10'd27, 10'd272, 10'd273, 10'd274, 10'd275,
                                    10'd284, 10'd285, 10'd1008, 10'd1009: spr_we = 1;
                                    default: if (xspr_valid) begin spr_we = 1; ctx_sync = 1; end
                                             else illegal = 1;
                                endcase
                            end

                            // cache / ordering hints: no-ops in this core
                            10'd598, 10'd854, 10'd86, 10'd54, 10'd278, 10'd246, 10'd982: ;

                            default: illegal = 1;
                        endcase
                    end
                endcase
            end

            default: illegal = 1;
        endcase

        // An ordinary load or store that straddles a page boundary is done one
        // byte per step so each page is translated (and can fault) separately.
        // Loads collect the bytes in the hidden temporary register.
        ea_base = ea;
        fsize   = msize;
        c_nb    = (msize == 2'd2) ? 3'd4 : 3'd2;
        xpage   = (ld | st) & ~nonplain &
                  ((msize == 2'd2 && ea[11:0] > 12'hFFC) || (msize == 2'd1 && ea[11:0] == 12'hFFF));
        ck      = ms_active ? ms_reg[1:0] : 2'd0;
        c_last  = ({1'b0, ck} == c_nb - 3'd1);
        if (xpage) begin
            if (ld) begin
                ld_acc = 1'b1;
                wa_val = (ck == 2'd0) ? 32'd0 : v_ms;
                if (!c_last) begin wa_idx = 6'd32; fsize = 2'd2; ld_sext = 1'b0; ld_brev = 1'b0; end
            end else begin
                st_data = (st_data >> ({3'd0, c_nb[1:0] - 2'd1 - ck} << 3)) & 32'h0000_00FF;
            end
            ea = ea + {30'd0, ck};
            msize = 2'd0;
            if (!c_last) begin
                next_pc = pc; retire = 1'b0; upd = 1'b0;
                ms_active_n = 1'b1; ms_reg_n = {5'd0, ck} + 7'd1;
            end
        end

        // memory side effects
        if (upd) begin wb_en = 1; wb_val = ea_base; end

        // overflow and record forms (CR0 uses the updated SO)
        if (oe_en) begin xer_n[30] = oe_ov; xer_n[31] = xer[31] | oe_ov; end
        if (rec_en)
            cr_n[31:28] = {rec_val[31], ~rec_val[31] & (|rec_val), rec_val == 32'd0, xer_n[31]};

        // ---------------- MSR, rfi, exceptions ----------------
        msr_n = msr;
        if (msr_we) msr_n = vs & MSR_MASK;
        if (rfi_c) begin msr_n = srr1 & MSR_MASK; next_pc = {srr0[31:2], 2'b00}; end

        exc = 1'b0; exc_vec = 20'h0; int_ack_dec = 1'b0;
        srr_we = 1'b0; srr0_n = pc; srr1_n = msr & 32'h87C0_FFFF;
        // asynchronous interrupts are taken between instructions, before executing this one
        take_int = (int_ext | int_dec) & msr[15] & ~ms_active;
        if (take_int) begin
            exc = 1'b1; exc_vec = int_ext ? 20'h00500 : 20'h00900; int_ack_dec = ~int_ext;
        end else if (isi) begin
            exc = 1'b1; exc_vec = 20'h00400; srr1_n = srr1_n | isi_bits;   // instruction storage
        end else if (fpu && !msr[13]) begin
            exc = 1'b1; exc_vec = 20'h00800;                         // FP unavailable
        end else if (illegal || fpu) begin
            exc = 1'b1; exc_vec = 20'h00700; srr1_n[19] = 1'b1;      // program: illegal instruction
        end else if (priv) begin
            exc = 1'b1; exc_vec = 20'h00700; srr1_n[18] = 1'b1;      // program: privileged
        end else if (trapc) begin
            exc = 1'b1; exc_vec = 20'h00700; srr1_n[17] = 1'b1;      // program: trap
        end else if (sc_c) begin
            exc = 1'b1; exc_vec = 20'h00C00; srr0_n = pc + 32'd4;    // system call
        end
        if (exc) begin
            wa_en = 1'b0; wb_en = 1'b0; ld = 1'b0; st = 1'b0;
            cr_n = cr; xer_n = xer; lr_n = lr; ctr_n = ctr; spr_we = 1'b0;
            ms_active_n = 1'b0; ms_reg_n = 7'd0; retire = 1'b1;
            resv_set = 1'b0; resv_clr = 1'b0;
            ctx_sync = 1'b0; sr_we = 1'b0; tlbie = 1'b0;
            srr_we = 1'b1;
            msr_n = msr & 32'h0000_1040;                             // keep ME and IP only
            next_pc = {msr[6] ? 12'hFFF : 12'h000, exc_vec};
        end
    end

endmodule
