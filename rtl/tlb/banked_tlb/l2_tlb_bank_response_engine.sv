// -----------------------------------------------------------------------------
// MSHR response engine: a single-buffered, N-destination broadcast serializer.
//
// Two valid/ready load sources feed one held group (mask + payload); the engine
// drains the group one core per cycle onto the bank response port.
//   - mshr_deliver : a whole coalesced set of cores in ONE handshake (priority)
//   - tlb_hit      : a single core (a direct store/cache hit)
//
// The engine is payload-opaque: both sources hand it a fully-formed
// l2_l1_rsp_data_t, so it never touches PTEs or the cache.  The hit's back-
// pressure is just its `ready` - the bank forwards tlb_hit_ready_o to its own
// req_ready_o, so request acceptance is a clean handshake, not a side effect.
//
// Deliver has strict priority: its ready is asserted whenever the engine is
// free; the hit's ready additionally requires that no deliver is offered.
// -----------------------------------------------------------------------------

module l2_tlb_bank_response_engine
    import mmu_pkg::*;
#(
    parameter  int unsigned NUM_CORES = 32,
    localparam int unsigned CORE_ID_W = (NUM_CORES > 1) ? $clog2(NUM_CORES) : 1
) (
    input logic clk_i,
    input logic rst_i,

    // MSHR deliver (slave): a coalesced core set + payload, taken in one fire.
    input  logic                                         mshr_deliver_valid_i,
    output logic                                         mshr_deliver_ready_o,
    input  logic                         [NUM_CORES-1:0] mshr_deliver_cores_i,
    input  mmu_pkg::inter_tlb_rsp_data_t                 mshr_deliver_rsp_i,

    // TLB hit (slave): a single core + payload.
    input  logic                                         tlb_hit_valid_i,
    output logic                                         tlb_hit_ready_o,
    input  logic                         [CORE_ID_W-1:0] tlb_hit_core_i,
    input  mmu_pkg::inter_tlb_rsp_data_t                 tlb_hit_rsp_i,

    // Bank response (master): one core / cycle.
    output logic                                         rsp_valid_o,
    input  logic                                         rsp_ready_i,
    output mmu_pkg::inter_tlb_rsp_data_t                 rsp_data_o,
    output logic                         [CORE_ID_W-1:0] rsp_src_o
);

    // -------------------------------------------------------------------------
    // Held group (single-buffered)
    // -------------------------------------------------------------------------
    logic                         [NUM_CORES-1:0] mask;  // cores still owed a response
    mmu_pkg::inter_tlb_rsp_data_t                 data;  // payload broadcast to all of them

    // -------------------------------------------------------------------------
    // Pick the lowest pending core
    // -------------------------------------------------------------------------
    logic                         [CORE_ID_W-1:0] pick_idx;
    logic                         [NUM_CORES-1:0] pick_oh;
    always_comb begin
        pick_idx = '0;
        pick_oh  = '0;
        for (int i = 0; i < NUM_CORES; i++) begin
            if (mask[i] && (pick_oh == '0)) begin
                pick_idx   = CORE_ID_W'(i);
                pick_oh[i] = 1'b1;
            end
        end
    end

    assign rsp_valid_o = (mask != '0);  // never depends on rsp_ready_i
    assign rsp_data_o  = data;
    assign rsp_src_o   = pick_idx;

    // -------------------------------------------------------------------------
    // Drain bookkeeping
    // -------------------------------------------------------------------------
    wire                 rsp_fire = rsp_valid_o && rsp_ready_i;
    wire [NUM_CORES-1:0] mask_after = mask & ~(rsp_fire ? pick_oh : '0);
    wire                 free_next = (mask_after == '0);  // empty next cycle -> loadable now

    // -------------------------------------------------------------------------
    // Load arbitration (deliver > hit).  A ready never depends on its OWN valid.
    // -------------------------------------------------------------------------
    assign mshr_deliver_ready_o = free_next;
    assign tlb_hit_ready_o      = free_next && !mshr_deliver_valid_i;

    wire                 load_deliver = mshr_deliver_ready_o && mshr_deliver_valid_i;
    wire                 load_hit = tlb_hit_ready_o && tlb_hit_valid_i;

    wire [NUM_CORES-1:0] hit_oh = (NUM_CORES'(1) << tlb_hit_core_i);

    // -------------------------------------------------------------------------
    // Load / drain.  Load happens on the same cycle the last core drains, so
    // back-to-back groups have no bubble; data is stable while draining.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            mask <= '0;
        end else if (free_next) begin
            if (load_deliver) begin
                mask <= mshr_deliver_cores_i;
                data <= mshr_deliver_rsp_i;
            end else if (load_hit) begin
                mask <= hit_oh;
                data <= tlb_hit_rsp_i;
            end else begin
                mask <= '0;
            end
        end else begin
            mask <= mask_after;
        end
    end

endmodule
