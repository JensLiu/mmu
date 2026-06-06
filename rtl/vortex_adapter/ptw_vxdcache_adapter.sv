`include "VX_define.vh"

module ptw_vxdcache_adapter #(
    parameter int unsigned NUM_PTWS = 1
) (
    input  logic                    clk,
    input  logic                    reset,
    output mmu_pkg::dmem_ptw_comm_t dmem_ptw_comm_o[NUM_PTWS],
    input  mmu_pkg::ptw_dmem_comm_t ptw_dmem_comm_i[NUM_PTWS],

    VX_mem_bus_if.master mem_bus_if[NUM_PTWS]
);
    // The adapter converts PTW memory requests to Vortex dcache format.
    // Supports both SV32 (XLEN=32, 4-byte PTEs) and SV39 (XLEN=64, 8-byte PTEs).
    //
    // Assumptions:
    //  - PTW provides byte-aligned physical addresses
    //  - PTW request is held stable until response is received
    //  - Single outstanding request at a time

    // We are adapting to the L2 cache interface
    localparam int unsigned WORD_SIZE = VX_gpu_pkg::DCACHE_LINE_SIZE;
    localparam int unsigned ADDR_OFFSET_BITS = $clog2(WORD_SIZE);
    localparam int unsigned ADDR_WIDTH = `MEM_ADDR_WIDTH - ADDR_OFFSET_BITS;

    // PTE size in bytes: 4 for SV32 (XLEN=32), 8 for SV39 (XLEN=64)
    // localparam int unsigned PTE_SIZE = `XLEN / 8;
    // Response data width matches dmem_ptw_resp_t::data (always 64 bits)
    localparam int unsigned PTW_DATA_WIDTH = 64;

    // Word address sent to the dcache (DCACHE_ADDR_WIDTH bits).
    // DCACHE_ADDR_WIDTH is already a word-address width (byte offset stripped).
    // Extract from the PTW byte address by dropping the low DCACHE_ADDR_OFFSET_BITS bits:
    //   word_addr = byte_addr[DCACHE_ADDR_WIDTH+DCACHE_ADDR_OFFSET_BITS-1 : DCACHE_ADDR_OFFSET_BITS]
    //             = byte_addr[MEM_ADDR_WIDTH-1 : log2(DCACHE_WORD_SIZE)]
    logic [      ADDR_WIDTH-1:0] aligned_addr;
    // Byte offset within the dcache word (selects which PTE inside the cache word).
    logic [ADDR_OFFSET_BITS-1:0] word_offset;
    // Registered word_offset for response extraction (captured when request is sent)
    logic [ADDR_OFFSET_BITS-1:0] word_offset_r;
    always_comb begin
        // Strip low DCACHE_ADDR_OFFSET_BITS (byte offset within word) to get word address.
        aligned_addr = ADDR_WIDTH'(ptw_dmem_comm_i[0].req.addr >> ADDR_OFFSET_BITS);
        word_offset  = ptw_dmem_comm_i[0].req.addr[ADDR_OFFSET_BITS-1:0];
    end
    // However, we register it for timing closure since response path is registered.
    always_ff @(posedge clk) begin
        if (reset) begin
            word_offset_r <= '0;
        end else if (ptw_dmem_comm_i[0].req.valid) begin
            word_offset_r <= word_offset;
        end
    end
    // NOTE: The MMU expect synchronous response

    // IMPORTANT:
    // PTW holds req.valid combinatorially high for 2 extra cycles after the dcache handshake
    // because both the request path and dmem_ready path are registered (1 cycle each).
    // Cache hits have no MSHR entry to detect duplicates, so the dcache accepts it and
    // returns a second response that corrupts the next page-table walk.
    // req_accepted suppresses re-assertion until PTW deasserts req.valid (entering S_WAIT).
    logic req_accepted;
    // Request: PTW → dcache
    // NOTE: we don't need to check the offset because Vortex doesn't have atomic operations
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
            // PTW deasserts req.valid when entering S_WAIT (between walk levels).
            // That clears req_accepted so the next walk level can fire.
            if (!ptw_dmem_comm_i[0].req.valid) begin
                req_accepted            <= 1'b0;
                mem_bus_if[0].req_valid <= 1'b0;
            end else if (mem_bus_if[0].req_valid && mem_bus_if[0].req_ready) begin
                // Handshake: suppress re-assertion while PTW still holds req.valid high.
                req_accepted            <= 1'b1;
                mem_bus_if[0].req_valid <= 1'b0;
            end else if (!req_accepted) begin
                mem_bus_if[0].req_valid <= ptw_dmem_comm_i[0].req.valid;
            end
            mem_bus_if[0].req_data.rw        <= 0;
            mem_bus_if[0].req_data.addr      <= aligned_addr;
            mem_bus_if[0].req_data.byteen    <= '1;
            mem_bus_if[0].req_data.data      <= '0;
            mem_bus_if[0].req_data.flags     <= '0;  // < global memory access
            // Tag is all zeros: UUID=0 (debug only), ClientID=0 (injected by VX_dcache_req_hub), rest=0.
            mem_bus_if[0].req_data.tag.uuid  <= '0;
            mem_bus_if[0].req_data.tag.value <= '0;
        end
    end


    // Response: dcache → PTW
    always_ff @(posedge clk) begin
        if (reset) begin
            dmem_ptw_comm_o[0].dmem_ready <= 1'b0;
            dmem_ptw_comm_o[0].resp       <= '0;
            mem_bus_if[0].rsp_ready       <= 1'b0;
        end else begin
            dmem_ptw_comm_o[0].dmem_ready <= mem_bus_if[0].req_ready;
            dmem_ptw_comm_o[0].resp.valid <= mem_bus_if[0].rsp_valid;
            dmem_ptw_comm_o[0].resp.nack <= '0;
            dmem_ptw_comm_o[0].resp.addr <= '0;
            dmem_ptw_comm_o[0].resp.tag_addr <= '0;
            dmem_ptw_comm_o[0].resp.cmd <= '0;
            dmem_ptw_comm_o[0].resp.typ <= '0;
            dmem_ptw_comm_o[0].resp.replay <= '0;
            dmem_ptw_comm_o[0].resp.has_data <= '0;
            dmem_ptw_comm_o[0].resp.data_subw <= '0;
            dmem_ptw_comm_o[0].resp.store_data <= '0;
            dmem_ptw_comm_o[0].resp.rnvalid <= '0;
            dmem_ptw_comm_o[0].resp.rnext <= '0;
            dmem_ptw_comm_o[0].resp.xcpt_ma_ld <= '0;
            dmem_ptw_comm_o[0].resp.xcpt_ma_st <= '0;
            dmem_ptw_comm_o[0].resp.xcpt_pf_ld <= '0;
            dmem_ptw_comm_o[0].resp.xcpt_pf_st <= '0;
            dmem_ptw_comm_o[0].resp.ordered <= '0;
            // Extract one PTE (XLEN bits) at the byte offset within the cache word,
            // then zero-extend to PTW_DATA_WIDTH (64b). For SV32: 32b→64b; SV39: 64b→64b.
            // Use registered offset to match the original request.
            dmem_ptw_comm_o[0].resp.data <=
          PTW_DATA_WIDTH'(mem_bus_if[0].rsp_data.data[word_offset_r*8+:`XLEN]);
            mem_bus_if[0].rsp_ready <= 1'b1;  // < The MMU always accept the response
        end
    end
endmodule
