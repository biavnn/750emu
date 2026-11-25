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

endpackage
