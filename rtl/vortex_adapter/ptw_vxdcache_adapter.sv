`include "VX_define.vh"

// The adapter converts PTW memory requests to Vortex dcache format.
// Supports both SV32 (XLEN=32, 4-byte PTEs) and SV39 (XLEN=64, 8-byte PTEs).
// Assumptions:
//  - PTW provides byte-aligned physical addresses (PTEs never straddle a line)
//  - PTW holds the request stable until req_ready pulses
//  - Single outstanding request at a time
//  - Writes are posted: the dcache sends no write response, so the req_ready
//    pulse is the only completion the PTW gets (see ptw_mem_if).
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
    // Byte offset of the PTE within the dcache word.
    wire  [ADDR_OFFSET_BITS-1:0] word_offset = mem_if[0].req_addr[ADDR_OFFSET_BITS-1:0];
    wire                         req_is_write = (mem_if[0].req_cmd != mmu_pkg::PTW_MEM_READ);

    // Registered word_offset for response extraction (captured at launch)
    logic [ADDR_OFFSET_BITS-1:0] word_offset_r;

    // Request channel: capture the PTW request once, hold it on the bus until
    // the dcache accepts it, then pulse req_ready back. The held request never
    // changes or cancels mid-flight, and the PTW only advances on the pulse, so
    // exactly one bus request fires per PTW request. req_sent suppresses a
    // relaunch while the PTW is still holding req_valid (its ready/state path
    // lags the pulse by a cycle).
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
            // Extract one PTE (XLEN bits) at the byte offset within the cache word,
            // then zero-extend to 64b (SV32: 32b->64b; SV39: 64b->64b). Uses the
            // registered offset so it matches the original request.
            mem_if[0].rsp_data      <= 64'(mem_bus_if[0].rsp_data.data[word_offset_r*8+:XLEN]);
            mem_bus_if[0].rsp_ready <= 1'b1;  // < the MMU always accepts the response
        end
    end
endmodule
