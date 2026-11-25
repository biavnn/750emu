// Direct-mapped cache with 32-byte lines for the g3core request/response bus.
//
//   core side:   c_*  (slave)   one request outstanding, response >= 1 cycle later
//   memory side: m_*  (master)  same protocol
//
// Read hits answer in the cycle after the request and a new request can be
// accepted in that same cycle, so a stream of hits runs at one access per
// cycle. A read miss fetches the whole line (8 word reads, issued back to
// back) and then answers. Writes are write-through with no allocation: a hit
// updates the cached word, and every write is forwarded to memory, so memory
// is always current and the cache never holds dirty data. A write is
// acknowledged to the core as soon as memory accepts it, so a stream of stores
// also runs at one per cycle when memory keeps up.
//
// This relies on the bus rule that a slave grants a new request only once the
// previous response has been delivered (in that same cycle at the latest): the
// response to a forwarded write is never mistaken for a later read's data.
//
// Not cached (forwarded unchanged): addresses in the I/O region 0xFxxx_xxxx and
// accesses that straddle a word boundary; such a write invalidates the lines
// it touches. `flush` invalidates everything (used for icbi and HID0[ICFI]).
//
// Tag and data arrays are read synchronously, as block RAM requires.

module cache #(
    parameter int SETS = 1024                // lines; 1024 x 32 bytes = 32 KiB
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        flush,
    input  logic        c_req,
    output logic        c_gnt,
    input  logic [31:0] c_addr,
    input  logic [1:0]  c_size,
    input  logic        c_we,
    input  logic [31:0] c_wdata,
    output logic        c_rvalid,
    output logic [31:0] c_rdata,
    output logic        m_req,
    input  logic        m_gnt,
    output logic [31:0] m_addr,
    output logic [1:0]  m_size,
    output logic        m_we,
    output logic [31:0] m_wdata,
    input  logic        m_rvalid,
    input  logic [31:0] m_rdata
);
    localparam int IW   = $clog2(SETS);
    localparam int TAGW = 32 - 5 - IW;

    logic [31:0]     data [SETS * 8];
    logic [TAGW-1:0] tags [SETS];
    logic [SETS-1:0] valid;

    typedef enum logic [2:0] { IDLE, LOOKUP, FILL_REQ, FILL_RSP, REREAD, FWD_REQ, FWD_RSP } state_t;
    state_t state;

    // the request being served
    logic [31:0] q_addr, q_wdata;
    logic [1:0]  q_size;
    logic        q_we;
    // registered array outputs for q_addr
    logic [31:0]     rd_word;
    logic [TAGW-1:0] rd_tag;
    logic            rd_valid;
    logic [2:0]      cnt;
    logic            fill_cancel;
    logic [63:0]     n_hit, n_miss;

    wire [IW-1:0]   q_idx  = q_addr[5 +: IW];
    wire [TAGW-1:0] q_tag  = q_addr[31 -: TAGW];
    wire [2:0]      q_nb   = (q_size == 2'd2) ? 3'd4 : (q_size == 2'd1) ? 3'd2 : 3'd1;
    wire            q_split = ({1'b0, q_addr[1:0]} + q_nb) > 3'd4;       // crosses a word boundary
    wire            q_cacheable = (q_addr[31:28] != 4'hF) && !q_split;
    wire            hit    = rd_valid && (rd_tag == q_tag);
    wire            hit_rd = (state == LOOKUP) && q_cacheable && hit && !q_we;

    // big-endian byte lanes inside the cached word
    wire [2:0]  q_lane = 3'd4 - {1'b0, q_addr[1:0]} - q_nb;            // bytes to the right of the access
    wire [4:0]  q_sh   = {q_lane[1:0], 3'b000};
    wire [31:0] q_mask = ((q_size == 2'd2) ? 32'hFFFF_FFFF : (q_size == 2'd1) ? 32'h0000_FFFF : 32'h0000_00FF) << q_sh;
    wire [31:0] wr_word = (rd_word & ~q_mask) | ((q_wdata << q_sh) & q_mask);

    wire wr_now    = (state == LOOKUP) && q_we;              // forward the write straight away
    wire wr_done   = wr_now && m_gnt;
    wire fill_next = (state == FILL_RSP) && m_rvalid && (cnt != 3'd7);   // next word, back to back
    wire filling   = (state == FILL_REQ) || fill_next;

    assign c_gnt    = (state == IDLE) || hit_rd || wr_done;
    wire   take     = c_req && c_gnt;
    assign c_rvalid = hit_rd || wr_done || (state == FWD_RSP && m_rvalid);
    assign c_rdata  = hit_rd ? ((rd_word & q_mask) >> q_sh) : m_rdata;

    assign m_req   = filling || (state == FWD_REQ) || wr_now;
    assign m_addr  = filling ? {q_addr[31:5], fill_next ? cnt + 3'd1 : cnt, 2'b00} : q_addr;
    assign m_size  = filling ? 2'd2 : q_size;
    assign m_we    = wr_now;
    assign m_wdata = q_wdata;

    // synchronous array read: for a newly accepted request, or again after a fill
    wire             rd_en   = take || (state == REREAD);
    wire [31:0]      rd_addr = take ? c_addr : q_addr;
    wire [IW-1:0]    rd_idx  = rd_addr[5 +: IW];
    wire [IW-1:0]    q_idx2  = IW'((q_addr + 32'd3) >> 5);              // line of the last byte

    always_ff @(posedge clk) begin
        if (rd_en) begin
            rd_word  <= data[{rd_idx, rd_addr[4:2]}];
            rd_tag   <= tags[rd_idx];
            rd_valid <= valid[rd_idx] && !flush;
        end
        if (flush) rd_valid <= 1'b0;
        // A request taken in the cycle a write completes must see that write.
        if (take && wr_now) begin
            if (q_cacheable) begin
                if (hit && rd_addr[31:2] == q_addr[31:2]) rd_word <= wr_word;
            end else if (q_addr[31:28] != 4'hF && (rd_idx == q_idx || rd_idx == q_idx2)) begin
                rd_valid <= 1'b0;
            end
        end

        if (rst) begin
            state <= IDLE; valid <= '0; fill_cancel <= 1'b0; cnt <= 3'd0;
            n_hit <= 0; n_miss <= 0;
        end else begin
            if (flush) begin valid <= '0; fill_cancel <= 1'b1; end

            case (state)
                IDLE: ;
                LOOKUP: begin
                    if (q_we) begin
                        // (repeated harmlessly each cycle while waiting for memory to accept the write)
                        if (!q_cacheable) begin
                            if (q_addr[31:28] != 4'hF) begin valid[q_idx] <= 1'b0; valid[q_idx2] <= 1'b0; end
                        end else if (hit) data[{q_idx, q_addr[4:2]}] <= wr_word;
                        if (m_gnt) state <= IDLE;           // unless another request is taken below
                    end else if (!q_cacheable) begin
                        state <= FWD_REQ;
                    end else if (hit) begin
                        n_hit <= n_hit + 64'd1;
                        state <= IDLE;                      // unless another request is taken below
                    end else begin
                        n_miss <= n_miss + 64'd1;
                        cnt <= 3'd0; fill_cancel <= 1'b0;
                        state <= FILL_REQ;
                    end
                end
                FILL_REQ: if (m_gnt) state <= FILL_RSP;
                FILL_RSP: if (m_rvalid) begin
                    data[{q_idx, cnt}] <= m_rdata;
                    cnt <= cnt + 3'd1;
                    if (cnt == 3'd7) begin
                        tags[q_idx] <= q_tag;
                        if (!fill_cancel && !flush) valid[q_idx] <= 1'b1;
                        state <= REREAD;
                    end else if (!m_gnt) state <= FILL_REQ;  // next request already accepted otherwise
                end
                REREAD: state <= LOOKUP;
                FWD_REQ: if (m_gnt) state <= FWD_RSP;
                FWD_RSP: if (m_rvalid) state <= IDLE;
                default: state <= IDLE;
            endcase

            if (take) begin
                q_addr <= c_addr; q_size <= c_size; q_we <= c_we; q_wdata <= c_wdata;
                state <= LOOKUP;
            end
        end
    end

    final if ($test$plusargs("cachestats"))
        $display("%m: %0d hits, %0d misses", n_hit, n_miss);
endmodule
