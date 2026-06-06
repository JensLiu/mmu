
module tlb_storage_parallel_cam #(
    localparam int unsigned NUM_LEVELS      = mmu_pkg::LEVELS,
    localparam int unsigned LEVEL_W         = mmu_pkg::LEVEL_BITS,
    localparam int unsigned ASID_W          = mmu_pkg::ASID_SIZE,
    localparam int unsigned VPN_W           = mmu_pkg::VPN_SIZE,
    localparam int unsigned VPN_W_PER_LVL   = mmu_pkg::PAGE_LVL_BITS,
    parameter  int unsigned NUM_READ_PORTS  = 1,
    parameter  int unsigned NUM_TLB_ENTRIES = 16
) (
    input logic clk_i,
    input logic rstn_i,

    // Read (combinational lookup)
    input  logic                              read_valid_i [NUM_READ_PORTS],
    output logic                              read_ready_o [NUM_READ_PORTS],
    output logic                              read_is_hit_o[NUM_READ_PORTS],
    input  logic                [ ASID_W-1:0] read_asid_i  [NUM_READ_PORTS],
    input  logic                [  VPN_W-1:0] read_vpn_i   [NUM_READ_PORTS],
    output logic                [LEVEL_W-1:0] read_level_o [NUM_READ_PORTS],
    output mmu_pkg::tlb_entry_t               read_entry_o [NUM_READ_PORTS],

    // Write
    input  logic                             write_valid_i,
    output logic                             write_ready_o,
    input  logic                [ VPN_W-1:0] write_vpn_i,
    input  logic                [ASID_W-1:0] write_asid_i,
    input  mmu_pkg::tlb_entry_t              write_entry_i,

    // Clear (flush all valid entries)
    input  logic clear_valid_i,
    output logic clear_ready_o
);
    localparam int unsigned TLB_IDX_W = $clog2(NUM_TLB_ENTRIES);
    // Recency rank: read ports get ranks 0..NUM_READ_PORTS-1, a concurrent
    // write (fill) gets the highest rank NUM_READ_PORTS so a freshly installed
    // entry is treated as the most-recently-used.
    localparam int unsigned RANK_W = $clog2(NUM_READ_PORTS + 1) + 1;

    mmu_pkg::tlb_entry_t [NUM_TLB_ENTRIES-1:0] tlb_entries;

    // Reference-matrix exact LRU: lru_matrix[i][j] == 1 means entry i is more
    // recently used than entry j. On an access to entry a, row a is set to all
    // 1s and column a to all 0s; the LRU victim is the entry whose row is all
    // zero. This structure is multiport-friendly: several simultaneous hits are
    // merged combinationally, with port index used to break the recency tie.
    logic [NUM_TLB_ENTRIES-1:0] lru_matrix [NUM_TLB_ENTRIES];

    for (genvar i = 0; i < NUM_READ_PORTS; i++) begin : g_read_valid
        assign read_ready_o[i] = !write_valid_i && !clear_valid_i;
    end
    // The write (a fill) is fire-and-forget: always consumed, never deferred.
    // If clear and write fire together, clear wins and the write is silently
    // dropped (see the write FF below) rather than held — a deferred refill
    // would install a stale translation once the page tables have changed.
    assign write_ready_o = 1'b1;
    assign clear_ready_o = '1;

    // -------------------------------------------------------------------------
    // Parallel CAM hit logic
    // --------------------------------------------------------
    // We run the per-level CAM compare over NUM_READ_PORTS + 1 query ports.
    // Ports 0..NUM_READ_PORTS-1 are the external read ports; the extra port
    // WR_PROBE presents the incoming write VPN/ASID so the write path can find
    // an already-resident copy of the translation and overwrite it in place
    // (de-dup / clean->dirty upgrade), reusing this exact same compare logic.
    localparam int unsigned NUM_QUERY = NUM_READ_PORTS + 1;
    localparam int unsigned WR_PROBE  = NUM_READ_PORTS;

    logic [        VPN_W-1:0]   q_vpn          [NUM_QUERY];
    logic [       ASID_W-1:0]   q_asid         [NUM_QUERY];
    logic [NUM_TLB_ENTRIES-1:0] q_entry_hit_lvl[NUM_QUERY][NUM_LEVELS];
    logic [NUM_TLB_ENTRIES-1:0] q_entry_hit    [NUM_QUERY];
    logic                       q_hit          [NUM_QUERY];
    logic [    TLB_IDX_W-1:0]   q_hit_idx      [NUM_QUERY];

    for (genvar p = 0; p < NUM_READ_PORTS; p++) begin : g_read_query
        assign q_vpn[p]  = read_vpn_i[p];
        assign q_asid[p] = read_asid_i[p];
    end
    assign q_vpn[WR_PROBE]  = write_vpn_i;
    assign q_asid[WR_PROBE] = write_asid_i;

    for (genvar p = 0; p < NUM_QUERY; p++) begin : g_query_cam
        // Per-level hit vectors indexed by PTW level (0 = largest page).
        // For PTW level l, compare the top (l+1)*PAGE_LVL_BITS bits of the VPN:
        //   SV39 (LEVELS=3, PAGE_LVL_BITS=9): l=0 -> vpn[26:18], l=1 -> vpn[26:9], l=2 -> vpn[26:0]
        //   SV32 (LEVELS=2, PAGE_LVL_BITS=10): l=0 -> vpn[19:10], l=1 -> vpn[19:0]
        for (genvar lvl = 0; lvl < NUM_LEVELS; lvl++) begin : g_per_lvl_cam
            localparam int VPN_CMP_W = (lvl + 1) * VPN_W_PER_LVL;
            always_comb begin
                for (int i = 0; i < NUM_TLB_ENTRIES; i++) begin
                    q_entry_hit_lvl[p][lvl][i] = (
                        (tlb_entries[i].vpn[VPN_W-1 -: VPN_CMP_W] == q_vpn[p][VPN_W-1 -: VPN_CMP_W])
                        && (tlb_entries[i].asid == q_asid[p])
                        && tlb_entries[i].valid
                        && (tlb_entries[i].level == 2'(lvl))
                    ) ? 1'b1 : 1'b0;
                end
            end
        end

        // OR the per-level vectors (each entry is tagged with exactly one level).
        always_comb begin
            q_entry_hit[p] = '0;
            for (int l = 0; l < NUM_LEVELS; l++) q_entry_hit[p] |= q_entry_hit_lvl[p][l];
        end
        assign q_hit[p] = |q_entry_hit[p];

        // Encode the first matching index.
        logic found;
        always_comb begin
            q_hit_idx[p] = '0;
            found        = 1'b0;
            for (int i = 0; !found && i < NUM_TLB_ENTRIES; i++) begin
                if (q_entry_hit[p][i]) begin
                    q_hit_idx[p] = TLB_IDX_W'(i);
                    found        = 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Read Response Logic (real read ports only)
    // -------------------------------------------------------------------------
    for (genvar p = 0; p < NUM_READ_PORTS; p++) begin : g_read_resp
        assign read_is_hit_o[p] = q_hit[p];
        assign read_entry_o[p]  = tlb_entries[q_hit_idx[p]];

        // Select the matching level (largest index wins; an entry matches at
        // exactly one level, so at most one per-level vector is non-zero).
        logic [LEVEL_W-1:0] hit_lvl_sel;
        always_comb begin
            hit_lvl_sel = '0;
            for (int hl = NUM_LEVELS - 1; hl >= 0; hl--) begin
                if (|q_entry_hit_lvl[p][hl]) hit_lvl_sel = LEVEL_W'(hl);
            end
        end
        assign read_level_o[p] = hit_lvl_sel;
    end

    // -------------------------------------------------------------------------
    // Victim Selection
    //   1. If the write translation is already resident (same VPN/ASID at the
    //      write entry's level), overwrite that slot in place. This de-dups and
    //      performs the clean->dirty upgrade without leaving a stale copy.
    //   2. else the first invalid (free) slot.
    //   3. else the LRU entry (matrix row all zero).
    // -------------------------------------------------------------------------
    logic [NUM_TLB_ENTRIES-1:0] valid_vec;
    for (genvar i = 0; i < NUM_TLB_ENTRIES; i++) begin : g_valid_vec
        assign valid_vec[i] = tlb_entries[i].valid;
    end

    // Existing copy of the incoming write, matched at the write entry's level
    // (so we never clobber a coarser superpage that merely shares top VPN bits).
    logic [NUM_TLB_ENTRIES-1:0] write_match_vec;
    always_comb begin
        write_match_vec = '0;
        for (int l = 0; l < NUM_LEVELS; l++) begin
            if (write_entry_i.level == 2'(l)) write_match_vec = q_entry_hit_lvl[WR_PROBE][l];
        end
    end
    wire write_match = |write_match_vec;

    logic [TLB_IDX_W-1:0]       victim_idx;
    logic [NUM_TLB_ENTRIES-1:0] victim_onehot;
    always_comb begin
        logic found;
        victim_idx = '0;
        found      = 1'b0;
        if (write_match) begin
            // Overwrite the resident copy in place.
            for (int i = 0; !found && i < NUM_TLB_ENTRIES; i++) begin
                if (write_match_vec[i]) begin
                    victim_idx = TLB_IDX_W'(i);
                    found      = 1'b1;
                end
            end
        end else if (|(~valid_vec)) begin
            // First invalid (free) slot.
            for (int i = 0; !found && i < NUM_TLB_ENTRIES; i++) begin
                if (!valid_vec[i]) begin
                    victim_idx = TLB_IDX_W'(i);
                    found      = 1'b1;
                end
            end
        end else begin
            // No free slot: evict the LRU entry, i.e. the one not more recent
            // than any other (its matrix row is all zero). The diagonal is held
            // at 0, so a plain row-is-zero test is sufficient.
            for (int i = 0; !found && i < NUM_TLB_ENTRIES; i++) begin
                if (lru_matrix[i] == '0) begin
                    victim_idx = TLB_IDX_W'(i);
                    found      = 1'b1;
                end
            end
        end
    end
    always_comb begin
        victim_onehot              = '0;
        victim_onehot[victim_idx]  = 1'b1;
    end

    // -------------------------------------------------------------------------
    // Replacement Policy Update (reference-matrix exact LRU)
    // -------------------------------------------------------------------------
    // Per-cycle access set. Reads and writes are mutually exclusive (a read is
    // only handshaken when read_ready_o is high, which excludes write/clear
    // cycles), so the access set comes from either the read ports or the fill,
    // never both at once. Each entry records the rank of the accessing port to
    // break the recency tie when two entries are accessed in the same cycle.
    logic              accessed [NUM_TLB_ENTRIES];
    logic [RANK_W-1:0] acc_rank [NUM_TLB_ENTRIES];

    // Only real read ports drive the LRU; the WR_PROBE query is excluded (it is
    // a de-dup lookup, not an access). The fill marks its slot MRU below.
    logic [NUM_TLB_ENTRIES-1:0] port_access [NUM_READ_PORTS];
    for (genvar p = 0; p < NUM_READ_PORTS; p++) begin : g_port_access
        assign port_access[p] =
            (read_valid_i[p] && read_ready_o[p]) ? q_entry_hit[p]
                                                 : '0;
    end

    always_comb begin
        for (int i = 0; i < NUM_TLB_ENTRIES; i++) begin
            accessed[i] = 1'b0;
            acc_rank[i] = '0;
            // Highest-priority read port that hit this entry wins the rank.
            for (int p = 0; p < NUM_READ_PORTS; p++) begin
                if (port_access[p][i]) begin
                    accessed[i] = 1'b1;
                    acc_rank[i] = RANK_W'(p);
                end
            end
            // A fill targets the victim slot and is the most recent of all.
            if (write_valid_i && write_ready_o && victim_onehot[i]) begin
                accessed[i] = 1'b1;
                acc_rank[i] = RANK_W'(NUM_READ_PORTS);
            end
        end
    end

    logic [NUM_TLB_ENTRIES-1:0] lru_matrix_n [NUM_TLB_ENTRIES];
    always_comb begin
        for (int i = 0; i < NUM_TLB_ENTRIES; i++) begin
            for (int j = 0; j < NUM_TLB_ENTRIES; j++) begin
                if (i == j) begin
                    lru_matrix_n[i][j] = 1'b0;  // hold diagonal at 0
                end else if (accessed[i] && !accessed[j]) begin
                    lru_matrix_n[i][j] = 1'b1;  // i now more recent than j
                end else if (!accessed[i] && accessed[j]) begin
                    lru_matrix_n[i][j] = 1'b0;  // j now more recent than i
                end else if (accessed[i] && accessed[j]) begin
                    lru_matrix_n[i][j] = (acc_rank[i] > acc_rank[j]);
                end else begin
                    lru_matrix_n[i][j] = lru_matrix[i][j];  // unchanged
                end
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i || clear_valid_i) begin
            for (int i = 0; i < NUM_TLB_ENTRIES; i++) lru_matrix[i] <= '0;
        end else begin
            for (int i = 0; i < NUM_TLB_ENTRIES; i++) lru_matrix[i] <= lru_matrix_n[i];
        end
    end

    // -------------------------------------------------------------------------
    // Write Logic
    // -------------------------------------------------------------------------
    mmu_pkg::tlb_entry_t write_entry;
    always_comb begin
        write_entry       = write_entry_i;
        write_entry.vpn   = write_vpn_i;
        write_entry.asid  = write_asid_i;
        write_entry.valid = 1'b1;
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            for (int i = 0; i < NUM_TLB_ENTRIES; i++) tlb_entries[i] <= '0;
        end else if (clear_valid_i) begin
            // Flush all valid entries. clear wins over a coincident write: the
            // write is dropped (not deferred), since it would be stale.
            for (int i = 0; i < NUM_TLB_ENTRIES; i++) tlb_entries[i] <= '0;
        end else if (write_valid_i) begin
            tlb_entries[victim_idx] <= write_entry;
        end
    end

endmodule

