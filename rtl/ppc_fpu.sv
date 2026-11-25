// g3core floating-point unit (IEEE 754 double and single, PowerPC semantics)
//
// Purely combinational for now: one result per call, exact intermediate and a
// single rounding (including fused multiply-add). The execute unit's
// sequencer gives it a step of its own, so it can become iterative for FPGA
// timing without changing the interface.
//
// Exceptions are reported as flags; the "disabled exception" result is always
// produced (traps on enabled exceptions are not implemented).

module ppc_fpu (
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

    fp_t fa, fb, fc;
    assign fa = unpack(a);
    assign fb = unpack(b);
    assign fc = unpack(c);

    logic         is_arith, is_madd, sub_b, negate, gen, spec, to_inf, inc, rb, st, tiny, ovf;
    logic         sp, sb, sr, pz, bz, any_snan, inv;
    logic [63:0]  nan_res, pk64;
    logic [105:0] Mp;
    logic [52:0]  Mb;
    logic [223:0] Rp, Rb, R, N, N2;
    logic [112:0] dnum, dq;
    int           Ep, Eb, Ebase, d, sh, t, e, dsh, base;
    logic [31:0]  pk32, imag;
    logic [53:0]  ishift;
    logic         vxsnan, vxisi, vxidi, vxzdz, vximz, vxvc, vxcvi, ox, ux, zx, xx;

    always_comb begin
        res = 64'd0; fr = 1'b0; fi = 1'b0; set_fprf = 1'b0; fprf = 5'd0; cmp = 4'd0;
        {vxsnan, vxisi, vxidi, vxzdz, vximz, vxvc, vxcvi, ox, ux, zx, xx} = '0;
        gen = 1'b0; spec = 1'b0; sr = 1'b0; R = '0; Ebase = 0;
        Rp = '0; Rb = '0; N = '0; N2 = '0; Mp = '0; Mb = '0; Ep = 0; Eb = 0; d = 0; sh = 0; t = 0; e = 0;
        dsh = 0; base = 0; pk64 = '0; pk32 = '0; dnum = '0; dq = '0; imag = '0; ishift = '0;
        to_inf = 1'b0; inc = 1'b0; rb = 1'b0; st = 1'b0; tiny = 1'b0; ovf = 1'b0;
        sp = 1'b0; sb = 1'b0; pz = 1'b0; bz = 1'b0; inv = 1'b0; nan_res = DEF_NAN;

        is_madd  = (op == OP_MADD || op == OP_MSUB || op == OP_NMADD || op == OP_NMSUB);
        is_arith = (op == OP_ADD || op == OP_SUB || op == OP_MUL || op == OP_DIV || is_madd || op == OP_RSP);
        sub_b    = (op == OP_SUB || op == OP_MSUB || op == OP_NMSUB);
        negate   = (op == OP_NMADD || op == OP_NMSUB);

        // which operands take part, and NaN selection in the order frA, frB, frC
        any_snan = 1'b0;
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

        if (is_arith) begin
            set_fprf = 1'b1;
            sp = (op == OP_ADD || op == OP_SUB) ? fa.s : (op == OP_DIV) ? (fa.s ^ fb.s) : (fa.s ^ fc.s);
            sb = fb.s ^ sub_b;
            if (spec) begin
                // NaN operand: propagate it, quieted
                vxsnan = any_snan;
                if (is_madd && ((fa.inf && fc.zero) || (fa.zero && fc.inf))) vximz = 1'b1;
                res = nan_res | 64'h0008_0000_0000_0000;
                if (single) res[28:0] = 29'd0;
            end else begin
                case (op)
                    OP_ADD, OP_SUB: begin
                        if (fa.inf && fb.inf && (fa.s != sb)) begin inv = 1; vxisi = 1; end
                        else if (fa.inf) begin spec = 1; res = {fa.s, 11'h7FF, 52'd0}; end
                        else if (fb.inf) begin spec = 1; res = {sb, 11'h7FF, 52'd0}; end
                        else begin
                            gen = 1; Mp = {53'd0, fa.m}; Ep = int'(fa.e) - 52;
                            Mb = fb.m; Eb = int'(fb.e) - 52;
                        end
                    end
                    OP_MUL: begin
                        if ((fa.inf && fc.zero) || (fa.zero && fc.inf)) begin inv = 1; vximz = 1; end
                        else if (fa.inf || fc.inf) begin spec = 1; res = {sp, 11'h7FF, 52'd0}; end
                        else if (fa.zero || fc.zero) begin spec = 1; res = {sp, 63'd0}; end
                        else begin
                            gen = 1; Mp = fa.m * fc.m; Ep = int'(fa.e) + int'(fc.e) - 104; Mb = 53'd0;
                        end
                    end
                    OP_DIV: begin
                        if (fa.inf && fb.inf) begin inv = 1; vxidi = 1; end
                        else if (fa.zero && fb.zero) begin inv = 1; vxzdz = 1; end
                        else if (fa.inf) begin spec = 1; res = {sp, 11'h7FF, 52'd0}; end
                        else if (fb.inf || fa.zero) begin spec = 1; res = {sp, 63'd0}; end
                        else if (fb.zero) begin spec = 1; zx = 1; res = {sp, 11'h7FF, 52'd0}; end
                        else begin
                            // 61-bit quotient plus a sticky bit from the remainder
                            dnum = {fa.m, 60'd0};
                            dq   = dnum / {60'd0, fb.m};
                            R    = {110'd0, dq, (dnum != dq * {60'd0, fb.m})};
                            Ebase = int'(fa.e) - int'(fb.e) - 61;
                            sr = sp;
                        end
                    end
                    OP_RSP: begin
                        if (fb.inf || fb.zero) begin spec = 1; res = b; end
                        else begin R = {171'd0, fb.m}; Ebase = int'(fb.e) - 52; sr = fb.s; end
                    end
                    default: begin   // fused multiply-add
                        if ((fa.inf && fc.zero) || (fa.zero && fc.inf)) begin inv = 1; vximz = 1; end
                        else if ((fa.inf || fc.inf) && fb.inf && (sp != sb)) begin inv = 1; vxisi = 1; end
                        else if (fa.inf || fc.inf) begin spec = 1; res = {sp, 11'h7FF, 52'd0}; end
                        else if (fb.inf) begin spec = 1; res = {sb, 11'h7FF, 52'd0}; end
                        else begin
                            gen = 1; Mp = fa.m * fc.m; Ep = int'(fa.e) + int'(fc.e) - 104;
                            Mb = fb.m; Eb = int'(fb.e) - 52;
                        end
                    end
                endcase

                if (inv) begin
                    spec = 1; res = DEF_NAN;
                end

                // exact sum of the (possibly trivial) product and the addend
                if (gen) begin
                    pz = (Mp == 106'd0); bz = (Mb == 53'd0);
                    d = Ep - Eb; sh = 56 - d;
                    if (bz) begin Rp = {118'd0, Mp} << 56; Ebase = Ep - 56; end
                    else if (pz) begin Rb = {171'd0, Mb}; Ebase = Eb; end
                    else if (sh >= 167) begin
                        Rp = 224'd1; Rb = {171'd0, Mb} << 166; Ebase = Eb - 166;       // product is only "sticky"
                    end else if (sh >= 0) begin
                        Rp = {118'd0, Mp} << 56; Rb = {171'd0, Mb} << sh; Ebase = Ep - 56;
                    end else begin
                        Rp = {118'd0, Mp} << 56; Ebase = Ep - 56;
                        if (-sh >= 54) Rb = 224'd1;
                        else Rb = {171'd0, Mb >> (-sh)} | {223'd0, |(Mb & ((53'd1 << (-sh)) - 53'd1))};
                    end
                    if (sp == sb)      begin R = Rp + Rb; sr = sp; end
                    else if (Rp >= Rb) begin R = Rp - Rb; sr = sp; end
                    else               begin R = Rb - Rp; sr = sb; end
                    if (R == 224'd0) begin
                        spec = 1;
                        res = {(sp == sb) ? sp : (rn == 2'b11), 63'd0};
                    end
                end

                // normalise, round once to the target precision, pack
                if (!spec) begin
                    for (int i = 0; i < 224; i++) if (R[i]) t = i;
                    e = t + Ebase;
                    N = R << (223 - t);
                    tiny = single ? (e < -126) : (e < -1022);
                    N2 = N;
                    if (tiny) begin
                        dsh = (single ? -126 : -1022) - e;
                        if (dsh > 60) dsh = 60;
                        N2 = (N >> dsh) | {223'd0, |(N & ((224'd1 << dsh) - 224'd1))};
                    end
                    if (single) begin rb = N2[199]; st = |N2[198:0]; inc = N2[200]; end
                    else        begin rb = N2[170]; st = |N2[169:0]; inc = N2[171]; end
                    case (rn)
                        2'b00: inc = rb & (st | inc);
                        2'b01: inc = 1'b0;
                        2'b10: inc = ~sr & (rb | st);
                        default: inc = sr & (rb | st);
                    endcase
                    if (single) begin
                        base = tiny ? 0 : (e + 126);
                        pk64 = (64'(base) << 23) + {40'd0, N2[223:200]} + {63'd0, inc};
                        ovf = (pk64[63:23] >= 41'd255);
                        pk32 = pk64[31:0];
                        res = ppc_pkg::sgl2dbl({sr, pk32[30:0]});
                    end else begin
                        base = tiny ? 0 : (e + 1022);
                        pk64 = (64'(base) << 52) + {11'd0, N2[223:171]} + {63'd0, inc};
                        ovf = (pk64[63:52] >= 12'd2047);
                        res = {sr, pk64[62:0]};
                    end
                    if (ovf) begin
                        ox = 1; xx = 1; fi = 1;
                        to_inf = (rn == 2'b00) | (rn == 2'b10 & ~sr) | (rn == 2'b11 & sr);
                        fr = to_inf;
                        if (to_inf) res = {sr, 11'h7FF, 52'd0};
                        else res = single ? {sr, 63'h47EF_FFFF_E000_0000} : {sr, 63'h7FEF_FFFF_FFFF_FFFF};
                    end else begin
                        xx = rb | st; fi = rb | st; fr = inc;
                        ux = tiny & (rb | st);
                    end
                end
                if (negate && !inv) res[63] = ~res[63];
            end
            fprf = classify(res);
        end

        // ---- convert to 32-bit integer ----
        if (op == OP_CTIW || op == OP_CTIWZ) begin
            res[63:32] = 32'd0;            // undefined by the architecture; QEMU gives zero
            if (fb.nan) begin
                vxcvi = 1; vxsnan = fb.snan; res[31:0] = 32'h8000_0000;
            end else if (fb.inf || (!fb.zero && fb.e > 13'sd31)) begin
                vxcvi = 1; res[31:0] = fb.s ? 32'h8000_0000 : 32'h7FFF_FFFF;
            end else if (fb.zero || fb.e < -13'sd1) begin
                // magnitude below one half (or zero): result is 0 or +-1
                st = ~fb.zero;
                case ((op == OP_CTIWZ) ? 2'b01 : rn)
                    2'b10: inc = ~fb.s & st;
                    2'b11: inc = fb.s & st;
                    default: inc = 1'b0;
                endcase
                res[31:0] = inc ? (fb.s ? 32'hFFFF_FFFF : 32'h0000_0001) : 32'd0;
                xx = st; fi = st; fr = inc;
            end else begin
                // value = m * 2^(e-52), with -1 <= e <= 31
                ishift = {1'b0, fb.m} << 1;                       // one guard position below the binary point at e=-1
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
                pk64 = {32'd0, imag} + {63'd0, inc};
                if (fb.s ? (pk64[32:0] > 33'h0_8000_0000) : (pk64[32:0] > 33'h0_7FFF_FFFF)) begin
                    vxcvi = 1; res[31:0] = fb.s ? 32'h8000_0000 : 32'h7FFF_FFFF;
                end else begin
                    res[31:0] = fb.s ? (32'd0 - pk64[31:0]) : pk64[31:0];
                    xx = rb | st; fi = rb | st; fr = inc;
                end
            end
        end

        // the upper word is undefined by the architecture; QEMU sign-extends the integer
        if (op == OP_CTIW || op == OP_CTIWZ) res[63:32] = fb.nan ? 32'd0 : {32{res[31]}};
        // QEMU marks the class "QNaN" after an invalid conversion (undefined by the architecture)
        if ((op == OP_CTIW || op == OP_CTIWZ) && vxcvi) begin set_fprf = 1'b1; fprf = 5'b10001; end

        // ---- compare ----
        if (op == OP_CMPU || op == OP_CMPO) begin
            if (fa.nan | fb.nan) begin
                cmp = 4'b0001;
                vxsnan = fa.snan | fb.snan;
                if (op == OP_CMPO) vxvc = vxsnan ? ~ve : 1'b1;
            end else if (fa.zero && fb.zero) cmp = 4'b0010;
            else if (a == b) cmp = 4'b0010;
            else if (fa.s != fb.s) cmp = fa.s ? 4'b1000 : 4'b0100;
            else if ((a[62:0] < b[62:0]) ^ fa.s) cmp = 4'b1000;
            else cmp = 4'b0100;
        end

        // ---- select ----
        if (op == OP_SEL) res = (!fa.nan && (fa.zero || !fa.s)) ? c : b;
    end

    assign exc = {ox, ux, zx, xx, vxsnan, vxisi, vxidi, vxzdz, vximz, vxvc, vxcvi};
endmodule
