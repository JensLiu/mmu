
module l2_tlb_mshr #(
    parameter  int unsigned MSHR_SIZE    = 4,
    parameter  int unsigned NUM_CORES    = 32,
    localparam int unsigned VPN_WIDTH    = mmu_pkg::VPN_WIDTH,
    localparam int unsigned ASID_WIDTH   = mmu_pkg::ASID_WIDTH,
    localparam int unsigned LEVEL_BITS   = mmu_pkg::LEVEL_BITS,
    localparam int unsigned TAG_W        = (MSHR_SIZE > 1) ? $clog2(MSHR_SIZE) : 1,
    localparam int unsigned CORE_ID_SIZE = (NUM_CORES > 1) ? $clog2(NUM_CORES) : 1
) (
    input logic clk_i,
    input logic rst_i,

    // Allocate
    input  logic                    allocate_valid_i,
    output logic                    allocate_ready_o,
    input  logic [   VPN_WIDTH-1:0] allocate_vpn_i,
    input  logic [  ASID_WIDTH-1:0] allocate_asid_i,
    input  logic                    allocate_set_dirty_i,  // store (needs dirty)
    input  logic [CORE_ID_SIZE-1:0] allocate_core_id_i,

    // Issue (to PTW)
    output logic                  issue_valid_o,
    input  logic                  issue_ready_i,
    output logic [     TAG_W-1:0] issue_id_o,
    output logic [ VPN_WIDTH-1:0] issue_vpn_o,
    output logic [ASID_WIDTH-1:0] issue_asid_o,
    output logic                  issue_set_dirty_o,

    // Fill (from PTW, keyed by tag)
    input  logic                           fill_valid_i,
    output logic                           fill_ready_o,
    input  logic          [     TAG_W-1:0] fill_id_i,
    input  mmu_pkg::pte_t                  fill_pte_i,
    input  logic          [LEVEL_BITS-1:0] fill_level_i,
    input  logic                           fill_error_i,

    // Deliver (to the deliver engine; snapshot + advance/free)
    output logic                           deliver_valid_o,
    input  logic                           deliver_ready_i,
    output logic          [ NUM_CORES-1:0] deliver_cores_o,
    output mmu_pkg::pte_t                  deliver_pte_o,
    output logic          [LEVEL_BITS-1:0] deliver_level_o,
    output logic                           deliver_error_o,
    output logic          [ VPN_WIDTH-1:0] deliver_vpn_o,
    output logic          [ASID_WIDTH-1:0] deliver_asid_o,
    output logic                           deliver_write_cache_o, // terminal & !error

    // Issue-pending bitmask (one bit per slot in a *_PENDING_ISSUE state)
    output logic [MSHR_SIZE-1:0] pending_entries_o
);

    // -------------------------------------------------------------------------
    // Entry
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        ES_INVALID,
        ES_CLEAN_PENDING_ISSUE,
        ES_CLEAN_PENDING_FILL,
        ES_CLEAN_PENDING_DELIVER,
        ES_DIRTY_PENDING_ISSUE,
        ES_DIRTY_PENDING_FILL,
        ES_DIRTY_PENDING_DELIVER
    } mshr_entry_state_t;

    typedef struct packed {
        mshr_entry_state_t     state;
        logic [VPN_WIDTH-1:0]  vpn;
        logic [ASID_WIDTH-1:0] asid;
        logic                  set_dirty;
        logic                  dirty_poison;
        logic [NUM_CORES-1:0]  pending_cores;  // delivered this pass
        logic [NUM_CORES-1:0]  dirty_cores;    // held stores, become the next pass
        mmu_pkg::pte_t         pte;
        logic [LEVEL_BITS-1:0] level;
        logic                  error;
    } mshr_entry_t;

    mshr_entry_t [MSHR_SIZE-1:0] mshr_entries;

    // -------------------------------------------------------------------------
    // Deliver select (computed first: allocate.ready depends on deliver_fire)
    // -------------------------------------------------------------------------
    logic        [MSHR_SIZE-1:0] deliver_pending;
    for (genvar i = 0; i < MSHR_SIZE; i++) begin : g_deliver_pending
        assign deliver_pending[i] = (mshr_entries[i].state == ES_CLEAN_PENDING_DELIVER)
                                 || (mshr_entries[i].state == ES_DIRTY_PENDING_DELIVER);
    end

    logic [TAG_W-1:0] deliver_id;
    logic             deliver_some;
    VX_priority_encoder #(
        .N(MSHR_SIZE)
    ) deliver_sel (
        .data_in  (deliver_pending),
        .index_out(deliver_id),
        .valid_out(deliver_some),
        `UNUSED_PIN(onehot_out)
    );

    wire deliver_is_clean = (mshr_entries[deliver_id].state == ES_CLEAN_PENDING_DELIVER);
    wire deliver_poisoned = mshr_entries[deliver_id].dirty_poison;
    wire deliver_terminal = deliver_some && !(deliver_is_clean && deliver_poisoned);

    assign deliver_valid_o       = deliver_some;
    assign deliver_cores_o       = mshr_entries[deliver_id].pending_cores;
    assign deliver_pte_o         = mshr_entries[deliver_id].pte;
    assign deliver_level_o       = mshr_entries[deliver_id].level;
    assign deliver_error_o       = mshr_entries[deliver_id].error;
    assign deliver_vpn_o         = mshr_entries[deliver_id].vpn;
    assign deliver_asid_o        = mshr_entries[deliver_id].asid;
    assign deliver_write_cache_o = deliver_terminal && !mshr_entries[deliver_id].error;

    wire deliver_fire = deliver_valid_o && deliver_ready_i;

    // -------------------------------------------------------------------------
    // Issue select: first *_PENDING_ISSUE slot
    // -------------------------------------------------------------------------
    for (genvar i = 0; i < MSHR_SIZE; i++) begin : g_pending
        assign pending_entries_o[i] = (mshr_entries[i].state == ES_CLEAN_PENDING_ISSUE)
                                   || (mshr_entries[i].state == ES_DIRTY_PENDING_ISSUE);
    end

    logic [TAG_W-1:0] issue_id;
    logic             issue_valid;
    VX_priority_encoder #(
        .N(MSHR_SIZE)
    ) issue_sel (
        .data_in  (pending_entries_o),
        .index_out(issue_id),
        .valid_out(issue_valid),
        `UNUSED_PIN(onehot_out)
    );

    assign issue_valid_o = issue_valid;
    assign issue_id_o = issue_id;
    assign issue_vpn_o = mshr_entries[issue_id].vpn;
    assign issue_asid_o = mshr_entries[issue_id].asid;
    assign issue_set_dirty_o = (coalesce_fire && hit_found_id == issue_id)
                             ? coal_set_dirty_n
                             : mshr_entries[issue_id].set_dirty;

    wire issue_fire = issue_valid_o && issue_ready_i;

    // -------------------------------------------------------------------------
    // Fill (always accepted; the slot flop is free to take the result)
    // -------------------------------------------------------------------------
    wire fill_fire = fill_valid_i && fill_ready_o;
    assign fill_ready_o = 1'b1;

    // -------------------------------------------------------------------------
    // CAM: coalesce search (match any non-INVALID slot of the same VPN/ASID)
    // -------------------------------------------------------------------------
    logic             hit_found;
    logic [TAG_W-1:0] hit_found_id;

    always_comb begin : g_cam
        hit_found    = 1'b0;
        hit_found_id = '0;
        for (int i = 0; i < MSHR_SIZE; i++) begin
            if (!hit_found
                    && mshr_entries[i].state != ES_INVALID
                    && mshr_entries[i].vpn  == allocate_vpn_i
                    && mshr_entries[i].asid == allocate_asid_i) begin
                hit_found    = 1'b1;
                hit_found_id = TAG_W'(i);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Free-slot allocator
    // -------------------------------------------------------------------------
    logic mshr_full, mshr_empty;
    logic [TAG_W-1:0] alloc_id;
    `UNUSED_VAR(mshr_empty)

    // ready drops on any deliver snapshot so no CAM write races the snapshot.
    assign allocate_ready_o = (hit_found || !mshr_full) && !deliver_fire;

    wire alloc_handshake = allocate_valid_i && allocate_ready_o;
    wire coalesce_fire = alloc_handshake && hit_found;
    wire alloc_fire = alloc_handshake && !hit_found;  // ready => !mshr_full

    wire release_fire = deliver_fire && deliver_terminal;

    VX_allocator #(
        .SIZE(MSHR_SIZE)
    ) allocator (
        .clk         (clk_i),
        .reset       (rst_i),
        .acquire_en  (alloc_fire),
        .acquire_addr(alloc_id),
        .release_en  (release_fire),
        .release_addr(deliver_id),
        .empty       (mshr_empty),
        .full        (mshr_full)
    );

    // -------------------------------------------------------------------------
    // Coalesce routing (combinational next-fields for the hit slot)
    // -------------------------------------------------------------------------
    // Poison: a store the slot's clean walk cannot satisfy with a dirty PTE.
    wire poison_now = allocate_set_dirty_i
                   && (!mshr_entries[hit_found_id].set_dirty || mshr_entries[hit_found_id].dirty_poison)
                   && ((mshr_entries[hit_found_id].state == ES_CLEAN_PENDING_FILL)
                    || (mshr_entries[hit_found_id].state == ES_CLEAN_PENDING_DELIVER));

    logic [NUM_CORES-1:0] coal_pending_n, coal_dirty_n;
    logic coal_set_dirty_n, coal_poison_n;
    always_comb begin
        coal_pending_n   = mshr_entries[hit_found_id].pending_cores;
        coal_dirty_n     = mshr_entries[hit_found_id].dirty_cores;
        coal_set_dirty_n = mshr_entries[hit_found_id].set_dirty | allocate_set_dirty_i;
        coal_poison_n    = mshr_entries[hit_found_id].dirty_poison;
        if (poison_now) begin
            coal_dirty_n[allocate_core_id_i] = 1'b1;  // held until the dirty pass
            coal_poison_n                    = 1'b1;
        end else begin
            coal_pending_n[allocate_core_id_i] = 1'b1;  // delivered this pass
        end
    end

    // -------------------------------------------------------------------------
    // State updates.  Per-slot fields written here are disjoint across the
    // concurrent events that can target the SAME slot in a cycle:
    //   coalesce -> {pending_cores, dirty_cores, set_dirty, dirty_poison}
    //   reap     -> {state}            (slot was *_PENDING_ISSUE)
    //   fill     -> {state, pte,...}   (slot was *_PENDING_FILL)
    //   deliver  -> {state, ...}       (slot was *_PENDING_DELIVER)
    // coalesce never coincides with deliver (allocate.ready=0 on deliver_fire).
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int i = 0; i < MSHR_SIZE; i++) mshr_entries[i].state <= ES_INVALID;
        end else begin
            // Coalesce onto an existing slot
            if (coalesce_fire) begin
                mshr_entries[hit_found_id].pending_cores <= coal_pending_n;
                mshr_entries[hit_found_id].dirty_cores   <= coal_dirty_n;
                mshr_entries[hit_found_id].set_dirty     <= coal_set_dirty_n;
                mshr_entries[hit_found_id].dirty_poison  <= coal_poison_n;
            end

            // Allocate a fresh slot
            if (alloc_fire) begin
                mshr_entries[alloc_id].state        <= ES_CLEAN_PENDING_ISSUE;
                mshr_entries[alloc_id].vpn          <= allocate_vpn_i;
                mshr_entries[alloc_id].asid         <= allocate_asid_i;
                mshr_entries[alloc_id].set_dirty    <= allocate_set_dirty_i;
                mshr_entries[alloc_id].dirty_poison <= 1'b0;
                mshr_entries[alloc_id].dirty_cores  <= '0;
                for (int j = 0; j < NUM_CORES; j++)
                mshr_entries[alloc_id].pending_cores[j] <= (j == int'(allocate_core_id_i));
            end

            // Issue: PTW accepted the issued walk
            if (issue_fire) begin
                if (mshr_entries[issue_id].state == ES_CLEAN_PENDING_ISSUE)
                    mshr_entries[issue_id].state <= ES_CLEAN_PENDING_FILL;
                else mshr_entries[issue_id].state <= ES_DIRTY_PENDING_FILL;
            end

            // Fill: capture the walk result
            if (fill_fire) begin
                mshr_entries[fill_id_i].pte   <= fill_pte_i;
                mshr_entries[fill_id_i].level <= fill_level_i;
                // assert (!fill_error_i);
                if (fill_error_i) begin
                    $finish;
                end
                mshr_entries[fill_id_i].error <= fill_error_i;
                if (mshr_entries[fill_id_i].state == ES_CLEAN_PENDING_FILL)
                    mshr_entries[fill_id_i].state <= ES_CLEAN_PENDING_DELIVER;
                else mshr_entries[fill_id_i].state <= ES_DIRTY_PENDING_DELIVER;
            end

            // Deliver: snapshot taken by the engine; advance or free the slot
            if (deliver_fire) begin
                if (deliver_is_clean && deliver_poisoned) begin
                    // recirculate for the dirty pass
                    mshr_entries[deliver_id].state         <= ES_DIRTY_PENDING_ISSUE;
                    mshr_entries[deliver_id].pending_cores <= mshr_entries[deliver_id].dirty_cores;
                    mshr_entries[deliver_id].dirty_cores   <= '0;
                    mshr_entries[deliver_id].set_dirty     <= 1'b1;
                    mshr_entries[deliver_id].dirty_poison  <= 1'b0;
                end else begin
                    mshr_entries[deliver_id].state <= ES_INVALID;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------
`ifdef SIMULATION
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            if (fill_fire)
                assert (mshr_entries[fill_id_i].state == ES_CLEAN_PENDING_FILL
                     || mshr_entries[fill_id_i].state == ES_DIRTY_PENDING_FILL)
                else $fatal(1, "MSHR: fill of non-inflight slot %0d", fill_id_i);
            if (issue_fire)
                assert (issue_valid)
                else $fatal(1, "MSHR: reap with no pending issue");
            if (coalesce_fire)
                assert (!deliver_fire)
                else $fatal(1, "MSHR: coalesce raced a deliver snapshot");
            if (alloc_fire && release_fire)
                assert (alloc_id != deliver_id)
                else $fatal(1, "MSHR: alloc/free collision on slot %0d", alloc_id);
        end
    end
`endif

endmodule
