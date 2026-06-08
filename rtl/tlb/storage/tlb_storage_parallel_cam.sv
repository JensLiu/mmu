/*
 * Copyright 2025 BSC*
 * *Barcelona Supercomputing Center (BSC)
 *
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Licensed under the Solderpad Hardware License v 2.1 (the "License"); you
 * may not use this file except in compliance with the License, or, at your
 * option, the Apache License version 2.0. You may obtain a copy of the
 * License at
 *
 * https://solderpad.org/licenses/SHL-2.1/
 *
 * Unless required by applicable law or agreed to in writing, any work
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 */

// Multiport parallel-CAM TLB storage with reference-matrix exact LRU.
module tlb_storage_parallel_cam #(
    localparam int unsigned NUM_LEVELS       = mmu_pkg::LEVELS,
    localparam int unsigned LEVEL_BITS       = mmu_pkg::LEVEL_BITS,
    localparam int unsigned ASID_WIDTH       = mmu_pkg::ASID_WIDTH,
    localparam int unsigned VPN_WIDTH        = mmu_pkg::VPN_WIDTH,
    localparam int unsigned VPN_PER_LVL_BITS = mmu_pkg::PAGE_LVL_BITS,
    parameter  int unsigned NUM_READ_PORTS   = 1,
    parameter  int unsigned NUM_TLB_ENTRIES  = 16
) (
    input logic clk_i,
    input logic rst_i,

    // Read (combinational lookup)
    input  logic                              read_valid_i [NUM_READ_PORTS],
    output logic                              read_ready_o [NUM_READ_PORTS],
    output logic                              read_is_hit_o[NUM_READ_PORTS],
    input  logic                [ASID_WIDTH-1:0] read_asid_i [NUM_READ_PORTS],
    input  logic                [ VPN_WIDTH-1:0] read_vpn_i  [NUM_READ_PORTS],
    output logic                [LEVEL_BITS-1:0] read_level_o[NUM_READ_PORTS],
    output mmu_pkg::tlb_entry_t               read_entry_o [NUM_READ_PORTS],

    // Write
    input  logic                  write_valid_i,
    output logic                  write_ready_o,
    input  logic [ VPN_WIDTH-1:0] write_vpn_i,
    input  logic [ASID_WIDTH-1:0] write_asid_i,
    input  mmu_pkg::tlb_entry_t   write_entry_i,

    // Clear (flush all valid entries)
    input  logic clear_valid_i,
    output logic clear_ready_o
);
    localparam int unsigned TLB_IDX_BITS = $clog2(NUM_TLB_ENTRIES);
    // recency rank: read ports 0..N-1, a concurrent fill gets the top rank (MRU)
    localparam int unsigned RANK_BITS = $clog2(NUM_READ_PORTS + 1) + 1;

    mmu_pkg::tlb_entry_t [NUM_TLB_ENTRIES-1:0] tlb_entries;

    // reference-matrix exact LRU: lru_matrix[i][j]=1 means i more-recent than j.
    // Access a => set row a, clear column a; victim = the all-zero row.
    logic [NUM_TLB_ENTRIES-1:0] lru_matrix [NUM_TLB_ENTRIES];

    for (genvar i = 0; i < NUM_READ_PORTS; i++) begin : g_read_valid
        assign read_ready_o[i] = !write_valid_i && !clear_valid_i;
    end
    // fill is fire-and-forget; a write coincident with clear is dropped (clear
    // wins), never deferred (a deferred refill would be stale).
    assign write_ready_o = 1'b1;
    assign clear_ready_o = '1;

    // ---------------------------------------------------------
    // Parallel CAM hit logic
    // ---------------------------------------------------------
    // Compare over NUM_READ_PORTS + 1 query ports; the extra WR_PROBE port carries
    // the write VPN/ASID so the write path can find a resident copy to overwrite.
    localparam int unsigned NUM_QUERY = NUM_READ_PORTS + 1;
    localparam int unsigned WR_PROBE  = NUM_READ_PORTS;

    logic [       VPN_WIDTH-1:0] q_vpn          [NUM_QUERY];
    logic [      ASID_WIDTH-1:0] q_asid         [NUM_QUERY];
    logic [NUM_TLB_ENTRIES-1:0]  q_entry_hit_lvl[NUM_QUERY][NUM_LEVELS];
    logic [NUM_TLB_ENTRIES-1:0]  q_entry_hit    [NUM_QUERY];
    logic                        q_hit          [NUM_QUERY];
    logic [    TLB_IDX_BITS-1:0] q_hit_idx      [NUM_QUERY];

    for (genvar p = 0; p < NUM_READ_PORTS; p++) begin : g_read_query
        assign q_vpn[p]  = read_vpn_i[p];
        assign q_asid[p] = read_asid_i[p];
    end
    assign q_vpn[WR_PROBE]  = write_vpn_i;
    assign q_asid[WR_PROBE] = write_asid_i;

    for (genvar p = 0; p < NUM_QUERY; p++) begin : g_query_cam
        // level l (0 = largest page) compares the top (l+1)*PAGE_LVL_BITS VPN bits
        for (genvar lvl = 0; lvl < NUM_LEVELS; lvl++) begin : g_per_lvl_cam
            localparam int VPN_CMP_WIDTH = (lvl + 1) * VPN_PER_LVL_BITS;
            always_comb begin
                for (int i = 0; i < NUM_TLB_ENTRIES; i++) begin
                    q_entry_hit_lvl[p][lvl][i] = (
                        (tlb_entries[i].vpn[VPN_WIDTH-1 -: VPN_CMP_WIDTH] == q_vpn[p][VPN_WIDTH-1 -: VPN_CMP_WIDTH])
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
                    q_hit_idx[p] = TLB_IDX_BITS'(i);
                    found        = 1'b1;
                end
            end
        end
    end

    // ---------------------------------------------------------
    // Read response (real read ports only)
    // ---------------------------------------------------------
    for (genvar p = 0; p < NUM_READ_PORTS; p++) begin : g_read_rsp
        assign read_is_hit_o[p] = q_hit[p];
        assign read_entry_o[p]  = tlb_entries[q_hit_idx[p]];

        // Select the matching level (largest index wins; an entry matches at
        // exactly one level, so at most one per-level vector is non-zero).
        logic [LEVEL_BITS-1:0] hit_lvl_sel;
        always_comb begin
            hit_lvl_sel = '0;
            for (int hl = NUM_LEVELS - 1; hl >= 0; hl--) begin
                if (|q_entry_hit_lvl[p][hl]) hit_lvl_sel = LEVEL_BITS'(hl);
            end
        end
        assign read_level_o[p] = hit_lvl_sel;
    end

    // ---------------------------------------------------------
    // Victim selection: resident match (de-dup) -> free slot -> LRU row
    // ---------------------------------------------------------
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

    logic [TLB_IDX_BITS-1:0]    victim_idx;
    logic [NUM_TLB_ENTRIES-1:0] victim_onehot;
    always_comb begin
        logic found;
        victim_idx = '0;
        found      = 1'b0;
        if (write_match) begin  // overwrite the resident copy in place
            for (int i = 0; !found && i < NUM_TLB_ENTRIES; i++) begin
                if (write_match_vec[i]) begin
                    victim_idx = TLB_IDX_BITS'(i);
                    found      = 1'b1;
                end
            end
        end else if (|(~valid_vec)) begin  // first free slot
            for (int i = 0; !found && i < NUM_TLB_ENTRIES; i++) begin
                if (!valid_vec[i]) begin
                    victim_idx = TLB_IDX_BITS'(i);
                    found      = 1'b1;
                end
            end
        end else begin  // LRU = the all-zero row (diagonal held at 0)
            for (int i = 0; !found && i < NUM_TLB_ENTRIES; i++) begin
                if (lru_matrix[i] == '0) begin
                    victim_idx = TLB_IDX_BITS'(i);
                    found      = 1'b1;
                end
            end
        end
    end
    always_comb begin
        victim_onehot             = '0;
        victim_onehot[victim_idx] = 1'b1;
    end

    // ---------------------------------------------------------
    // Replacement policy update (reference-matrix exact LRU)
    // ---------------------------------------------------------
    // Per-cycle access set + accessing-port rank (ties break by port). Reads and
    // the fill are mutually exclusive, so it comes from one or the other.
    logic                accessed [NUM_TLB_ENTRIES];
    logic [RANK_BITS-1:0] acc_rank [NUM_TLB_ENTRIES];

    // only real read-port hits drive the LRU; WR_PROBE is a lookup, not an access
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
                    acc_rank[i] = RANK_BITS'(p);
                end
            end
            // A fill targets the victim slot and is the most recent of all.
            if (write_valid_i && write_ready_o && victim_onehot[i]) begin
                accessed[i] = 1'b1;
                acc_rank[i] = RANK_BITS'(NUM_READ_PORTS);
            end
        end
    end

    logic [NUM_TLB_ENTRIES-1:0] lru_matrix_n [NUM_TLB_ENTRIES];
    always_comb begin
        for (int i = 0; i < NUM_TLB_ENTRIES; i++) begin
            for (int j = 0; j < NUM_TLB_ENTRIES; j++) begin
                if (i == j) lru_matrix_n[i][j] = 1'b0;  // diagonal
                else if (accessed[i] && !accessed[j]) lru_matrix_n[i][j] = 1'b1;
                else if (!accessed[i] && accessed[j]) lru_matrix_n[i][j] = 1'b0;
                else if (accessed[i] && accessed[j]) lru_matrix_n[i][j] = (acc_rank[i] > acc_rank[j]);
                else lru_matrix_n[i][j] = lru_matrix[i][j];
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i || clear_valid_i) begin
            for (int i = 0; i < NUM_TLB_ENTRIES; i++) lru_matrix[i] <= '0;
        end else begin
            for (int i = 0; i < NUM_TLB_ENTRIES; i++) lru_matrix[i] <= lru_matrix_n[i];
        end
    end

    // ---------------------------------------------------------
    // Write logic
    // ---------------------------------------------------------
    mmu_pkg::tlb_entry_t write_entry;
    always_comb begin
        write_entry       = write_entry_i;
        write_entry.vpn   = write_vpn_i;
        write_entry.asid  = write_asid_i;
        write_entry.valid = 1'b1;
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int i = 0; i < NUM_TLB_ENTRIES; i++) tlb_entries[i] <= '0;
        end else if (clear_valid_i) begin  // flush; wins over a coincident write
            for (int i = 0; i < NUM_TLB_ENTRIES; i++) tlb_entries[i] <= '0;
        end else if (write_valid_i) begin
            tlb_entries[victim_idx] <= write_entry;
        end
    end

endmodule
