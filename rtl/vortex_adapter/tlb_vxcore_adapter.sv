`include "VX_define.vh"

module tlb_vxcore_adapter #(
    parameter int unsigned NUM_ITLB_PORTS = 1,
    parameter int unsigned NUM_DTLB_PORTS = `NUM_LSU_BLOCKS * `NUM_LSU_LANES
) (
    core_tlb_if.master     itlb_core [NUM_ITLB_PORTS],
    core_tlb_if.master     dtlb_core [NUM_DTLB_PORTS],
    VX_addr_trans_if.slave itlb_if   [NUM_ITLB_PORTS],
    VX_addr_trans_if.slave dtlb_if   [NUM_DTLB_PORTS],
    VX_csr_mmu_if.slave    csr_mmu_if
);

    // ---------------------------------------------------------------------------
    // Address translation helpers
    // ---------------------------------------------------------------------------

    // Extract virtual page number from a full VA.
    // MMU req.vpn is [VPN_WIDTH:0] = 28 bits (SV39-sized).
    // Vortex SV32 VPN = VA[31:12] = 20 bits; SV39 VPN = VA[38:12] = 27 bits.
    // Upper bits are zero-padded via a local variable initialised to '0.
    /* verilator lint_off UNUSEDSIGNAL */  // in case VPN_WIDTH+1 is not a multiple of 4
    function automatic logic [mmu_pkg::VPN_WIDTH-1:0] va2vpn(input logic [`XLEN-1:0] va);
        logic [mmu_pkg::VPN_WIDTH-1:0] vpn;
        vpn                                = '0;
        vpn[`XLEN-`MEM_PAGE_LOG2_SIZE-1:0] = va[`XLEN-1:`MEM_PAGE_LOG2_SIZE];
        return vpn;
    endfunction

    // Extract the 12-bit page offset from a VA.
    function automatic logic [`MEM_PAGE_LOG2_SIZE-1:0] va2off(input logic [`XLEN-1:0] va);
        return va[`MEM_PAGE_LOG2_SIZE-1:0];
    endfunction

    // Reconstruct a physical address from the BSC PPN response and the page offset.
    // BSC PPN is PPN_WIDTH=44 bits; Vortex only uses the low
    // (MEM_ADDR_WIDTH - MEM_PAGE_LOG2_SIZE) bits (20 bits for XLEN=32, 36 for XLEN=64).
    function automatic logic [`MEM_ADDR_WIDTH-1:0] ppn2pa(
        input logic [mmu_pkg::PPN_WIDTH-1:0] ppn, input logic [`MEM_PAGE_LOG2_SIZE-1:0] offset);
        return {ppn[`MEM_ADDR_WIDTH-`MEM_PAGE_LOG2_SIZE-1:0], offset};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // vm_enable: SATP MODE bit controls whether address translation is active.
    // SV32 (XLEN=32): satp[31]=1 enables paging. SV39/SV48 (XLEN=64): satp[63]!=0.
    // Must be a named wire (not inline in genvar loops) to avoid Verilator issues.
    logic vm_enable;
    assign vm_enable = csr_mmu_if.satp[`XLEN-1];

    // The core always accepts the response immediately, so rsp_ready is tied
    // high; rsp_valid then signals a definitive result (translation or fault).

    // ---------------------------------------------------------------------------
    // iTLB (one port per core)
    // ---------------------------------------------------------------------------
    for (genvar i = 0; i < NUM_ITLB_PORTS; ++i) begin : g_itlb_if
        assign itlb_core[i].req_valid = itlb_if[i].valid;
        assign itlb_core[i].req_data.asid = '0;  // GPU: single shared address space
        assign itlb_core[i].req_data.vpn = va2vpn(itlb_if[i].va);
        assign itlb_core[i].req_data.instruction = 1;  // instruction access
        assign itlb_core[i].req_data.store = 0;  // not a store access
        assign itlb_core[i].req_data.priv_lvl = 0;  // always user mode for the GPU
        assign itlb_core[i].req_data.vm_enable = vm_enable;
        assign itlb_core[i].rsp_ready = 1'b1;
        assign itlb_if[i].pa = ppn2pa(itlb_core[i].rsp_data.ppn, va2off(itlb_if[i].va));
        assign itlb_if[i].ready = itlb_core[i].rsp_valid;
        assign itlb_if[i].fault = itlb_core[i].rsp_valid && itlb_core[i].rsp_data.xcpt.fetch;
    end

    // ---------------------------------------------------------------------------
    // dTLB (one port per LSU lane)
    // ---------------------------------------------------------------------------
    for (genvar i = 0; i < NUM_DTLB_PORTS; ++i) begin : g_dtlb_if
        assign dtlb_core[i].req_valid = dtlb_if[i].valid;
        assign dtlb_core[i].req_data.asid = '0;  // GPU: single shared address space
        assign dtlb_core[i].req_data.vpn = va2vpn(dtlb_if[i].va);
        assign dtlb_core[i].req_data.instruction = 0;  // data access
        assign dtlb_core[i].req_data.store = dtlb_if[i].store;
        assign dtlb_core[i].req_data.priv_lvl = 0;  // always user mode for the GPU
        assign dtlb_core[i].req_data.vm_enable = vm_enable;
        assign dtlb_core[i].rsp_ready = 1'b1;
        assign dtlb_if[i].pa = ppn2pa(dtlb_core[i].rsp_data.ppn, va2off(dtlb_if[i].va));
        assign dtlb_if[i].ready = dtlb_core[i].rsp_valid;
        assign dtlb_if[i].fault = dtlb_core[i].rsp_valid
                 && (dtlb_core[i].rsp_data.xcpt.load || dtlb_core[i].rsp_data.xcpt.store);
    end

endmodule
