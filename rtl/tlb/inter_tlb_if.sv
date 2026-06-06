interface inter_tlb_if #(
    // parameter int VPN_SIZE  = mmu_pkg::VPN_SIZE,
    // parameter int ASID_SIZE = mmu_pkg::ASID_SIZE
);

    logic req_valid, req_ready;
    mmu_pkg::inter_tlb_req_data_t req_data;
    logic rsp_valid, rsp_ready;
    mmu_pkg::inter_tlb_rsp_data_t rsp_data;

    // Broadcast flush from L2 -> L1. NOT request-matched: it is driven to every
    // L1 identically and must not ride the response channel.
    logic invalidate_tlb;

    modport master (
        output req_valid,
        output req_data,
        input req_ready,

        input rsp_valid,
        input rsp_data,
        output rsp_ready,

        input invalidate_tlb
    );

    modport slave (
        input req_valid,
        input req_data,
        output req_ready,

        output rsp_valid,
        output rsp_data,
        input rsp_ready,

        output invalidate_tlb
    );

endinterface
