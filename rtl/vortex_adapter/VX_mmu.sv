`include "VX_config.vh"

module VX_mmu #(
    parameter int unsigned NUM_CORES             = 1,
    parameter int unsigned NUM_CHANNELS_PER_CORE = 1,
    // One dTLB port per translated data request (PTW requests are already physical).
    parameter int unsigned NUM_DTLB_PORTS        = NUM_CORES * NUM_CHANNELS_PER_CORE,
    parameter int unsigned NUM_ITLB_PORTS        = NUM_CORES,
    parameter int unsigned NUM_PTW_PORTS         = 1
) (
    input logic clk,
    input logic reset,

    VX_addr_trans_if.slave iaddr_if      [NUM_ITLB_PORTS],
    VX_addr_trans_if.slave daddr_if      [NUM_DTLB_PORTS],
    VX_csr_mmu_if.slave    csr_mmu_if,
    VX_mem_bus_if.master   ptw_mem_bus_if[ NUM_PTW_PORTS]
);

    // iTLB / dTLB request-response interfaces (shared between the core adapter
    // (master) and bsc_mmu (slave)).
    core_tlb_if itlb_core_if[NUM_ITLB_PORTS] ();
    core_tlb_if dtlb_core_if[NUM_DTLB_PORTS] ();
    // CSR Interface
    mmu_pkg::csr_ptw_comm_t  csr_ptw_comm_i;
    // TODO: currently only support RV32
    assign csr_ptw_comm_i.satp    = {{(64 - `XLEN) {1'b0}}, csr_mmu_if.satp};  // < zero-extend satp
    assign csr_ptw_comm_i.flush   = csr_mmu_if.flush_tlb;
    assign csr_ptw_comm_i.mstatus = mmu_pkg::csr_mstatus_t'(csr_mmu_if.mstatus);

    // PTW - Memory Interface
    mmu_pkg::ptw_dmem_comm_t ptw_dmem_comm_o[NUM_PTW_PORTS];
    mmu_pkg::dmem_ptw_comm_t dmem_ptw_comm_i[NUM_PTW_PORTS];

    mmu #(
        .NUM_DTLBS_PER_CORE(NUM_CHANNELS_PER_CORE),
        .NUM_CORES         (NUM_CORES),
        .XLEN              (`XLEN)
    ) mmu_inst (
        .clk_i       (clk),
        .rstn_i      (~reset),
        .itlb_core_if(itlb_core_if),
        .dtlb_core_if(dtlb_core_if),
        .csr_ptw_comm_i(csr_ptw_comm_i),
        // currently, we only support 1 PTW port
        .ptw_dmem_comm_o(ptw_dmem_comm_o[0]),
        .dmem_ptw_comm_i(dmem_ptw_comm_i[0])
    );

    tlb_vxcore_adapter #(
        .NUM_ITLB_PORTS(NUM_ITLB_PORTS),
        .NUM_DTLB_PORTS(NUM_DTLB_PORTS)
    ) tlb_adapter (
        .itlb_core (itlb_core_if),
        .dtlb_core (dtlb_core_if),
        .itlb_if   (iaddr_if),
        .dtlb_if   (daddr_if),
        .csr_mmu_if(csr_mmu_if)
    );

    ptw_vxdcache_adapter #(
        .NUM_PTWS(NUM_PTW_PORTS)
    ) ptw_adapter (
        .clk            (clk),
        .reset          (reset),
        .dmem_ptw_comm_o(dmem_ptw_comm_i),
        .ptw_dmem_comm_i(ptw_dmem_comm_o),
        .mem_bus_if     (ptw_mem_bus_if)
    );

endmodule
