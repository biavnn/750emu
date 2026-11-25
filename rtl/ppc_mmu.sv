// g3core memory management unit (PowerPC 32-bit OEA, as on the 750)
//
//  - 4 instruction + 4 data BAT pairs (block address translation)
//  - 16 segment registers
//  - separate 64-entry direct-mapped instruction and data TLBs, tagged by VSID
//  - hardware walker for the hashed page table (primary then secondary PTEG),
//    which also maintains the Referenced/Changed bits in memory
//  - DSISR, DAR and SDR1
//
// Lookups are combinational. A TLB miss is reported to the core, which starts
// the walker when the access is known to be non-speculative and then retries.
// Both cores use this module unchanged, so TLB contents evolve identically.
//
// Limitations: an access that crosses a page boundary is translated by its
// first byte only; direct-store segments (T=1) fault; no-execute checks on
// pages follow the architecture (fetch needs read permission).

module ppc_mmu #(
    parameter int TLB_BITS = 6
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [31:0] msr,
    // instruction-side lookup
    input  logic [31:0] i_ea,
    output logic [31:0] i_pa,
    output logic        i_ok, i_miss, i_flt,
    output logic [31:0] i_fbits,          // SRR1 reason bits
    // data-side lookup
    input  logic [31:0] d_ea,
    input  logic        d_store,
    output logic [31:0] d_pa,
    output logic        d_ok, d_miss, d_flt,
    output logic [31:0] d_fbits,          // DSISR reason bits (without the store bit)
    // page table walker
    input  logic        wk_start,
    input  logic        wk_instr,
    input  logic        wk_store,
    input  logic [31:0] wk_ea,
    output logic        wk_busy,
    output logic        wk_done,          // last cycle of a walk
    output logic        wk_nf,            // with wk_done: no matching PTE
    output logic        wk_re, wk_we,
    output logic [31:0] wk_addr, wk_wdata,
    input  logic [31:0] wk_rdata,
    // special registers
    input  logic [9:0]  spr_idx,
    output logic [31:0] spr_rdata,
    output logic        spr_rvalid,       // spr_idx names a register that lives here
    input  logic        spr_we,
    input  logic [31:0] spr_wdata,
    input  logic [3:0]  sr_idx,
    output logic [31:0] sr_rdata,
    input  logic        sr_we,
    input  logic [31:0] sr_wdata,
    input  logic        tlbie,
    input  logic [31:0] tlbie_ea,
    input  logic        dsi_we,
    input  logic [31:0] dsisr_in, dar_in
);
    localparam int N = 1 << TLB_BITS;
    localparam int TAGW = 16 - TLB_BITS;

    logic [31:0] ibatu [4], ibatl [4], dbatu [4], dbatl [4];
    logic [31:0] sr [16];
    logic [31:0] sdr1, dsisr, dar;

    typedef struct packed {
        logic [23:0]     vsid;
        logic [TAGW-1:0] tag;
        logic [19:0]     rpn;
        logic [1:0]      pp;
        logic            c;
    } tlbe_t;

    tlbe_t        itlb [N], dtlb [N];
    logic [N-1:0] itlb_v, dtlb_v;

    typedef struct packed {
        logic        ok, miss, flt;
        logic [31:0] fbits;
        logic [31:0] pa;
    } xl_t;

    // page permission: 0 = none, 1 = read-only, 2 = read/write
    function automatic logic [1:0] perm(input logic key, input logic [1:0] pp);
        if (key) perm = (pp == 2'd0) ? 2'd0 : (pp == 2'd2) ? 2'd2 : 2'd1;
        else     perm = (pp == 2'd3) ? 2'd1 : 2'd2;
    endfunction

    function automatic xl_t xlate(
        input logic [31:0] ea, input logic en, input logic pr, input logic is_i, input logic store,
        input logic [31:0] batu [4], input logic [31:0] batl [4],
        input logic [31:0] seg, input tlbe_t te, input logic tv);
        xl_t r;
        logic bat_hit;
        logic [1:0] p;
        r = '0; r.pa = ea; bat_hit = 1'b0;
        if (!en) begin
            r.ok = 1'b1;
        end else begin
            for (int i = 3; i >= 0; i--) begin
                if ((pr ? batu[i][0] : batu[i][1]) && ea[31:28] == batu[i][31:28] &&
                    (ea[27:17] & ~batu[i][12:2]) == batu[i][27:17]) begin
                    bat_hit = 1'b1;
                    r.pa = {batl[i][31:28], (ea[27:17] & batu[i][12:2]) | batl[i][27:17], ea[16:0]};
                    r.flt = (batl[i][1:0] == 2'd0) || (store && batl[i][1:0] != 2'd2);
                end
            end
            if (bat_hit) begin
                r.ok = ~r.flt; r.fbits = 32'h0800_0000;
            end else if (seg[31] || (is_i && seg[28])) begin
                r.flt = 1'b1; r.fbits = 32'h1000_0000;           // direct-store or no-execute segment
            end else if (tv && te.vsid == seg[23:0] && te.tag == ea[27:12+TLB_BITS]) begin
                p = perm(pr ? seg[29] : seg[30], te.pp);
                r.pa = {te.rpn, ea[11:0]};
                if (p == 2'd0 || (store && p != 2'd2)) begin
                    r.flt = 1'b1; r.fbits = 32'h0800_0000;       // protection
                end else if (store && !te.c) begin
                    r.miss = 1'b1;                               // walk again to set Changed
                end else begin
                    r.ok = 1'b1;
                end
            end else begin
                r.miss = 1'b1;
            end
        end
        return r;
    endfunction

    xl_t xi, xd;
    assign xi = xlate(i_ea, msr[5], msr[14], 1'b1, 1'b0, ibatu, ibatl, sr[i_ea[31:28]],
                      itlb[i_ea[12+TLB_BITS-1:12]], itlb_v[i_ea[12+TLB_BITS-1:12]]);
    assign xd = xlate(d_ea, msr[4], msr[14], 1'b0, d_store, dbatu, dbatl, sr[d_ea[31:28]],
                      dtlb[d_ea[12+TLB_BITS-1:12]], dtlb_v[d_ea[12+TLB_BITS-1:12]]);
    assign i_pa = xi.pa; assign i_ok = xi.ok; assign i_miss = xi.miss; assign i_flt = xi.flt;
    assign i_fbits = xi.fbits;
    assign d_pa = xd.pa; assign d_ok = xd.ok; assign d_miss = xd.miss; assign d_flt = xd.flt;
    assign d_fbits = xd.fbits;

    // ------------------------------------------------------------------
    // Page table walker
    // ------------------------------------------------------------------
    typedef enum logic [1:0] { W_IDLE, W_PTE0, W_PTE1, W_NF } wstate_t;
    wstate_t     ws;
    logic [31:0] w_ea;
    logic        w_instr, w_store, w_sec;
    logic [2:0]  w_idx;

    wire [31:0] w_seg    = sr[w_ea[31:28]];
    wire [18:0] w_hash0  = w_seg[18:0] ^ {3'b0, w_ea[27:12]};
    wire [18:0] w_hash   = w_sec ? ~w_hash0 : w_hash0;
    wire [31:0] w_pteg   = {sdr1[31:16], 16'h0} +
                           ({7'b0, w_hash, 6'b0} & {7'b0, sdr1[8:0], 16'hFFFF});
    wire [31:0] w_pte    = w_pteg + {26'b0, w_idx, 3'b0};
    wire        w_match  = wk_rdata[31] && wk_rdata[30:7] == w_seg[23:0] &&
                           wk_rdata[6] == w_sec && wk_rdata[5:0] == w_ea[27:22];
    wire [1:0]  w_perm   = perm(msr[14] ? w_seg[29] : w_seg[30], wk_rdata[1:0]);
    wire        w_allow  = (w_perm != 2'd0) && !(w_store && w_perm != 2'd2);
    wire [31:0] w_pte1n  = wk_rdata | 32'h0000_0100 | (w_store ? 32'h0000_0080 : 32'h0);
    wire [TLB_BITS-1:0] w_ti = w_ea[12+TLB_BITS-1:12];

    assign wk_busy  = (ws != W_IDLE);
    assign wk_done  = (ws == W_PTE1) || (ws == W_NF);
    assign wk_nf    = (ws == W_NF);
    assign wk_re    = (ws == W_PTE0) || (ws == W_PTE1);
    assign wk_addr  = (ws == W_PTE1) ? w_pte + 32'd4 : w_pte;
    assign wk_we    = (ws == W_PTE1) && w_allow && (w_pte1n != wk_rdata);
    assign wk_wdata = w_pte1n;

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    wire [1:0] bn = spr_idx[2:1];
    always_comb begin
        spr_rvalid = 1'b1; spr_rdata = 32'd0;
        case (spr_idx) inside
            10'd18: spr_rdata = dsisr;
            10'd19: spr_rdata = dar;
            10'd25: spr_rdata = sdr1;
            [10'd528:10'd535]: spr_rdata = spr_idx[0] ? ibatl[bn] : ibatu[bn];
            [10'd536:10'd543]: spr_rdata = spr_idx[0] ? dbatl[bn] : dbatu[bn];
            default: spr_rvalid = 1'b0;
        endcase
    end
    assign sr_rdata = sr[sr_idx];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 4; i++) begin
                ibatu[i] <= 0; ibatl[i] <= 0; dbatu[i] <= 0; dbatl[i] <= 0;
            end
            for (int i = 0; i < 16; i++) sr[i] <= 0;
            sdr1 <= 0; dsisr <= 0; dar <= 0;
            itlb_v <= '0; dtlb_v <= '0;
            ws <= W_IDLE; w_ea <= 0; w_instr <= 0; w_store <= 0; w_sec <= 0; w_idx <= 0;
        end else begin
            if (spr_we) case (spr_idx) inside
                10'd18: dsisr <= spr_wdata;
                10'd19: dar   <= spr_wdata;
                10'd25: begin sdr1 <= spr_wdata; itlb_v <= '0; dtlb_v <= '0; end
                [10'd528:10'd535]: if (spr_idx[0]) ibatl[bn] <= spr_wdata; else ibatu[bn] <= spr_wdata;
                [10'd536:10'd543]: if (spr_idx[0]) dbatl[bn] <= spr_wdata; else dbatu[bn] <= spr_wdata;
                default: ;
            endcase
            if (sr_we) sr[sr_idx] <= sr_wdata;
            if (dsi_we) begin dsisr <= dsisr_in; dar <= dar_in; end
            if (tlbie) begin
                itlb_v[tlbie_ea[12+TLB_BITS-1:12]] <= 1'b0;
                dtlb_v[tlbie_ea[12+TLB_BITS-1:12]] <= 1'b0;
            end

            case (ws)
                W_IDLE: if (wk_start) begin
                    ws <= W_PTE0; w_ea <= wk_ea; w_instr <= wk_instr; w_store <= wk_store;
                    w_sec <= 1'b0; w_idx <= 3'd0;
                end
                W_PTE0: begin
                    if (w_match) ws <= W_PTE1;
                    else if (w_idx != 3'd7) w_idx <= w_idx + 3'd1;
                    else if (!w_sec) begin w_sec <= 1'b1; w_idx <= 3'd0; end
                    else ws <= W_NF;
                end
                W_PTE1: begin
                    // cache the translation; Changed reflects what is now in memory
                    if (w_instr) begin
                        itlb[w_ti] <= '{vsid: w_seg[23:0], tag: w_ea[27:12+TLB_BITS], rpn: wk_rdata[31:12],
                                        pp: wk_rdata[1:0], c: wk_rdata[7]};
                        itlb_v[w_ti] <= 1'b1;
                    end else begin
                        dtlb[w_ti] <= '{vsid: w_seg[23:0], tag: w_ea[27:12+TLB_BITS], rpn: wk_rdata[31:12],
                                        pp: wk_rdata[1:0], c: w_allow ? w_pte1n[7] : wk_rdata[7]};
                        dtlb_v[w_ti] <= 1'b1;
                    end
                    ws <= W_IDLE;
                end
                W_NF: ws <= W_IDLE;
            endcase
        end
    end
endmodule
