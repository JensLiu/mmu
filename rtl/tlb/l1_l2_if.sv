interface l1_l2_if #(
    // parameter int VPN_SIZE  = mmu_pkg::VPN_SIZE,
    // parameter int ASID_SIZE = mmu_pkg::ASID_SIZE
);

    // typedef struct packed {
    //     logic valid;  // Translation request valid.
    //     logic [VPN_SIZE-1:0] vpn;  // Virtual page number.
    //     logic [ASID_SIZE-1:0] asid;  // Address space identifier.
    //     logic [1:0]  prv;      // Privilege level of the translation: 2'b00 (User), 2'b01 (Supervisor), 2'b11 (Machine).
    //     logic store_hit;    // should write to memory (from L1's perspective)
    //     logic store;  // Store operation.
    //     logic fetch;  // Fetch operation.
    // } req_data_t;  // Translation request of the TLB to the PTW.

    // typedef struct packed {
    //     logic   error; // An error has ocurred with the translation request. Only check if the response is valid.
    //     mmu_pkg::tlb_entry_t tlb_entry;
    // } rsp_data_t;

    logic req_valid, req_ready;
    mmu_pkg::l1_l2_req_data_t req_data;  // ignore the embedded valid field; req_valid is the handshake
    logic rsp_valid, rsp_ready;
    mmu_pkg::l2_l1_rsp_data_t rsp_data;  // ignore the embedded valid field; rsp_valid is the handshake

    // Broadcast flush from L2 -> L1. NOT request-matched: it is driven to every
    // L1 identically and must not ride the response channel.
    logic invalidate_tlb;

    modport l1 (
        output req_valid,
        output req_data,
        input req_ready,

        input rsp_valid,
        input rsp_data,
        output rsp_ready,

        input invalidate_tlb
    );

    modport l2 (
        input req_valid,
        input req_data,
        output req_ready,

        output rsp_valid,
        output rsp_data,
        input rsp_ready,

        output invalidate_tlb
    );

endinterface
