// Simulation SoC: core + byte-addressed big-endian RAM + MMIO.
//   0x0000_0000 .. MEM_BYTES-1   RAM (loaded from +img=<file> via $readmemh)
//   0xF000_0000  write: UART TX (low byte to stdout)
//   0xF000_0004  write: end simulation with exit code
// Accesses outside RAM/MMIO raise bus_err.

module soc_top #(
    parameter int MEM_BYTES = 1 << 20,
    parameter int CORE      = 1,     // 0 = single-cycle reference, 1 = pipeline
    parameter bit QUIET     = 0      // suppress UART output (second core in lockstep)
) (
    input  logic        clk,
    input  logic        rst,
    output logic        done,
    output logic [31:0] exit_code,
    output logic        trap,
    output logic [31:0] trap_pc,
    output logic [31:0] trap_insn,
    output logic        bus_err,
    output logic [31:0] bus_err_addr,
    output logic [63:0] instret,
    output logic [63:0] cycles,
    output logic [63:0] stall_ld_use,
    output logic [63:0] flush_branch,
    output logic        tr_valid,
    output logic [31:0] tr_pc, tr_insn,
    output logic        tr_rf_we,  output logic [4:0] tr_rf_idx, output logic [31:0] tr_rf_val,
    output logic        tr_up_we,  output logic [4:0] tr_up_idx, output logic [31:0] tr_up_val,
    output logic [31:0] tr_cr, tr_xer, tr_lr, tr_ctr,
    output logic        tr_st,     output logic [31:0] tr_st_addr, tr_st_data,
    output logic [1:0]  tr_st_size
);
    localparam int AW = $clog2(MEM_BYTES);

    logic [7:0] mem [MEM_BYTES];

    initial begin
        string img;
        if ($value$plusargs("img=%s", img)) $readmemh(img, mem);
        else $display("soc_top: no +img=<file> given");
    end

    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [1:0]  dmem_size;
    logic        dmem_re, dmem_we;

    generate if (CORE == 0) begin : g_core
        ppc_core u_core (
            .clk, .rst,
            .imem_addr, .imem_rdata,
            .dmem_addr, .dmem_size, .dmem_re, .dmem_we, .dmem_wdata, .dmem_rdata,
            .trap, .trap_pc, .trap_insn, .instret, .cycles,
            .tr_valid, .tr_pc, .tr_insn, .tr_rf_we, .tr_rf_idx, .tr_rf_val,
            .tr_up_we, .tr_up_idx, .tr_up_val, .tr_cr, .tr_xer, .tr_lr, .tr_ctr,
            .tr_st, .tr_st_addr, .tr_st_data, .tr_st_size
        );
        assign stall_ld_use = 0;
        assign flush_branch = 0;
    end else begin : g_pipe
        ppc_pipe u_core (
            .clk, .rst,
            .imem_addr, .imem_rdata,
            .dmem_addr, .dmem_size, .dmem_re, .dmem_we, .dmem_wdata, .dmem_rdata,
            .trap, .trap_pc, .trap_insn, .instret, .cycles,
            .tr_valid, .tr_pc, .tr_insn, .tr_rf_we, .tr_rf_idx, .tr_rf_val,
            .tr_up_we, .tr_up_idx, .tr_up_val, .tr_cr, .tr_xer, .tr_lr, .tr_ctr,
            .tr_st, .tr_st_addr, .tr_st_data, .tr_st_size,
            .stall_ld_use, .flush_branch
        );
    end endgenerate

    function automatic logic [7:0] rd8(input logic [31:0] a);
        rd8 = mem[a[AW-1:0]];
    endfunction

    wire [31:0] ia = imem_addr;
    assign imem_rdata = {rd8(ia), rd8(ia + 1), rd8(ia + 2), rd8(ia + 3)};

    wire is_mmio  = (dmem_addr[31:28] == 4'hF);
    wire in_ram   = (dmem_addr < MEM_BYTES);
    wire [31:0] da = dmem_addr;

    always_comb begin
        case (dmem_size)
            2'd0:    dmem_rdata = {24'd0, rd8(da)};
            2'd1:    dmem_rdata = {16'd0, rd8(da), rd8(da + 1)};
            default: dmem_rdata = {rd8(da), rd8(da + 1), rd8(da + 2), rd8(da + 3)};
        endcase
        if (is_mmio) dmem_rdata = 32'd0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            done <= 0; exit_code <= 0; bus_err <= 0; bus_err_addr <= 0;
        end else begin
            if ((dmem_re || dmem_we) && !is_mmio && !in_ram && !bus_err) begin
                bus_err <= 1; bus_err_addr <= dmem_addr;
            end
            if (dmem_we && is_mmio) begin
                case (dmem_addr[7:0])
                    8'h00: if (!QUIET) begin $write("%c", dmem_wdata[7:0]); $fflush; end
                    8'h04: begin done <= 1; exit_code <= dmem_wdata; end
                    default: ;
                endcase
            end else if (dmem_we && in_ram) begin
                case (dmem_size)
                    2'd0: mem[da[AW-1:0]] <= dmem_wdata[7:0];
                    2'd1: begin
                        mem[da[AW-1:0]]           <= dmem_wdata[15:8];
                        mem[AW'(da + 1)]  <= dmem_wdata[7:0];
                    end
                    default: begin
                        mem[da[AW-1:0]]           <= dmem_wdata[31:24];
                        mem[AW'(da + 1)]  <= dmem_wdata[23:16];
                        mem[AW'(da + 2)]  <= dmem_wdata[15:8];
                        mem[AW'(da + 3)]  <= dmem_wdata[7:0];
                    end
                endcase
            end
        end
    end
endmodule
