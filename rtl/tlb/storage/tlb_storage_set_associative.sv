`IGNORE_WARNINGS_BEGIN
/* verilator lint_off VARHIDDEN */

// Set-associative TLB storage.
//  - Read : combinational priority lookup in the VPN-indexed set.
//  - Write: update-in-place if the VPN is already resident (preserves the one-
//           entry-per-VPN invariant the MSHR relies on), else fill an invalid
//           way, else evict the LRU way.
//  - Clear: flush (invalidate every entry).
// Ready/valid exclusivity: clear > write > read.  Exact LRU via a per-way rank
// permutation (0 = LRU, NUM_TLB_WAYS-1 = MRU).
module tlb_storage_set_associative
    import mmu_pkg::*;
#(
    parameter int unsigned ASID_SIZE    = mmu_pkg::ASID_SIZE,
    parameter int unsigned VPN_SIZE     = mmu_pkg::VPN_SIZE,
    parameter int unsigned LEVEL_SIZE   = mmu_pkg::LEVEL_BITS,
    // Set-associative
    parameter int unsigned NUM_TLB_SETS = 128,
    parameter int unsigned NUM_TLB_WAYS = 8,
    // Set-associative: hard to calculate set ID if we have multiple levels
    // better to use one set-assoc array per level
    parameter int unsigned TLB_LEVEL = 0
) (
    input logic clk_i,
    input logic rstn_i,

    // Read (combinational lookup)
    input  logic                  read_valid_i,
    output logic                  read_ready_o,
    output logic                  read_is_hit_o,
    input  logic [ ASID_SIZE-1:0] read_asid_i,
    input  logic [  VPN_SIZE-1:0] read_vpn_i,
    output logic [LEVEL_SIZE-1:0] read_level_o,
    output tlb_entry_t            read_entry_o,

    // Write
    input  logic                  write_valid_i,
    output logic                  write_ready_o,
    input  logic [  VPN_SIZE-1:0] write_vpn_i,
    input  logic [ ASID_SIZE-1:0] write_asid_i,
    input  tlb_entry_t            write_entry_i,

    // Clear (flush all valid entries)
    input  logic                  clear_valid_i,
    output logic                  clear_ready_o
);

    localparam int unsigned SET_IDX_W = (NUM_TLB_SETS > 1) ? $clog2(NUM_TLB_SETS) : 1;
    localparam int unsigned WAY_IDX_W = (NUM_TLB_WAYS > 1) ? $clog2(NUM_TLB_WAYS) : 1;
    localparam int unsigned RANK_W    = (NUM_TLB_WAYS > 1) ? $clog2(NUM_TLB_WAYS) : 1;
    localparam logic [RANK_W-1:0] RANK_MRU = RANK_W'(NUM_TLB_WAYS - 1);

    typedef struct packed {
        tlb_entry_t [NUM_TLB_WAYS-1:0]             entries;
        logic       [NUM_TLB_WAYS-1:0][RANK_W-1:0] rank;  // exact-LRU recency, 0 = LRU
    } tlb_set_t;
    tlb_set_t tlb_sets[NUM_TLB_SETS];

    // Ready/valid exclusivity: clear > write > read
    assign clear_ready_o = 1'b1;
    assign write_ready_o = !clear_valid_i;
    assign read_ready_o  = !clear_valid_i && !write_valid_i;
    wire read_fire  = read_valid_i  && read_ready_o;
    wire write_fire = write_valid_i && write_ready_o;
    wire clear_fire = clear_valid_i && clear_ready_o;

    // Low VPN bits -> set index (page-adjacent pages scatter across sets).
    function automatic logic [SET_IDX_W-1:0] set_idx(input logic [VPN_SIZE-1:0] vpn);
        return vpn[SET_IDX_W-1:0];
    endfunction

    // -------------------------------------------------------------------------
    // Read
    // -------------------------------------------------------------------------
    wire [SET_IDX_W-1:0]  read_set = set_idx(read_vpn_i);
    logic                 is_hit;
    logic [WAY_IDX_W-1:0] hit_way;
    always_comb begin
        is_hit  = 1'b0;
        hit_way = '0;
        for (int w = 0; w < NUM_TLB_WAYS; w++) begin
            if (!is_hit
                    && tlb_sets[read_set].entries[w].valid
                    && tlb_sets[read_set].entries[w].vpn  == read_vpn_i
                    && tlb_sets[read_set].entries[w].asid == read_asid_i) begin
                is_hit  = 1'b1;
                hit_way = WAY_IDX_W'(w);
            end
        end
    end
    assign read_is_hit_o = is_hit;
    assign read_entry_o  = tlb_sets[read_set].entries[hit_way];
    // TODO: remove level field (saves HW budget)
    assign read_level_o  = tlb_sets[read_set].entries[hit_way].level;

    // -------------------------------------------------------------------------
    // Write target
    // -------------------------------------------------------------------------
    wire [SET_IDX_W-1:0]  write_set = set_idx(write_vpn_i);
    logic                 match_hit;
    logic [WAY_IDX_W-1:0] match_way;
    logic                 inv_hit;
    logic [WAY_IDX_W-1:0] inv_way;
    logic [WAY_IDX_W-1:0] lru_way;
    always_comb begin
        match_hit = 1'b0;
        match_way = '0;
        inv_hit   = 1'b0;
        inv_way   = '0;
        lru_way   = '0;
        for (int w = 0; w < NUM_TLB_WAYS; w++) begin
            if (!match_hit
                    && tlb_sets[write_set].entries[w].valid
                    && tlb_sets[write_set].entries[w].vpn  == write_vpn_i
                    && tlb_sets[write_set].entries[w].asid == write_asid_i) begin
                match_hit = 1'b1;
                match_way = WAY_IDX_W'(w);
            end
            if (!inv_hit && !tlb_sets[write_set].entries[w].valid) begin
                inv_hit = 1'b1;
                inv_way = WAY_IDX_W'(w);
            end
            if (tlb_sets[write_set].rank[w] == '0) begin
                lru_way = WAY_IDX_W'(w);
            end
        end
    end
    wire [WAY_IDX_W-1:0] write_way = match_hit ? match_way : (inv_hit ? inv_way : lru_way);

    // -------------------------------------------------------------------------
    // LRU recency update: (read-hit or write - mutually exclusive).
    // -------------------------------------------------------------------------
    wire                  access_fire = (read_fire && is_hit) || write_fire;
    wire [SET_IDX_W-1:0]  access_set  = write_fire ? write_set : read_set;
    wire [WAY_IDX_W-1:0]  access_way  = write_fire ? write_way : hit_way;
    wire [   RANK_W-1:0]  old_rank    = tlb_sets[access_set].rank[access_way];

    logic [NUM_TLB_WAYS-1:0][RANK_W-1:0] rank_n;
    always_comb begin
        for (int w = 0; w < NUM_TLB_WAYS; w++) begin
            if (WAY_IDX_W'(w) == access_way)
                rank_n[w] = RANK_MRU;
            else if (tlb_sets[access_set].rank[w] > old_rank)
                rank_n[w] = tlb_sets[access_set].rank[w] - 1'b1;
            else
                rank_n[w] = tlb_sets[access_set].rank[w];
        end
    end

    // -------------------------------------------------------------------------
    // State (clear/write are mutually exclusive)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            for (int s = 0; s < NUM_TLB_SETS; s++) begin
                for (int w = 0; w < NUM_TLB_WAYS; w++) begin
                    tlb_sets[s].entries[w] <= '0;          // valid = 0
                    tlb_sets[s].rank[w]    <= RANK_W'(w);  // distinct ranks 0..WAYS-1
                end
            end
        end else begin
            if (clear_fire) begin
                for (int s = 0; s < NUM_TLB_SETS; s++)
                    for (int w = 0; w < NUM_TLB_WAYS; w++)
                        tlb_sets[s].entries[w].valid <= 1'b0;
            end
            if (write_fire) begin
                tlb_sets[write_set].entries[write_way] <= write_entry_i;
            end
            if (access_fire) begin
                tlb_sets[access_set].rank <= rank_n;
            end
        end
    end

endmodule

`IGNORE_WARNINGS_END
