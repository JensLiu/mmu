`include "VX_define.vh"

// The adapter converts PTW memory requests to Vortex dcache format.
// Supports both SV32 (XLEN=32, 4-byte PTEs) and SV39 (XLEN=64, 8-byte PTEs).
// Assumptions:
//  - PTW provides byte-aligned physical addresses
//  - PTW request is held stable until response is received
//  - Single outstanding request at a time
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
    localparam int unsigned ADDR_OFFSET_BITS = $clog2(WORD_SIZE);
    localparam int unsigned ADDR_WIDTH = `MEM_ADDR_WIDTH - ADDR_OFFSET_BITS;

    // Response data width matches the PTW interface (always 64 bits)
    localparam int unsigned PTW_DATA_WIDTH = 64;

    // Word address sent to the dcache (byte offset stripped).
    logic [      ADDR_WIDTH-1:0] aligned_addr;
    // Byte offset within the dcache word (selects which PTE inside the cache word).
    logic [ADDR_OFFSET_BITS-1:0] word_offset;
    // Registered word_offset for response extraction (captured when request is sent)
    logic [ADDR_OFFSET_BITS-1:0] word_offset_r;
    always_comb begin
        aligned_addr = ADDR_WIDTH'(mem_if[0].req_addr >> ADDR_OFFSET_BITS);
        word_offset  = mem_if[0].req_addr[ADDR_OFFSET_BITS-1:0];
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            word_offset_r <= '0;
        end else if (mem_if[0].req_valid) begin
            word_offset_r <= word_offset;
        end
    end

    // IMPORTANT:
    // PTW holds req_valid combinatorially high for 2 extra cycles after the dcache
    // handshake because both the request path and req_ready path are registered.
    // Cache hits have no MSHR entry to detect duplicates, so the dcache accepts it
    // and returns a second response that corrupts the next walk.  req_accepted
    // suppresses re-assertion until PTW deasserts req_valid (entering S_WAIT).
    logic req_accepted;
    // Read vs write (A/D write-back). Walks are read-only today, so this is 0;
    // wired from req_cmd so the write path drops in once the PTW emits writes.
    // TODO: a write also needs req_wdata placed at word_offset + byteen set.
    wire  req_is_write = (mem_if[0].req_cmd != mmu_pkg::PTW_MEM_READ);

    // Request: PTW -> dcache
    always_ff @(posedge clk) begin
        if (reset) begin
            req_accepted                     <= 1'b0;
            mem_bus_if[0].req_valid          <= 1'b0;
            mem_bus_if[0].req_data.rw        <= '0;
            mem_bus_if[0].req_data.addr      <= '0;
            mem_bus_if[0].req_data.byteen    <= '0;
            mem_bus_if[0].req_data.data      <= '0;
            mem_bus_if[0].req_data.flags     <= '0;
            mem_bus_if[0].req_data.tag.uuid  <= '0;
            mem_bus_if[0].req_data.tag.value <= '0;
        end else begin
            if (!mem_if[0].req_valid) begin
                req_accepted            <= 1'b0;
                mem_bus_if[0].req_valid <= 1'b0;
            end else if (mem_bus_if[0].req_valid && mem_bus_if[0].req_ready) begin
                req_accepted            <= 1'b1;
                mem_bus_if[0].req_valid <= 1'b0;
            end else if (!req_accepted) begin
                mem_bus_if[0].req_valid <= mem_if[0].req_valid;
            end
            mem_bus_if[0].req_data.rw        <= req_is_write;
            mem_bus_if[0].req_data.addr      <= aligned_addr;
            mem_bus_if[0].req_data.byteen    <= '1;
            mem_bus_if[0].req_data.data      <= '0;  // TODO: A/D write-back data
            mem_bus_if[0].req_data.flags     <= '0;  // < global memory access
            // Tag is all zeros: UUID=0 (debug), ClientID injected downstream, rest=0.
            mem_bus_if[0].req_data.tag.uuid  <= '0;
            mem_bus_if[0].req_data.tag.value <= '0;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            mem_if[0].req_ready     <= 1'b0;
            mem_if[0].rsp_valid     <= 1'b0;
            mem_if[0].rsp_data      <= '0;
            mem_if[0].rsp_error     <= 1'b0;
            mem_bus_if[0].rsp_ready <= 1'b0;
        end else begin
            mem_if[0].req_ready <= mem_bus_if[0].req_ready;
            mem_if[0].rsp_valid <= mem_bus_if[0].rsp_valid;
            mem_if[0].rsp_error <= 1'b0;  // no PTE-access fault reported by the dcache
            // Extract one PTE (XLEN bits) at the byte offset within the cache word,
            // then zero-extend to 64b (SV32: 32b->64b; SV39: 64b->64b). Uses the
            // registered offset so it matches the original request.
            mem_if[0].rsp_data <=
                PTW_DATA_WIDTH'(mem_bus_if[0].rsp_data.data[word_offset_r*8+:`XLEN]);
            mem_bus_if[0].rsp_ready <= 1'b1;  // < the MMU always accepts the response
        end
    end
endmodule
