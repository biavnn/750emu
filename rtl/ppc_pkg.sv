// Small shared helpers for g3core.
package ppc_pkg;

    function automatic logic [31:0] bswap32(input logic [31:0] x);
        bswap32 = {x[7:0], x[15:8], x[23:16], x[31:24]};
    endfunction

    // Format raw (right-aligned, zero-extended) memory data for a load.
    function automatic logic [31:0] ld_format(input logic [31:0] d, input logic [1:0] size,
                                              input logic sext, input logic brev);
        if (brev)      ld_format = (size == 2'd1) ? {16'd0, d[7:0], d[15:8]} : bswap32(d);
        else if (sext) ld_format = {{16{d[15]}}, d[15:0]};
        else           ld_format = d;
    endfunction

    // Single <-> double format conversion as done by lfs / stfs (exact, no rounding
    // and no exceptions; stfs of a value outside single range is undefined).
    function automatic logic [63:0] sgl2dbl(input logic [31:0] w);
        int lz;
        logic [22:0] f;
        if (w[30:23] == 8'hFF)      sgl2dbl = {w[31], 11'h7FF, w[22:0], 29'd0};
        else if (w[30:23] != 8'd0)  sgl2dbl = {w[31], w[30], {3{~w[30]}}, w[29:0], 29'd0};
        else if (w[22:0] == 23'd0)  sgl2dbl = {w[31], 63'd0};
        else begin
            lz = 0;
            for (int i = 0; i < 23; i++) if (w[i]) lz = 22 - i;
            f = w[22:0] << (lz + 1);
            sgl2dbl = {w[31], 11'(1023 - 126 - (lz + 1)), f, 29'd0};
        end
    endfunction

    function automatic logic [31:0] dbl2sgl(input logic [63:0] d);
        logic [63:0] m;
        if (d[62:52] > 11'd896)       dbl2sgl = {d[63:62], d[58:29]};
        else if (d[62:52] >= 11'd874) begin
            m = {11'd0, 1'b1, d[51:0]} >> (11'd926 - d[62:52]);
            dbl2sgl = {d[63], m[30:0]};
        end else                      dbl2sgl = {d[63], 31'd0};
    endfunction

    // Final value of a load. Three cases:
    //   mrg: string load, one byte OR-ed into position pos of the register being assembled
    //   acc: page-crossing load done a byte at a time, shifting into an accumulator
    //   s2d: lfs, the word is converted to double and one half of it written
    //   otherwise an ordinary load
    function automatic logic [31:0] ld_result(input logic [31:0] d, input logic [1:0] fsize,
                                              input logic sext, input logic brev,
                                              input logic mrg, input logic [1:0] pos,
                                              input logic acc, input logic [31:0] base,
                                              input logic [1:0] s2d);
        logic [63:0] dd;
        dd = sgl2dbl(d);
        if (s2d[1])   ld_result = s2d[0] ? dd[31:0] : dd[63:32];     // lfs: half of the converted value
        else if (mrg) ld_result = base | ({24'd0, d[7:0]} << (5'd24 - {pos, 3'b000}));
        else     ld_result = ld_format(acc ? {base[23:0], d[7:0]} : d, fsize, sext, brev);
    endfunction

    // Exception entry helpers (shared so every exception path agrees)
    function automatic logic [31:0] exc_msr(input logic [31:0] msr);
        exc_msr = msr & 32'h0000_1040;                 // keep ME and IP only
    endfunction
    function automatic logic [31:0] exc_srr1(input logic [31:0] msr);
        exc_srr1 = msr & 32'h87C0_FFFF;
    endfunction
    function automatic logic [31:0] exc_vector(input logic [31:0] msr, input logic [19:0] vec);
        exc_vector = {msr[6] ? 12'hFFF : 12'h000, vec};
    endfunction

endpackage
