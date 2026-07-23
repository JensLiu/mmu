/*
 * Copyright 2026 BSC*
 * *Barcelona Supercomputing Center (BSC)
 *
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Licensed under the Solderpad Hardware License v 2.1 (the “License”); you
 * may not use this file except in compliance with the License, or, at your
 * option, the Apache License version 2.0. You may obtain a copy of the
 * License at
 *
 * https://solderpad.org/licenses/SHL-2.1/
 *
 * Unless required by applicable law or agreed to in writing, any work
 * distributed under the License is distributed on an “AS IS” BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 */

module l2_tlb_mshr #(
    parameter  int unsigned MSHR_SIZE    = 4,
    parameter  int unsigned NUM_CORES    = 32,
    localparam int unsigned VPN_WIDTH    = mmu_pkg::VPN_WIDTH,
    localparam int unsigned PPN_WIDTH    = mmu_pkg::PPN_WIDTH,
    localparam int unsigned ASID_WIDTH   = mmu_pkg::ASID_WIDTH,
    localparam int unsigned LEVEL_BITS   = mmu_pkg::LEVEL_BITS,
    localparam int unsigned TAG_W        = (MSHR_SIZE > 1) ? $clog2(MSHR_SIZE) : 1,
    localparam int unsigned CORE_ID_SIZE = (NUM_CORES > 1) ? $clog2(NUM_CORES) : 1
) (
    input logic clk_i,
    input logic rst_i,

    // Allocate (slave)
    input  logic                    allocate_valid_i,
    output logic                    allocate_ready_o,
    input  logic [   VPN_WIDTH-1:0] allocate_vpn_i,
    input  logic [  ASID_WIDTH-1:0] allocate_asid_i,
    input  logic                    allocate_set_dirty_i,  // store (needs dirty)
    input  logic [CORE_ID_SIZE-1:0] allocate_core_id_i,

    // Issue (master)
    output logic                  issue_valid_o,
    input  logic                  issue_ready_i,
    output logic [     TAG_W-1:0] issue_id_o,
    output logic [ VPN_WIDTH-1:0] issue_vpn_o,
    output logic [ASID_WIDTH-1:0] issue_asid_o,
    output logic                  issue_set_dirty_o,

    // Fill (slave)
    input  logic                           fill_valid_i,
    output logic                           fill_ready_o,
    input  logic                           fill_error_i,
    input  logic          [     TAG_W-1:0] fill_id_i,
    input  mmu_pkg::tlb_entry_t            fill_tlb_entry_i,

    // Deliver (master)
    output logic                           deliver_valid_o,
    input  logic                           deliver_ready_i,
    output logic          [ NUM_CORES-1:0] deliver_cores_o,
    output mmu_pkg::tlb_entry_t            deliver_tlb_entry_o,
    output logic                           deliver_error_o,
    output logic                           deliver_write_cache_o
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
        // TLB fields from response (fill)
        logic [PPN_WIDTH-1:0]   fill_ppn;
        logic [LEVEL_BITS-1:0]  fill_level;
        logic                   fill_access;
        logic                   fill_dirty;
        mmu_pkg::tlb_entry_permissions_t fill_perms;
        logic                   error;
    } mshr_entry_t;

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic mmu_pkg::tlb_entry_t tlb_entry_from_mshr (
        input mshr_entry_t mshr_entry
    );
        tlb_entry_from_mshr.vpn = mshr_entry.vpn;
        tlb_entry_from_mshr.asid = mshr_entry.asid;
        tlb_entry_from_mshr.ppn = mshr_entry.fill_ppn;
        tlb_entry_from_mshr.level = mshr_entry.fill_level;
        tlb_entry_from_mshr.access = mshr_entry.fill_access;
        tlb_entry_from_mshr.dirty = mshr_entry.fill_dirty;
        tlb_entry_from_mshr.perms = mshr_entry.fill_perms;
        tlb_entry_from_mshr.valid = !mshr_entry.error; // TODO: redundant field
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

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
    assign deliver_tlb_entry_o   = tlb_entry_from_mshr(mshr_entries[deliver_id]);
    assign deliver_error_o       = mshr_entries[deliver_id].error;  // TODO:redundant`!tlb_entry.valid`
    assign deliver_write_cache_o = deliver_terminal && !mshr_entries[deliver_id].error;

    wire                  deliver_fire = deliver_valid_o && deliver_ready_i;

    // -------------------------------------------------------------------------
    // Issue select: first *_PENDING_ISSUE slot
    // -------------------------------------------------------------------------
    logic [MSHR_SIZE-1:0] pending_entries;
    for (genvar i = 0; i < MSHR_SIZE; i++) begin : g_pending
        assign pending_entries[i] = (mshr_entries[i].state == ES_CLEAN_PENDING_ISSUE)
                                   || (mshr_entries[i].state == ES_DIRTY_PENDING_ISSUE);
    end

    logic [TAG_W-1:0] issue_id;
    logic             issue_valid;
    VX_priority_encoder #(
        .N(MSHR_SIZE)
    ) issue_sel (
        .data_in  (pending_entries),
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
    logic             mshr_full;
    logic [TAG_W-1:0] alloc_id;

    // ready drops on any deliver snapshot so no CAM write races the snapshot.
    assign allocate_ready_o = (hit_found || !mshr_full) && !deliver_fire;

    wire alloc_handshake = allocate_valid_i && allocate_ready_o;
    wire coalesce_fire = alloc_handshake && hit_found;
    wire alloc_fire = alloc_handshake && !hit_found;

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
        `UNUSED_PIN(empty),
        .full        (mshr_full)
    );

    // -------------------------------------------------------------------------
    // Coalesce routing
    // -------------------------------------------------------------------------
    // Poison: while PTW is doing a clean walk, we coalesced a request with `set_dirty`
    // `set_dirty` is bypassed during `ES_CLEAN_PENDING_ISSUE` stage to prevent lost write
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
    // State updates
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

            // Issue: PTW accepts the issued walk
            if (issue_fire) begin
                if (mshr_entries[issue_id].state == ES_CLEAN_PENDING_ISSUE) begin
                    mshr_entries[issue_id].state <= ES_CLEAN_PENDING_FILL;
                end else begin
                    assert (mshr_entries[issue_id].state == ES_DIRTY_PENDING_ISSUE);
                    mshr_entries[issue_id].state <= ES_DIRTY_PENDING_FILL;
                end
            end

            // Fill: capture the walk result
            if (fill_fire) begin
                assert (mshr_entries[fill_id_i].vpn == fill_tlb_entry_i.vpn);
                assert (mshr_entries[fill_id_i].asid == fill_tlb_entry_i.asid);
                assert (fill_tlb_entry_i.valid == !fill_error_i);
                mshr_entries[fill_id_i].fill_ppn   <= fill_tlb_entry_i.ppn;
                mshr_entries[fill_id_i].fill_level   <= fill_tlb_entry_i.level;
                mshr_entries[fill_id_i].fill_access   <= fill_tlb_entry_i.access;
                mshr_entries[fill_id_i].fill_dirty   <= fill_tlb_entry_i.dirty;
                mshr_entries[fill_id_i].fill_perms   <= fill_tlb_entry_i.perms;
                mshr_entries[fill_id_i].error   <= fill_error_i;
                // assert (!fill_error_i);
                // if (fill_error_i) begin
                //     $finish;
                // end
                if (mshr_entries[fill_id_i].state == ES_CLEAN_PENDING_FILL) begin
                    mshr_entries[fill_id_i].state <= ES_CLEAN_PENDING_DELIVER;
                end else begin
                    assert (mshr_entries[fill_id_i].state == ES_DIRTY_PENDING_FILL);
                    mshr_entries[fill_id_i].state <= ES_DIRTY_PENDING_DELIVER;
                end
            end

            // Deliver: snapshot taken by the engine; advance or free the slot
            if (deliver_fire) begin
                if (deliver_is_clean && deliver_poisoned) begin
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
