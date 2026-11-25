// Iterative 32-bit integer divider for divw / divwu: restoring, two quotient
// bits per cycle (16 cycles plus one to start). Same handshake as the FPU:
// hold `req` with stable operands until `done`, then pulse `clear`.
// The quotient truncates toward zero; divide by zero and the signed overflow
// case are handled by the caller (their results are undefined).

module ppc_div (
    input  logic        clk,
    input  logic        rst,
    input  logic        req,
    input  logic        clear,
    output logic        done,
    input  logic        is_signed,
    input  logic [31:0] a, b,
    output logic [31:0] q
);
    logic        busy, neg;
    logic [4:0]  cnt;
    logic [31:0] quo, den;
    logic [32:0] rem;
    logic [31:0] num;

    wire [31:0] ua = (is_signed && a[31]) ? (32'd0 - a) : a;
    wire [31:0] ub = (is_signed && b[31]) ? (32'd0 - b) : b;

    wire [33:0] v1 = {rem, num[31]};
    wire        b1 = (v1 >= {2'b0, den});
    wire [32:0] r1 = b1 ? 33'(v1 - {2'b0, den}) : v1[32:0];
    wire [33:0] v2 = {r1, num[30]};
    wire        b2 = (v2 >= {2'b0, den});
    wire [32:0] r2 = b2 ? 33'(v2 - {2'b0, den}) : v2[32:0];

    assign q = neg ? (32'd0 - quo) : quo;

    always_ff @(posedge clk) begin
        if (rst || clear) begin
            busy <= 1'b0; done <= 1'b0;
        end else if (!busy && !done) begin
            if (req) begin
                busy <= 1'b1; cnt <= 5'd16;
                num <= ua; den <= ub; rem <= 33'd0; quo <= 32'd0;
                neg <= is_signed && (a[31] ^ b[31]);
            end
        end else if (busy) begin
            quo <= {quo[29:0], b1, b2};
            rem <= r2;
            num <= {num[29:0], 2'b00};
            cnt <= cnt - 5'd1;
            if (cnt == 5'd1) begin busy <= 1'b0; done <= 1'b1; end
        end
    end
endmodule
