interface tlb_storage_if #(
    parameter int unsigned ASID_SIZE      = mmu_pkg::ASID_SIZE,
    parameter int unsigned VPN_SIZE       = mmu_pkg::VPN_SIZE,
    parameter int unsigned LEVELS         = mmu_pkg::LEVELS,
    parameter int unsigned TLB_ENTRIES,
    parameter int unsigned NUM_READ_PORTS = 1
);

    localparam int unsigned LEVEL_BITS = $clog2(LEVELS);
    localparam int unsigned TLB_IDX_SIZE = $clog2(TLB_ENTRIES);

    typedef struct packed {
        logic [ASID_SIZE-1:0] asid;
        logic [VPN_SIZE-1:0]  vpn;
    } storage_read_req_t;

    typedef struct packed {
        logic                    is_hit;
        logic [TLB_IDX_SIZE-1:0] hit_idx;
        logic [LEVEL_BITS-1:0]   hit_level;
        mmu_pkg::tlb_entry_t     hit_entry;
    } storage_read_resp_t;

    typedef struct packed {
        // Write operation
        logic                    write_tlb;
        logic [TLB_IDX_SIZE-1:0] write_idx;
        mmu_pkg::tlb_entry_t     write_entry;
    } storage_update_req_t;

    typedef struct packed {
        logic                   clear_tlb;
        logic [TLB_ENTRIES-1:0] clear_mask;
    } storage_clear_req_t;

    typedef struct packed {
        storage_update_req_t update_req;
        storage_clear_req_t  clear_req;
    } tlb_storage_write_comm_t;

    storage_read_req_t                     read_req      [NUM_READ_PORTS];
    storage_read_resp_t                    read_resp     [NUM_READ_PORTS];
    storage_update_req_t                   update_req;
    storage_clear_req_t                    clear_req;
    // Indicates if there is at least one invalid entry in the TLB storage, used for replacement policy.
    logic                                  tlb_has_invalid_entry;
    // The index of an invalid entry in the TLB storage, used for replacement policy.
    logic               [TLB_IDX_SIZE-1:0] tlb_invalid_entry_idx;

    modport master(
        output read_req,
        input read_resp,
        output update_req,
        output clear_req,
        input tlb_has_invalid_entry,
        input tlb_invalid_entry_idx
    );

    modport slave(
        input read_req,
        output read_resp,
        input update_req,
        input clear_req,
        output tlb_has_invalid_entry,
        output tlb_invalid_entry_idx
    );

endinterface
