module eviction_policy
    import mmu_pkg::*;
#(
) (
    input logic clk_i,
    input logic rstn_i,

    // Hit Inputs
    input logic                    access_hit_i,
    input logic [TLB_IDX_SIZE-1:0] access_idx_i,

    // Write Inputs (mark freshly-written entries as recently used)
    input logic                    write_event_i,
    input logic [TLB_IDX_SIZE-1:0] write_idx_i,

    // Invalid Entry Inputs
    input logic                    tlb_has_invalid_entry_i,
    input logic [TLB_IDX_SIZE-1:0] tlb_invalid_entry_idx_i,

    // Eviction Decision Outputs
    output logic [TLB_IDX_SIZE-1:0] evict_idx_o

);

    logic [TLB_IDX_SIZE-1:0] plru_evict_idx;

    pseudoLRU #(
        .ENTRIES(TLB_ENTRIES)
    ) plru (
        .clk_i            (clk_i),
        .rstn_i           (rstn_i),
        .access_hit_i     (access_hit_i || write_event_i),
        .access_idx_i     (write_event_i ? write_idx_i : access_idx_i),
        .replacement_idx_o(plru_evict_idx)
    );

    assign evict_idx_o = tlb_has_invalid_entry_i ? tlb_invalid_entry_idx_i : plru_evict_idx;

endmodule
