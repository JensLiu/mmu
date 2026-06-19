`include "VX_define.vh"

module ptw_vxdcache_adapter #(
    parameter int unsigned NUM_PTWS = 1
) (
    input logic clk,
    input logic reset,

    ptw_mem_if.slave     mem_if    [NUM_PTWS],
    VX_mem_bus_if.master mem_bus_if[NUM_PTWS]
);

    // We are adapting to the L2 cache interface
    localparam int unsigned WORD_SIZE = VX_gpu_pkg::DCACHE_LINE_SIZE;
    localparam int unsigned LINE_BITS = WORD_SIZE * 8;
    localparam int unsigned ADDR_OFFSET_BITS = $clog2(WORD_SIZE);
    localparam int unsigned ADDR_WIDTH = `MEM_ADDR_WIDTH - ADDR_OFFSET_BITS;

    localparam int unsigned XLEN = `XLEN;

    // Word address sent to the dcache (byte offset stripped).
    wire  [      ADDR_WIDTH-1:0] aligned_addr = ADDR_WIDTH'(mem_if[0].req_addr >> ADDR_OFFSET_BITS);
    wire  [ADDR_OFFSET_BITS-1:0] word_offset = mem_if[0].req_addr[ADDR_OFFSET_BITS-1:0];
    wire                         req_is_write = (mem_if[0].req_cmd != mmu_pkg::PTW_MEM_READ);
    logic [ADDR_OFFSET_BITS-1:0] word_offset_r;
    logic                        req_sent;
    always_ff @(posedge clk) begin
        if (reset) begin
            req_sent                <= 1'b0;
            word_offset_r           <= '0;
            mem_if[0].req_ready     <= 1'b0;
            mem_bus_if[0].req_valid <= 1'b0;
            mem_bus_if[0].req_data  <= '0;
        end else begin
            mem_if[0].req_ready <= 1'b0;  // pulses one cycle per accepted request
            if (mem_bus_if[0].req_valid) begin
                if (mem_bus_if[0].req_ready) begin  // dcache accepted the request
                    mem_bus_if[0].req_valid <= 1'b0;
                    mem_if[0].req_ready     <= 1'b1;
                    req_sent                <= 1'b1;
                end
            end else if (mem_if[0].req_valid && !req_sent) begin
                mem_bus_if[0].req_valid <= 1'b1;
                mem_bus_if[0].req_data.rw <= req_is_write;
                mem_bus_if[0].req_data.addr <= aligned_addr;
                // Writes update only the PTE's bytes within the line; the wdata
                // and byte enables are shifted to the PTE's offset.
                mem_bus_if[0].req_data.byteen <= req_is_write
                    ? WORD_SIZE'(mem_if[0].req_wbe) << word_offset
                    : {WORD_SIZE{1'b1}};
                mem_bus_if[0].req_data.data <= LINE_BITS'(mem_if[0].req_wdata) << (word_offset * 8);
                mem_bus_if[0].req_data.flags <= '0;  // < global memory access
                mem_bus_if[0].req_data.tag.uuid <= '0;
                mem_bus_if[0].req_data.tag.value <= '0;
                word_offset_r <= word_offset;
            end
            if (!mem_if[0].req_valid) req_sent <= 1'b0;
        end
    end

    // Response channel: dcache -> PTW (reads only; writes are posted)
    always_ff @(posedge clk) begin
        if (reset) begin
            mem_if[0].rsp_valid     <= 1'b0;
            mem_if[0].rsp_data      <= '0;
            mem_if[0].rsp_error     <= 1'b0;
            mem_bus_if[0].rsp_ready <= 1'b0;
        end else begin
            mem_if[0].rsp_valid     <= mem_bus_if[0].rsp_valid;
            mem_if[0].rsp_error     <= 1'b0;  // no PTE-access fault reported by the dcache
            mem_if[0].rsp_data      <= 64'(mem_bus_if[0].rsp_data.data[word_offset_r*8+:XLEN]);
            mem_bus_if[0].rsp_ready <= 1'b1;  // the MMU always accepts the response
        end
    end
endmodule
