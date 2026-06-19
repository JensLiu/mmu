`include "VX_define.vh"

// The adapter converts PTW memory requests to Vortex dcache format.
// Supports both SV32 (XLEN=32, 4-byte PTEs) and SV39 (XLEN=64, 8-byte PTEs).
// Assumptions:
//  - PTW provides byte-aligned physical addresses (PTEs never straddle a line)
//  - PTW holds the request stable until req_ready pulses
//  - Single outstanding request at a time
//  - Writes are posted: the dcache sends no write response, so the req_ready
//    pulse is the only completion the PTW gets (see ptw_mem_if).
module ptw_vxdcache_adapter_v2 #(
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
    wire [      ADDR_WIDTH-1:0] aligned_addr = ADDR_WIDTH'(mem_if[0].req_addr >> ADDR_OFFSET_BITS);
    // Byte offset of the PTE within the dcache word.
    wire [ADDR_OFFSET_BITS-1:0] word_offset = mem_if[0].req_addr[ADDR_OFFSET_BITS-1:0];
    wire                        req_is_write = (mem_if[0].req_cmd != mmu_pkg::PTW_MEM_READ);

    // -------------------------------------------------------------------------
    // Request channel: combinational pass-through. The PTW holds req_* stable
    // until req_ready (single outstanding, never cancels mid-flight) and its
    // req_valid does not depend on req_ready, so forwarding ready straight back
    // creates no combinational loop and needs no holding register.
    // -------------------------------------------------------------------------
    always_comb begin
        mem_bus_if[0].req_valid = mem_if[0].req_valid;
        mem_bus_if[0].req_data = '0;
        mem_bus_if[0].req_data.rw = req_is_write;
        mem_bus_if[0].req_data.addr = aligned_addr;
        // Writes update only the PTE's bytes within the line; the wdata and byte
        // enables are shifted to the PTE's offset. Reads enable the whole word.
        mem_bus_if[0].req_data.byteen = req_is_write
            ? WORD_SIZE'(mem_if[0].req_wbe) << word_offset
            : {WORD_SIZE{1'b1}};
        mem_bus_if[0].req_data.data = LINE_BITS'(mem_if[0].req_wdata) << (word_offset * 8);
        mem_bus_if[0].req_data.flags = '0;  // < global memory access
        // Tag is all zeros: UUID=0 (debug), ClientID injected downstream.
        mem_bus_if[0].req_data.tag = '0;
    end
    assign mem_if[0].req_ready = mem_bus_if[0].req_ready;

    // The only retained state: the byte offset of the outstanding read, latched
    // on req-fire so the response extraction matches even if the PTW advances.
    wire                         req_fire = mem_if[0].req_valid && mem_bus_if[0].req_ready;
    logic [ADDR_OFFSET_BITS-1:0] word_offset_r;
    always_ff @(posedge clk) begin
        if (reset) word_offset_r <= '0;
        else if (req_fire) word_offset_r <= word_offset;
    end

    // -------------------------------------------------------------------------
    // Response channel: combinational dcache -> PTW (reads only; writes posted).
    // The PTW's rsp_ready is constant 1, so the dcache is always drained.
    // -------------------------------------------------------------------------
    assign mem_if[0].rsp_valid     = mem_bus_if[0].rsp_valid;
    assign mem_if[0].rsp_error     = 1'b0;  // no PTE-access fault reported by the dcache
    // Extract one PTE (XLEN bits) at the registered byte offset within the cache
    // word, then zero-extend to 64b (SV32: 32b->64b; SV39: 64b->64b).
    assign mem_if[0].rsp_data      = 64'(mem_bus_if[0].rsp_data.data[word_offset_r*8+:XLEN]);
    assign mem_bus_if[0].rsp_ready = 1'b1;  // < the MMU always accepts the response
endmodule
