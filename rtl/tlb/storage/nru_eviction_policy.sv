module nru_eviction_policy
    import mmu_pkg::*;
#(
    parameter int unsigned NUM_ENTRIES,
    parameter int unsigned NUM_HIT_PORTS,
    parameter int unsigned IDX_SIZE    = $clog2(NUM_ENTRIES)
) (
    input logic clk_i,
    input logic rstn_i,

    // Hit Inputs (one per CAM read port; an entry is "used" when any port hits it)
    input logic                access_hit_i[NUM_HIT_PORTS],
    input logic [IDX_SIZE-1:0] access_idx_i[NUM_HIT_PORTS],

    // Write Inputs (a freshly-filled entry counts as recently used)
    input logic                write_event_i,
    input logic [IDX_SIZE-1:0] write_idx_i,

    // Invalid Entry Inputs (prefer filling an empty slot before evicting)
    input logic                tlb_has_invalid_entry_i,
    input logic [IDX_SIZE-1:0] tlb_invalid_entry_idx_i,

    // Eviction Decision Outputs
    output logic [IDX_SIZE-1:0] evict_idx_o
);

    // -------------------------------------------------------------------------
    // NRU (Not-Recently-Used) reference bits
    // -------------------------------------------------------------------------
    // One reference bit per entry. A bit is set when the entry is accessed
    // (any CAM port hits it) or freshly filled. Because the per-port accesses
    // are OR-ed into a mask, multiple simultaneous hits to distinct entries in
    // a single cycle compose trivially
    //
    // When every reference bit would become set, the bits are cleared back to
    // just this cycle's accesses (a second-chance sweep), so there is always an
    // unreferenced victim candidate.

    logic [NUM_ENTRIES-1:0] used_q;

    // Hits this cycle (no fill). Used both to update reference bits and to
    // protect an entry being actively translated from eviction in the same
    // cycle. Deliberately excludes the fill index so evict_idx_o does not
    // depend on write_idx_i (which is wired back from evict_idx_o externally).
    logic [NUM_ENTRIES-1:0] hit_mask;
    always_comb begin
        hit_mask = '0;
        for (int unsigned p = 0; p < NUM_HIT_PORTS; p++) begin
            if (access_hit_i[p]) begin
                hit_mask[access_idx_i[p]] = 1'b1;
            end
        end
    end

    // Full access mask for the reference-bit update: hits plus the fill.
    logic [NUM_ENTRIES-1:0] access_mask;
    always_comb begin
        access_mask = hit_mask;
        if (write_event_i) begin
            access_mask[write_idx_i] = 1'b1;
        end
    end

    // Reference-bit next state with saturation sweep.
    logic [NUM_ENTRIES-1:0] used_pre, used_d;
    always_comb begin
        used_pre = used_q | access_mask;
        // if every bit would be set, reset to only this cycle's accesses
        used_d   = (&used_pre) ? access_mask : used_pre;
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            used_q <= '0;
        end else begin
            used_q <= used_d;
        end
    end

    // -------------------------------------------------------------------------
    // Victim selection: invalid entry first, else first not-recently-used entry
    // -------------------------------------------------------------------------
    // Protect entries hit this cycle (used_q | hit_mask) so we never evict a
    // translation another port is actively using.
    logic [NUM_ENTRIES-1:0] used_eff;
    assign used_eff = used_q | hit_mask;

    logic [IDX_SIZE-1:0] nru_victim;
    logic                found;
    always_comb begin
        nru_victim = '0;  // all-used fallback (rare): evict entry 0
        found      = 1'b0;
        for (int unsigned i = 0; i < NUM_ENTRIES; i++) begin
            if (!found && !used_eff[i]) begin
                nru_victim = IDX_SIZE'(i);
                found      = 1'b1;
            end
        end
    end

    assign evict_idx_o = tlb_has_invalid_entry_i ? tlb_invalid_entry_idx_i : nru_victim;

endmodule
