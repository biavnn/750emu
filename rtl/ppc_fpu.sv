// g3core floating-point unit (IEEE 754 double and single, PowerPC semantics)
//
// Multi-cycle: the caller holds `req` with stable operands until `done`, then
// pulses `clear` (the execute unit does that at the end of the step). Every
// result is computed exactly and rounded once, including fused multiply-add.
//
//   IDLE -> [MUL: 4 cycles, 53x17 per cycle] or [DIV: 30 cycles, 2 bits per cycle]
//        -> A  operand classes, special cases, alignment of product and addend
//        -> B  add / subtract
//        -> C  normalise
//        -> D  round and pack
//        -> DONE
//
// Results that need no datapath (NaN/infinity/zero cases, compares, fsel,
// integer conversion) finish after stage A.
//
// Exceptions are reported as flags; the "disabled exception" result is always
// produced (traps on enabled exceptions are not implemented).

module ppc_fpu (
    input  logic        clk,
    input  logic        rst,
    input  logic        req,
    input  logic        clear,
    output logic        done,
    input  logic [3:0]  op,
    input  logic        single,      // round to single precision (fadds, frsp, ...)
    input  logic [1:0]  rn,          // 0 nearest-even, 1 toward zero, 2 toward +inf, 3 toward -inf
    input  logic        ve,          // FPSCR[VE]
    input  logic [63:0] a, b, c,     // frA, frB, frC
    output logic [63:0] res,
    output logic [10:0] exc,         // {ox, ux, zx, xx, vxsnan, vxisi, vxidi, vxzdz, vximz, vxvc, vxcvi}
    output logic        fr, fi,
    output logic        set_fprf,
    output logic [4:0]  fprf,
    output logic [3:0]  cmp          // {lt, gt, eq, un}
);
    localparam logic [3:0] OP_ADD = 1, OP_SUB = 2, OP_MUL = 3, OP_DIV = 4, OP_MADD = 5, OP_MSUB = 6,
                           OP_NMADD = 7, OP_NMSUB = 8, OP_RSP = 9, OP_CTIW = 10, OP_CTIWZ = 11,
                           OP_CMPU = 12, OP_CMPO = 13, OP_SEL = 14;
    localparam logic [63:0] DEF_NAN = 64'h7FF8_0000_0000_0000;

    typedef struct packed {
        logic               s, zero, inf, nan, snan;
        logic signed [12:0] e;       // unbiased exponent of the normalised value
        logic [52:0]        m;       // significand, bit 52 set unless zero
    } fp_t;

    function automatic fp_t unpack(input logic [63:0] x);
        fp_t r;
        int lz;
        r.s = x[63];
        r.zero = (x[62:0] == 63'd0);
        r.inf  = (x[62:52] == 11'h7FF) && (x[51:0] == 52'd0);
        r.nan  = (x[62:52] == 11'h7FF) && (x[51:0] != 52'd0);
        r.snan = r.nan && !x[51];
        if (x[62:52] == 11'd0) begin
            lz = 0;
            for (int i = 0; i < 52; i++) if (x[i]) lz = 51 - i;
            r.m = (x[51:0] == 52'd0) ? 53'd0 : ({1'b0, x[51:0]} << (lz + 1));
            r.e = (x[51:0] == 52'd0) ? 13'sd0 : (-13'sd1022 - 13'(lz + 1));
        end else begin
            r.m = {1'b1, x[51:0]};
            r.e = $signed({2'b00, x[62:52]}) - 13'sd1023;
        end
        return r;
    endfunction

    function automatic logic [4:0] classify(input logic [63:0] x);
        logic den;
        den = (x[62:52] == 11'd0) && (x[51:0] != 52'd0);
        if (x[62:52] == 11'h7FF && x[51:0] != 52'd0) classify = 5'b10001;            // QNaN
        else if (x[62:52] == 11'h7FF) classify = x[63] ? 5'b01001 : 5'b00101;         // infinity
        else if (x[62:0] == 63'd0)    classify = x[63] ? 5'b10010 : 5'b00010;         // zero
        else if (den)                 classify = x[63] ? 5'b11000 : 5'b10100;         // denormal
        else                          classify = x[63] ? 5'b01000 : 5'b00100;         // normal
    endfunction

    // Each stage's logic is guarded by its state so that it costs nothing in
    // simulation (and toggles nothing in hardware) while the unit is idle.
    fp_t fa, fb, fc;
    always_comb begin
        fa = '0; fb = '0; fc = '0;
        if (req) begin fa = unpack(a); fb = unpack(b); fc = unpack(c); end
    end

    wire is_madd  = (op == OP_MADD || op == OP_MSUB || op == OP_NMADD || op == OP_NMSUB);
    wire is_arith = (op == OP_ADD || op == OP_SUB || op == OP_MUL || op == OP_DIV || is_madd || op == OP_RSP);
    wire sub_b    = (op == OP_SUB || op == OP_MSUB || op == OP_NMSUB);
    wire negate   = (op == OP_NMADD || op == OP_NMSUB);

    // The iterative units are only started for finite, non-zero operands.
    wire need_mul = (op == OP_MUL || is_madd) && !fa.nan && !fc.nan && !fa.inf && !fc.inf &&
                    !fa.zero && !fc.zero && !(is_madd && fb.nan);
    wire need_div = (op == OP_DIV) && !fa.nan && !fb.nan && !fa.inf && !fb.inf && !fa.zero && !fb.zero;

    typedef enum logic [3:0] { S_IDLE, S_MUL, S_DIV, S_A, S_B, S_C, S_D, S_DONE } state_t;
    state_t state;

    // ------------------------------------------------------------------
    // Iterative multiplier and divider
    // ------------------------------------------------------------------
    logic [105:0] mul_acc;
    logic [1:0]   mcnt;
    wire  [67:0]  mul_c    = {15'd0, fc.m} >> (6'd17 * {4'd0, mcnt});              // current 17-bit slice of frC
    wire  [69:0]  mul_pp   = fa.m * mul_c[16:0];

    logic [53:0]  div_rem;
    logic [60:0]  div_quo;
    logic [5:0]   dcnt;
    wire  [54:0]  dv1   = {div_rem, 1'b0};
    wire          db1   = (dv1 >= {2'b0, fb.m});
    wire  [53:0]  dr1   = db1 ? 54'(dv1 - {2'b0, fb.m}) : dv1[53:0];
    wire  [54:0]  dv2   = {dr1, 1'b0};
    wire          db2   = (dv2 >= {2'b0, fb.m});
    wire  [53:0]  dr2   = db2 ? 54'(dv2 - {2'b0, fb.m}) : dv2[53:0];

    // ------------------------------------------------------------------
    // Stage A: classes, special cases, alignment
    // ------------------------------------------------------------------
    logic         a_fin;                   // result is final after this stage
    logic [63:0]  a_res;
    logic         a_fr, a_fi, a_setf;
    logic [4:0]   a_fprf;
    logic [3:0]   a_cmp;
    logic         a_gen;                   // stage B adds Rp and Rb; otherwise R is given
    logic [223:0] a_Rp, a_Rb, a_R;
    logic         a_sp, a_sb, a_sr;
    int           a_Ebase;
    logic         vxsnan, vxisi, vxidi, vxzdz, vximz, vxvc, vxcvi, zx, a_xx;

    logic         any_snan, spec, inv, sp, sb, pz, bz, inc, rb, st;
    logic [63:0]  nan_res, ipk;
    logic [105:0] Mp;
    logic [52:0]  Mb;
    int           Ep, Eb, d, sh, dsh;
    logic [31:0]  imag;

    always_comb begin
        a_fin = 1'b0; a_res = 64'd0; a_fr = 1'b0; a_fi = 1'b0; a_setf = 1'b0; a_fprf = 5'd0; a_cmp = 4'd0;
        a_gen = 1'b0; a_Rp = '0; a_Rb = '0; a_R = '0; a_sr = 1'b0; a_Ebase = 0;
        {vxsnan, vxisi, vxidi, vxzdz, vximz, vxvc, vxcvi, zx, a_xx} = '0;
        spec = 1'b0; inv = 1'b0; pz = 1'b0; bz = 1'b0; inc = 1'b0; rb = 1'b0; st = 1'b0;
        nan_res = DEF_NAN; ipk = '0; Mp = '0; Mb = '0; Ep = 0; Eb = 0; d = 0; sh = 0; dsh = 0; imag = '0;
        any_snan = 1'b0; sp = 1'b0; sb = 1'b0;

        if (state == S_A) begin
        // NaN selection in the order frA, frB, frC
        case (op)
            OP_ADD, OP_SUB, OP_DIV: begin
                any_snan = fa.snan | fb.snan;
                if (fa.nan | fb.nan) begin spec = 1; nan_res = fa.nan ? a : b; end
            end
            OP_MUL: begin
                any_snan = fa.snan | fc.snan;
                if (fa.nan | fc.nan) begin spec = 1; nan_res = fa.nan ? a : c; end
            end
            OP_MADD, OP_MSUB, OP_NMADD, OP_NMSUB: begin
                any_snan = fa.snan | fb.snan | fc.snan;
                if (fa.nan | fb.nan | fc.nan) begin spec = 1; nan_res = fa.nan ? a : fb.nan ? b : c; end
            end
            OP_RSP, OP_CTIW, OP_CTIWZ: begin
                any_snan = fb.snan;
                if (fb.nan) begin spec = 1; nan_res = b; end
            end
            default: ;
        endcase

        sp = (op == OP_ADD || op == OP_SUB) ? fa.s : (op == OP_DIV) ? (fa.s ^ fb.s) : (fa.s ^ fc.s);
        sb = fb.s ^ sub_b;

        if (is_arith) begin
            a_setf = 1'b1;
            if (spec) begin
                // NaN operand: propagate it, quieted
                vxsnan = any_snan;
                if (is_madd && ((fa.inf && fc.zero) || (fa.zero && fc.inf))) vximz = 1'b1;
                a_res = nan_res | 64'h0008_0000_0000_0000;
                if (single) a_res[28:0] = 29'd0;
            end else begin
                case (op)
                    OP_ADD, OP_SUB: begin
                        if (fa.inf && fb.inf && (fa.s != sb)) begin inv = 1; vxisi = 1; end
                        else if (fa.inf) begin spec = 1; a_res = {fa.s, 11'h7FF, 52'd0}; end
                        else if (fb.inf) begin spec = 1; a_res = {sb, 11'h7FF, 52'd0}; end
                        else begin
                            a_gen = 1; Mp = {53'd0, fa.m}; Ep = int'(fa.e) - 52;
                            Mb = fb.m; Eb = int'(fb.e) - 52;
                        end
                    end
                    OP_MUL: begin
                        if ((fa.inf && fc.zero) || (fa.zero && fc.inf)) begin inv = 1; vximz = 1; end
                        else if (fa.inf || fc.inf) begin spec = 1; a_res = {sp, 11'h7FF, 52'd0}; end
                        else if (fa.zero || fc.zero) begin spec = 1; a_res = {sp, 63'd0}; end
                        else begin
                            a_gen = 1; Mp = mul_acc; Ep = int'(fa.e) + int'(fc.e) - 104; Mb = 53'd0;
                        end
                    end
                    OP_DIV: begin
                        if (fa.inf && fb.inf) begin inv = 1; vxidi = 1; end
                        else if (fa.zero && fb.zero) begin inv = 1; vxzdz = 1; end
                        else if (fa.inf) begin spec = 1; a_res = {sp, 11'h7FF, 52'd0}; end
                        else if (fb.inf || fa.zero) begin spec = 1; a_res = {sp, 63'd0}; end
                        else if (fb.zero) begin spec = 1; zx = 1; a_res = {sp, 11'h7FF, 52'd0}; end
                        else begin
                            // 61-bit quotient plus a sticky bit from the remainder
                            a_R = {162'd0, div_quo, (div_rem != 54'd0)};
                            a_Ebase = int'(fa.e) - int'(fb.e) - 61;
                            a_sr = sp;
                        end
                    end
                    OP_RSP: begin
                        if (fb.inf || fb.zero) begin spec = 1; a_res = b; end
                        else begin a_R = {171'd0, fb.m}; a_Ebase = int'(fb.e) - 52; a_sr = fb.s; end
                    end
                    default: begin   // fused multiply-add
                        if ((fa.inf && fc.zero) || (fa.zero && fc.inf)) begin inv = 1; vximz = 1; end
                        else if ((fa.inf || fc.inf) && fb.inf && (sp != sb)) begin inv = 1; vxisi = 1; end
                        else if (fa.inf || fc.inf) begin spec = 1; a_res = {sp, 11'h7FF, 52'd0}; end
                        else if (fb.inf) begin spec = 1; a_res = {sb, 11'h7FF, 52'd0}; end
                        else begin
                            a_gen = 1; Mp = (fa.zero || fc.zero) ? 106'd0 : mul_acc;
                            Ep = int'(fa.e) + int'(fc.e) - 104;
                            Mb = fb.m; Eb = int'(fb.e) - 52;
                        end
                    end
                endcase
                if (inv) begin spec = 1; a_res = DEF_NAN; end

                // place product and addend in a common 224-bit window
                if (a_gen) begin
                    pz = (Mp == 106'd0); bz = (Mb == 53'd0);
                    d = Ep - Eb; sh = 56 - d;
                    if (bz) begin a_Rp = {118'd0, Mp} << 56; a_Ebase = Ep - 56; end
                    else if (pz) begin a_Rb = {171'd0, Mb}; a_Ebase = Eb; end
                    else if (sh >= 167) begin
                        a_Rp = 224'd1; a_Rb = {171'd0, Mb} << 166; a_Ebase = Eb - 166;   // product is only "sticky"
                    end else if (sh >= 0) begin
                        a_Rp = {118'd0, Mp} << 56; a_Rb = {171'd0, Mb} << sh; a_Ebase = Ep - 56;
                    end else begin
                        a_Rp = {118'd0, Mp} << 56; a_Ebase = Ep - 56;
                        if (-sh >= 54) a_Rb = 224'd1;
                        else a_Rb = {171'd0, Mb >> (-sh)} | {223'd0, |(Mb & ((53'd1 << (-sh)) - 53'd1))};
                    end
                end
                if (negate && spec && !inv) a_res[63] = ~a_res[63];
            end
            a_fin  = spec;
            a_fprf = classify(a_res);
        end

        // ---- convert to 32-bit integer ----
        if (op == OP_CTIW || op == OP_CTIWZ) begin
            a_fin = 1'b1;
            if (fb.nan) begin
                vxcvi = 1; vxsnan = fb.snan; a_res[31:0] = 32'h8000_0000;
            end else if (fb.inf || (!fb.zero && fb.e > 13'sd31)) begin
                vxcvi = 1; a_res[31:0] = fb.s ? 32'h8000_0000 : 32'h7FFF_FFFF;
            end else if (fb.zero || fb.e < -13'sd1) begin
                // magnitude below one half (or zero): result is 0 or +-1
                st = ~fb.zero;
                case ((op == OP_CTIWZ) ? 2'b01 : rn)
                    2'b10: inc = ~fb.s & st;
                    2'b11: inc = fb.s & st;
                    default: inc = 1'b0;
                endcase
                a_res[31:0] = inc ? (fb.s ? 32'hFFFF_FFFF : 32'h0000_0001) : 32'd0;
                a_xx = st; a_fi = st; a_fr = inc;
            end else begin
                // value = m * 2^(e-52), with -1 <= e <= 31
                dsh = 52 - int'(fb.e);                            // 21 .. 53 fraction bits
                imag = 32'((fb.m >> dsh));
                rb = (dsh >= 1) ? fb.m[dsh - 1] : 1'b0;
                st = (dsh >= 2) ? |(fb.m & ((53'd1 << (dsh - 1)) - 53'd1)) : 1'b0;
                case ((op == OP_CTIWZ) ? 2'b01 : rn)
                    2'b00: inc = rb & (st | imag[0]);
                    2'b01: inc = 1'b0;
                    2'b10: inc = ~fb.s & (rb | st);
                    default: inc = fb.s & (rb | st);
                endcase
                ipk = {32'd0, imag} + {63'd0, inc};
                if (fb.s ? (ipk[32:0] > 33'h0_8000_0000) : (ipk[32:0] > 33'h0_7FFF_FFFF)) begin
                    vxcvi = 1; a_res[31:0] = fb.s ? 32'h8000_0000 : 32'h7FFF_FFFF;
                end else begin
                    a_res[31:0] = fb.s ? (32'd0 - ipk[31:0]) : ipk[31:0];
                    a_xx = rb | st; a_fi = rb | st; a_fr = inc;
                end
            end
            // the upper word is undefined by the architecture; QEMU sign-extends the integer
            a_res[63:32] = fb.nan ? 32'd0 : {32{a_res[31]}};
            // QEMU marks the class "QNaN" after an invalid conversion (undefined by the architecture)
            if (vxcvi) begin a_setf = 1'b1; a_fprf = 5'b10001; end
        end

        // ---- compare ----
        if (op == OP_CMPU || op == OP_CMPO) begin
            a_fin = 1'b1;
            if (fa.nan | fb.nan) begin
                a_cmp = 4'b0001;
                vxsnan = fa.snan | fb.snan;
                if (op == OP_CMPO) vxvc = vxsnan ? ~ve : 1'b1;
            end else if (fa.zero && fb.zero) a_cmp = 4'b0010;
            else if (a == b) a_cmp = 4'b0010;
            else if (fa.s != fb.s) a_cmp = fa.s ? 4'b1000 : 4'b0100;
            else if ((a[62:0] < b[62:0]) ^ fa.s) a_cmp = 4'b1000;
            else a_cmp = 4'b0100;
        end

        // ---- select ----
        if (op == OP_SEL) begin
            a_fin = 1'b1;
            a_res = (!fa.nan && (fa.zero || !fa.s)) ? c : b;
        end
        end
    end

    // ------------------------------------------------------------------
    // Stage B: exact sum (registered inputs q_*)
    // ------------------------------------------------------------------
    logic         q_gen, q_sp, q_sb, q_sr;
    logic [223:0] q_Rp, q_Rb, q_R;
    int           q_Ebase;
    logic [223:0] b_R;
    logic         b_sr, b_zero;
    always_comb begin
        b_R = q_R; b_sr = q_sr; b_zero = 1'b0;
        if (state == S_B && q_gen) begin
            if (q_sp == q_sb)      begin b_R = q_Rp + q_Rb; b_sr = q_sp; end
            else if (q_Rp >= q_Rb) begin b_R = q_Rp - q_Rb; b_sr = q_sp; end
            else                   begin b_R = q_Rb - q_Rp; b_sr = q_sb; end
            if (b_R == 224'd0) begin
                b_zero = 1'b1;                                   // exact zero
                b_sr = (q_sp == q_sb) ? q_sp : (rn == 2'b11);
            end
        end
    end

    // ------------------------------------------------------------------
    // Stage C: normalise
    // ------------------------------------------------------------------
    logic [223:0] r_R, c_N;
    logic         r_sr;
    int           c_t, c_e;
    always_comb begin
        c_t = 0; c_e = 0; c_N = '0;
        if (state == S_C) begin
            for (int i = 0; i < 224; i++) if (r_R[i]) c_t = i;
            c_e = c_t + q_Ebase;
            c_N = r_R << (223 - c_t);
        end
    end

    // ------------------------------------------------------------------
    // Stage D: round once to the target precision and pack
    // ------------------------------------------------------------------
    logic [223:0] n_N, N2;
    int           n_e, base, tsh;
    logic         tiny, d_rb, d_st, d_inc, ovf, to_inf;
    logic [63:0]  pk64, d_res;
    logic         d_ox, d_ux, d_xx, d_fr, d_fi;
    always_comb begin
        tiny = 1'b0; N2 = '0; tsh = 0; d_rb = 1'b0; d_st = 1'b0; d_inc = 1'b0; base = 0; pk64 = '0;
        ovf = 1'b0; d_res = '0; to_inf = 1'b0; d_ox = 1'b0; d_ux = 1'b0; d_xx = 1'b0; d_fi = 1'b0; d_fr = 1'b0;
        if (state == S_D) begin
        tiny = single ? (n_e < -126) : (n_e < -1022);
        N2 = n_N; tsh = 0;
        if (tiny) begin
            tsh = (single ? -126 : -1022) - n_e;
            if (tsh > 60) tsh = 60;
            N2 = (n_N >> tsh) | {223'd0, |(n_N & ((224'd1 << tsh) - 224'd1))};
        end
        if (single) begin d_rb = N2[199]; d_st = |N2[198:0]; d_inc = N2[200]; end
        else        begin d_rb = N2[170]; d_st = |N2[169:0]; d_inc = N2[171]; end
        case (rn)
            2'b00: d_inc = d_rb & (d_st | d_inc);
            2'b01: d_inc = 1'b0;
            2'b10: d_inc = ~r_sr & (d_rb | d_st);
            default: d_inc = r_sr & (d_rb | d_st);
        endcase
        if (single) begin
            base = tiny ? 0 : (n_e + 126);
            pk64 = (64'(base) << 23) + {40'd0, N2[223:200]} + {63'd0, d_inc};
            ovf = (pk64[63:23] >= 41'd255);
            d_res = ppc_pkg::sgl2dbl({r_sr, pk64[30:0]});
        end else begin
            base = tiny ? 0 : (n_e + 1022);
            pk64 = (64'(base) << 52) + {11'd0, N2[223:171]} + {63'd0, d_inc};
            ovf = (pk64[63:52] >= 12'd2047);
            d_res = {r_sr, pk64[62:0]};
        end
        to_inf = (rn == 2'b00) | (rn == 2'b10 & ~r_sr) | (rn == 2'b11 & r_sr);
        d_ox = 1'b0; d_ux = 1'b0;
        if (ovf) begin
            d_ox = 1'b1; d_xx = 1'b1; d_fi = 1'b1; d_fr = to_inf;
            if (to_inf) d_res = {r_sr, 11'h7FF, 52'd0};
            else d_res = single ? {r_sr, 63'h47EF_FFFF_E000_0000} : {r_sr, 63'h7FEF_FFFF_FFFF_FFFF};
        end else begin
            d_xx = d_rb | d_st; d_fi = d_rb | d_st; d_fr = d_inc;
            d_ux = tiny & (d_rb | d_st);
        end
        if (negate) d_res[63] = ~d_res[63];
        end
    end

    // ------------------------------------------------------------------
    // Control and result registers
    // ------------------------------------------------------------------
    logic [10:0] flags_a;       // flags known after stage A
    assign done = (state == S_DONE);

    always_ff @(posedge clk) begin
        if (rst || clear) begin
            state <= S_IDLE;
        end else case (state)
            S_IDLE: if (req) begin
                if (need_mul) begin state <= S_MUL; mul_acc <= '0; mcnt <= 2'd0; end
                else if (need_div) begin
                    state <= S_DIV; dcnt <= 6'd30;
                    div_quo <= {60'd0, (fa.m >= fb.m)};
                    div_rem <= (fa.m >= fb.m) ? {1'b0, fa.m - fb.m} : {1'b0, fa.m};
                end else state <= S_A;
            end
            S_MUL: begin
                mul_acc <= mul_acc + ({36'd0, mul_pp} << (6'd17 * {4'd0, mcnt}));
                mcnt <= mcnt + 2'd1;
                if (mcnt == 2'd3) state <= S_A;
            end
            S_DIV: begin
                div_quo <= {div_quo[58:0], db1, db2};
                div_rem <= dr2;
                dcnt <= dcnt - 6'd1;
                if (dcnt == 6'd1) state <= S_A;
            end
            S_A: begin
                flags_a <= {1'b0, 1'b0, zx, a_xx, vxsnan, vxisi, vxidi, vxzdz, vximz, vxvc, vxcvi};
                set_fprf <= a_setf; cmp <= a_cmp;
                q_gen <= a_gen; q_Rp <= a_Rp; q_Rb <= a_Rb; q_R <= a_R;
                q_sp <= sp; q_sb <= sb; q_sr <= a_sr; q_Ebase <= a_Ebase;
                if (a_fin) begin
                    res <= a_res; fr <= a_fr; fi <= a_fi; fprf <= a_fprf;
                    exc <= {1'b0, 1'b0, zx, a_xx, vxsnan, vxisi, vxidi, vxzdz, vximz, vxvc, vxcvi};
                    state <= S_DONE;
                end else state <= S_B;
            end
            S_B: begin
                r_R <= b_R; r_sr <= b_sr;
                if (b_zero) begin
                    res <= {b_sr ^ negate, 63'd0}; fr <= 1'b0; fi <= 1'b0;
                    fprf <= classify({b_sr ^ negate, 63'd0}); exc <= flags_a;
                    state <= S_DONE;
                end else state <= S_C;
            end
            S_C: begin n_N <= c_N; n_e <= c_e; state <= S_D; end
            S_D: begin
                res <= d_res; fr <= d_fr; fi <= d_fi; fprf <= classify(d_res);
                exc <= flags_a | {d_ox, d_ux, 1'b0, d_xx, 7'd0};
                state <= S_DONE;
            end
            default: ;       // S_DONE: hold the result until clear
        endcase
    end
endmodule
