// Simulation SoC: core + byte-addressed big-endian RAM + MMIO.
//   0x0000_0000 .. MEM_BYTES-1   RAM, loaded from +img=<hex file> ($readmemh)
//                                or +bin=<raw binary> (loaded at address 0)
//   0xF000_0000  write: simple UART TX (low byte to stdout)
//   0xF000_0004  write: end simulation with exit code
//   0xF000_1000  16550-compatible UART (transmit only; enough register
//                behaviour for the Linux 8250 driver's probing)
// Accesses outside RAM/MMIO raise bus_err.

module soc_top #(
    parameter int MEM_BYTES = 1 << 20,
    parameter logic [31:0] RESET_PC = 32'h0000_0100,
    parameter int CORE      = 1,     // 0 = single-cycle reference, 1 = pipeline
    parameter bit QUIET     = 0,     // suppress UART output (second core in lockstep)
    parameter bit BUS_JITTER = 0,    // pipeline only: random bus wait states (stress test)
    parameter bit CACHES     = 1     // pipeline only: instruction and data caches
) (
    input  logic        clk,
    input  logic        rst,
    output logic        done,
    output logic [31:0] exit_code,
    output logic        bus_err,
    output logic [31:0] bus_err_addr,
    output logic [63:0] instret,
    output logic [63:0] cycles,
    output logic [63:0] stall_ld_use,
    output logic [63:0] flush_branch,
    output logic        tr_valid,
    output logic [31:0] tr_pc, tr_insn,
    output logic        tr_rf_we,  output logic [6:0] tr_rf_idx, output logic [31:0] tr_rf_val,
    output logic        tr_up_we,  output logic [4:0] tr_up_idx, output logic [31:0] tr_up_val,
    output logic [31:0] tr_cr, tr_xer, tr_lr, tr_ctr, tr_msr,
    output logic        tr_exc,
    output logic        tr_st,     output logic [31:0] tr_st_addr, tr_st_data,
    output logic [1:0]  tr_st_size
);
    localparam int AW = $clog2(MEM_BYTES);

    logic [7:0] mem [MEM_BYTES];

    initial begin
        string img;
        int fd, n;
        if ($value$plusargs("img=%s", img)) $readmemh(img, mem);
        else if ($value$plusargs("bin=%s", img)) begin
            fd = $fopen(img, "rb");
            if (fd == 0) $display("soc_top: cannot open %s", img);
            else begin n = $fread(mem, fd); $fclose(fd); if (n == 0) $display("soc_top: empty image"); end
        end else $display("soc_top: no +img=<hex> or +bin=<binary> given");
    end

    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [1:0]  dmem_size;
    logic        dmem_re, dmem_we;

    generate if (CORE == 0) begin : g_core
        ppc_core #(.RESET_PC(RESET_PC)) u_core (
            .clk, .rst, .irq(1'b0),
            .imem_addr, .imem_rdata,
            .dmem_addr, .dmem_size, .dmem_re, .dmem_we, .dmem_wdata, .dmem_rdata,
            .instret, .cycles,
            .tr_valid, .tr_pc, .tr_insn, .tr_rf_we, .tr_rf_idx, .tr_rf_val,
            .tr_up_we, .tr_up_idx, .tr_up_val, .tr_cr, .tr_xer, .tr_lr, .tr_ctr, .tr_msr, .tr_exc,
            .tr_st, .tr_st_addr, .tr_st_data, .tr_st_size
        );
        assign stall_ld_use = 0;
        assign flush_branch = 0;
    end else begin : g_pipe
        // Request/response buses on top of the memory model below. Without
        // jitter this behaves like block RAM: always ready, response the next
        // cycle. With BUS_JITTER, requests are refused and responses delayed at
        // pseudo-random, which must not change what the program does.
        // ibus/dbus are the memory-side buses; cibus/cdbus are the core's.
        logic        ibus_req, ibus_gnt, ibus_rvalid, dbus_req, dbus_gnt, dbus_we, dbus_rvalid;
        logic [31:0] ibus_addr, ibus_rdata, dbus_addr, dbus_wdata, dbus_rdata;
        logic [1:0]  dbus_size;
        logic        cibus_req, cibus_gnt, cibus_rvalid, cdbus_req, cdbus_gnt, cdbus_we, cdbus_rvalid;
        logic [31:0] cibus_addr, cibus_rdata, cdbus_addr, cdbus_wdata, cdbus_rdata;
        logic [1:0]  cdbus_size;
        logic        icache_flush;

        if (CACHES) begin : g_caches
            logic [1:0]  i_size_unused;
            logic        i_we_unused;
            logic [31:0] i_wdata_unused;
            cache u_icache (
                .clk, .rst, .flush(icache_flush),
                .c_req(cibus_req), .c_gnt(cibus_gnt), .c_addr(cibus_addr), .c_size(2'd2), .c_we(1'b0),
                .c_wdata(32'd0), .c_rvalid(cibus_rvalid), .c_rdata(cibus_rdata),
                .m_req(ibus_req), .m_gnt(ibus_gnt), .m_addr(ibus_addr), .m_size(i_size_unused),
                .m_we(i_we_unused), .m_wdata(i_wdata_unused), .m_rvalid(ibus_rvalid), .m_rdata(ibus_rdata)
            );
            cache u_dcache (
                .clk, .rst, .flush(1'b0),
                .c_req(cdbus_req), .c_gnt(cdbus_gnt), .c_addr(cdbus_addr), .c_size(cdbus_size), .c_we(cdbus_we),
                .c_wdata(cdbus_wdata), .c_rvalid(cdbus_rvalid), .c_rdata(cdbus_rdata),
                .m_req(dbus_req), .m_gnt(dbus_gnt), .m_addr(dbus_addr), .m_size(dbus_size),
                .m_we(dbus_we), .m_wdata(dbus_wdata), .m_rvalid(dbus_rvalid), .m_rdata(dbus_rdata)
            );
        end else begin : g_nocaches
            assign ibus_req = cibus_req; assign cibus_gnt = ibus_gnt; assign ibus_addr = cibus_addr;
            assign cibus_rvalid = ibus_rvalid; assign cibus_rdata = ibus_rdata;
            assign dbus_req = cdbus_req; assign cdbus_gnt = dbus_gnt; assign dbus_addr = cdbus_addr;
            assign dbus_size = cdbus_size; assign dbus_we = cdbus_we; assign dbus_wdata = cdbus_wdata;
            assign cdbus_rvalid = dbus_rvalid; assign cdbus_rdata = dbus_rdata;
        end
        logic        i_pend, d_pend;
        logic [1:0]  i_wait, d_wait;
        logic [31:0] lfsr, i_data, d_data;

        assign ibus_rvalid = i_pend && (i_wait == 2'd0);
        assign dbus_rvalid = d_pend && (d_wait == 2'd0);
        // read data is only meaningful in the response cycle
        assign ibus_rdata = ibus_rvalid ? i_data : 32'hDEAD_BEEF;
        assign dbus_rdata = dbus_rvalid ? d_data : 32'hDEAD_BEEF;
        assign ibus_gnt = (!i_pend || ibus_rvalid) && !(BUS_JITTER && lfsr[3] && lfsr[11]);
        assign dbus_gnt = (!d_pend || dbus_rvalid) && !(BUS_JITTER && lfsr[5] && lfsr[17]);
        assign imem_addr  = ibus_addr;
        assign dmem_addr  = dbus_addr;
        assign dmem_size  = dbus_size;
        assign dmem_wdata = dbus_wdata;
        assign dmem_re    = dbus_req && dbus_gnt && !dbus_we;
        assign dmem_we    = dbus_req && dbus_gnt && dbus_we;

        always_ff @(posedge clk) begin
            if (rst) begin
                i_pend <= 0; d_pend <= 0; i_wait <= 0; d_wait <= 0; lfsr <= 32'hC0FF_EE11;
                i_data <= 0; d_data <= 0;
            end else begin
                lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                if (ibus_rvalid) i_pend <= 0;
                else if (i_pend) i_wait <= i_wait - 2'd1;
                if (ibus_req && ibus_gnt) begin
                    i_pend <= 1; i_data <= imem_rdata;
                    i_wait <= BUS_JITTER ? (lfsr[8] ? lfsr[14:13] : 2'd0) : 2'd0;
                end
                if (dbus_rvalid) d_pend <= 0;
                else if (d_pend) d_wait <= d_wait - 2'd1;
                if (dbus_req && dbus_gnt) begin
                    d_pend <= 1; d_data <= dmem_rdata;
                    d_wait <= BUS_JITTER ? (lfsr[9] ? lfsr[20:19] : 2'd0) : 2'd0;
                end
            end
        end

        ppc_pipe #(.RESET_PC(RESET_PC)) u_core (
            .clk, .rst, .irq(1'b0),
            .ibus_req(cibus_req), .ibus_gnt(cibus_gnt), .ibus_addr(cibus_addr),
            .ibus_rvalid(cibus_rvalid), .ibus_rdata(cibus_rdata), .icache_flush,
            .dbus_req(cdbus_req), .dbus_gnt(cdbus_gnt), .dbus_addr(cdbus_addr), .dbus_size(cdbus_size),
            .dbus_we(cdbus_we), .dbus_wdata(cdbus_wdata), .dbus_rvalid(cdbus_rvalid), .dbus_rdata(cdbus_rdata),
            .instret, .cycles,
            .tr_valid, .tr_pc, .tr_insn, .tr_rf_we, .tr_rf_idx, .tr_rf_val,
            .tr_up_we, .tr_up_idx, .tr_up_val, .tr_cr, .tr_xer, .tr_lr, .tr_ctr, .tr_msr, .tr_exc,
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
        if (is_mmio) dmem_rdata = is_uart ? {24'd0, uart_rd} : 32'd0;
    end

    // ---- 16550-style UART ----
    wire       is_uart = (dmem_addr[31:12] == 20'hF0001);
    logic [7:0] u_ier, u_lcr, u_mcr, u_scr, u_dll, u_dlm;
    logic       u_fifo, u_thre;         // u_thre: 'transmitter empty' interrupt condition pending
    logic [7:0] uart_rd;
    always_comb begin
        case (dmem_addr[2:0])
            3'd0: uart_rd = u_lcr[7] ? u_dll : 8'h00;
            3'd1: uart_rd = u_lcr[7] ? u_dlm : u_ier;
            3'd2: uart_rd = {u_fifo, u_fifo, 4'h0, (u_thre & u_ier[1]) ? 2'b10 : 2'b01};
            3'd3: uart_rd = u_lcr;
            3'd4: uart_rd = u_mcr;
            3'd5: uart_rd = 8'h60;                               // transmitter always empty
            3'd6: uart_rd = u_mcr[4] ? {u_mcr[3], u_mcr[2], u_mcr[0], u_mcr[1], 4'h0} : 8'hB0;
            default: uart_rd = u_scr;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            done <= 0; exit_code <= 0; bus_err <= 0; bus_err_addr <= 0;
            u_ier <= 0; u_lcr <= 0; u_mcr <= 0; u_scr <= 0; u_dll <= 0; u_dlm <= 0; u_fifo <= 0; u_thre <= 0;
        end else begin
            // reading IIR while it reports "transmitter empty" clears that condition
            if (dmem_re && is_uart && dmem_addr[2:0] == 3'd2 && u_ier[1]) u_thre <= 0;
            if (dmem_we && is_uart) case (dmem_addr[2:0])
                3'd0: if (u_lcr[7]) u_dll <= dmem_wdata[7:0];
                      else begin
                          u_thre <= 1;               // sent instantly, so empty again
                          // in loopback mode nothing leaves the chip
                          if (!QUIET && !u_mcr[4]) begin $write("%c", dmem_wdata[7:0]); $fflush; end
                      end
                3'd1: if (u_lcr[7]) u_dlm <= dmem_wdata[7:0];
                      else begin
                          u_ier <= dmem_wdata[7:0] & 8'h0F;
                          if (dmem_wdata[1] && !u_ier[1]) u_thre <= 1;
                      end
                3'd2: u_fifo <= dmem_wdata[0];
                3'd3: u_lcr <= dmem_wdata[7:0];
                3'd4: u_mcr <= dmem_wdata[7:0] & 8'h1F;
                3'd7: u_scr <= dmem_wdata[7:0];
                default: ;
            endcase
            if ((dmem_re || dmem_we) && !is_mmio && !in_ram && !bus_err) begin
                bus_err <= 1; bus_err_addr <= dmem_addr;
            end
            if (dmem_we && is_mmio && !is_uart) begin
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
