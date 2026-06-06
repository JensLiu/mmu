// Core <-> L1 TLB interface.
//
// Decoupled valid/ready handshake, modelled on inter_tlb_if: a request channel
// (core -> TLB) and a response channel (TLB -> core).  The requester holds the
// request until it is answered; the TLB asserts rsp_valid only when it has a
// definitive result (a translation or a fault).  A miss simply leaves rsp_valid
// low while the walk is in flight.
interface core_tlb_if;

    // Generic handshake: a given master need not consume every field (e.g. the
    // GPU adapter ignores req_ready, rsp_data.hit_idx and the high PPN bits),
    // so UNUSEDSIGNAL is expected on the interface nets.

    /* verilator lint_off UNUSEDSIGNAL */
    logic req_valid, req_ready;
    mmu_pkg::core_tlb_req_data_t req_data;

    logic rsp_valid, rsp_ready;
    mmu_pkg::core_tlb_rsp_data_t rsp_data;
    /* verilator lint_on UNUSEDSIGNAL */

    modport master(  // translation requester (core)
        output req_valid,
        output req_data,
        input req_ready,

        input rsp_valid,
        input rsp_data,
        output rsp_ready
    );

    modport slave(  // L1 TLB
        input req_valid,
        input req_data,
        output req_ready,

        output rsp_valid,
        output rsp_data,
        input rsp_ready
    );

endinterface
