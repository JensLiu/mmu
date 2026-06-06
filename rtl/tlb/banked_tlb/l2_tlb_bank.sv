/*
 * Copyright 2026 BSC*
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

// Non-blocking, MSHR-coalescing L2 TLB bank.
//
//  - Ingress: probe the store combinationally on the incoming request.
//      * eff_hit (cam_hit && store_ok) -> load the response engine (1 src)
//      * miss / store-to-clean         -> allocate (or coalesce) an MSHR slot
//  - Issue : the MSHR presents a pending walk on the PTW request channel.
//  - Fill  : a PTW response is captured directly into its slot (keyed by tag).
//  - Deliver: the MSHR hands the response engine a {cores,result} snapshot; the
//    engine drains one src/cycle and, on a terminal deliver, writes the cache.
//
// The store is the correctness backstop and is written exactly once per slot,
// on its terminal deliver (so each VPN appears at most once in the store).
`IGNORE_WARNINGS_BEGIN
module l2_tlb_bank
    import mmu_pkg::*;
#(
    parameter int unsigned SRC_W        = 1,    // = LOG2UP(NUM_SRCS)
    parameter int unsigned NUM_SRCS     = 2,    // requesters served by this bank
    parameter int unsigned NUM_TLB_SETS = 128,
    parameter int unsigned NUM_TLB_WAYS = 8,
    parameter int unsigned MSHR_SIZE    = 4
) (
    input logic clk_i,
    input logic rstn_i,

    // Request (slave)
    input  logic                                     req_valid_i,
    output logic                                     req_ready_o,
    input  mmu_pkg::inter_tlb_req_data_t             req_data_i,
    input  logic                         [SRC_W-1:0] req_src_i,

    // Response (master)
    output logic                                     rsp_valid_o,
    input  logic                                     rsp_ready_i,
    output mmu_pkg::inter_tlb_rsp_data_t             rsp_data_o,
    output logic                         [SRC_W-1:0] rsp_src_o,

    // PTW (master)
    ptw_if.master ptw_if
);

    localparam int unsigned TLB_SET_IDX_SIZE = $clog2(NUM_TLB_SETS);
    localparam int unsigned TLB_WAY_IDX_SIZE = $clog2(NUM_TLB_WAYS);
    localparam int unsigned MSHR_TAG_W = (MSHR_SIZE > 1) ? $clog2(MSHR_SIZE) : 1;

    // -------------------------------------------------------------------------
    // pte_t -> payload / cache entry helpers
    // -------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic inter_tlb_rsp_data_t rsp_from_pte(
        input pte_t pte, input logic [LEVEL_BITS-1:0] level, input logic error);
        rsp_from_pte                    = '0;
        rsp_from_pte.error              = error;
        rsp_from_pte.tlb_entry.ppn      = pte.ppn;
        rsp_from_pte.tlb_entry.level    = 2'(level);
        rsp_from_pte.tlb_entry.dirty    = pte.d;
        rsp_from_pte.tlb_entry.access   = pte.a;
        rsp_from_pte.tlb_entry.perms.ur = pte.r & pte.u & pte.v;
        rsp_from_pte.tlb_entry.perms.uw = pte.w & pte.u & pte.v;
        rsp_from_pte.tlb_entry.perms.ux = pte.x & pte.u & pte.v;
        rsp_from_pte.tlb_entry.perms.sr = pte.r & ~pte.u & pte.v;
        rsp_from_pte.tlb_entry.perms.sw = pte.w & ~pte.u & pte.v;
        rsp_from_pte.tlb_entry.perms.sx = pte.x & ~pte.u & pte.v;
        rsp_from_pte.tlb_entry.valid    = !error;
    endfunction

    function automatic tlb_entry_t entry_from_pte(
        input pte_t pte, input logic [LEVEL_BITS-1:0] level, input logic [VPN_SIZE-1:0] vpn,
        input logic [ASID_SIZE-1:0] asid);
        inter_tlb_rsp_data_t r = rsp_from_pte(pte, level, 1'b0);
        entry_from_pte      = r.tlb_entry;
        entry_from_pte.vpn  = vpn;
        entry_from_pte.asid = asid;
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------------------------
    // Store
    // -------------------------------------------------------------------------
    wire  write_dirty_bit = req_data_i.set_dirty_bit;  // computed in the L1 (pte_perm_check)
    logic tlb_read_valid;
    assign tlb_read_valid = req_valid_i;
    /* verilator lint_off UNUSEDSIGNAL */
    logic tlb_read_ready, tlb_write_ready, tlb_clear_ready;
    /* verilator lint_on UNUSEDSIGNAL */
    logic                tlb_read_hit;
    mmu_pkg::tlb_entry_t tlb_read_hit_entry;

    tlb_storage_set_associative #(
        .NUM_TLB_SETS(NUM_TLB_SETS),
        .NUM_TLB_WAYS(NUM_TLB_WAYS)
    ) tlb_storage (
        .clk_i        (clk_i),
        .rstn_i       (rstn_i),
        // Read (slave)
        .read_valid_i (req_valid_i),
        .read_ready_o (tlb_read_ready),
        .read_is_hit_o(tlb_read_hit),
        .read_asid_i  (req_data_i.asid),
        .read_vpn_i   (req_data_i.vpn),
        `UNUSED_PIN(read_level_o),
        .read_entry_o (tlb_read_hit_entry),
        // Write (slave): update-in-place keeps one entry per VPN, so the dirty
        // re-walk simply overwrites the resident clean entry (no clear needed).
        .write_valid_i(deliver_fire && deliver_write_cache),
        .write_ready_o(tlb_write_ready),
        .write_vpn_i  (deliver_entry.vpn),
        .write_asid_i (deliver_entry.asid),
        .write_entry_i(deliver_entry),
        // Clear (slave): flush-all on a TLB Invalidate broadcast.
        .clear_valid_i(ptw_if.invalidate_tlb),
        .clear_ready_o(tlb_clear_ready)
    );

    wire tlb_read_fire = tlb_read_valid && tlb_read_ready;
    wire read_cam_hit = tlb_read_fire && tlb_read_hit;
    // Dirty bit should NOT return until it's been written
    // TODO: check if L2  dirty bit is set
    wire read_effective_hit = read_cam_hit && !write_dirty_bit;

    // -------------------------------------------------------------------------
    // Request acceptance
    // -------------------------------------------------------------------------
    always_comb begin
        if (!rstn_i) begin
            req_ready_o = 1'b0;
        end else if (read_effective_hit) begin
            // Read Hit: ask deliver engine to accept this hit
            req_ready_o = deliver_engine_hit_ready;
        end else begin
            // Read Miss: ask MHSR to accept allocation
            req_ready_o = allocate_ready;
        end
    end

    // -------------------------------------------------------------------------
    // MSHR
    // -------------------------------------------------------------------------
    logic                  allocate_ready;
    logic                  deliver_valid;
    logic                  deliver_ready;
    logic [  NUM_SRCS-1:0] deliver_cores;
    pte_t                  deliver_pte;
    logic [LEVEL_BITS-1:0] deliver_level;
    logic                  deliver_error;
    logic [  VPN_SIZE-1:0] deliver_vpn;
    logic [ ASID_SIZE-1:0] deliver_asid;
    logic                  deliver_write_cache;
    wire                   deliver_fire = deliver_valid && deliver_ready;
    wire                   alloc_valid = req_valid_i && !read_effective_hit;

    l2_tlb_mshr #(
        .MSHR_SIZE(MSHR_SIZE),
        .NUM_CORES(NUM_SRCS)
    ) mshr (
        .clk_i                (clk_i),
        .rstn_i               (rstn_i),
        // Allocate (slave)
        .allocate_valid_i     (alloc_valid),
        .allocate_ready_o     (allocate_ready),
        .allocate_vpn_i       (req_data_i.vpn),
        .allocate_asid_i      (req_data_i.asid),
        .allocate_set_dirty_i (req_data_i.set_dirty_bit),
        .allocate_prv_i       (req_data_i.prv),
        .allocate_core_id_i   (req_src_i),
        // PTW Issue (master)
        .issue_valid_o        (ptw_if.req_valid),
        .issue_ready_i        (ptw_if.req_ready),
        .issue_id_o           (ptw_if.req_data.tag.mshr_slot[MSHR_TAG_W-1:0]),
        .issue_vpn_o          (ptw_if.req_data.vpn),
        .issue_asid_o         (ptw_if.req_data.asid),
        .issue_set_dirty_o    (ptw_if.req_data.store),
        .issue_prv_o          (ptw_if.req_data.prv),
        // PTW Fill (slave)
        .fill_valid_i         (ptw_if.rsp_valid),
        .fill_ready_o         (ptw_if.rsp_ready),
        .fill_id_i            (MSHR_TAG_W'(ptw_if.rsp_data.tag.mshr_slot)),
        .fill_pte_i           (ptw_if.rsp_data.pte),
        .fill_level_i         (ptw_if.rsp_data.level),
        .fill_error_i         (ptw_if.rsp_data.error),
        // Deliver (master)
        .deliver_valid_o      (deliver_valid),
        .deliver_ready_i      (deliver_ready),
        .deliver_cores_o      (deliver_cores),
        .deliver_pte_o        (deliver_pte),
        .deliver_level_o      (deliver_level),
        .deliver_error_o      (deliver_error),
        .deliver_vpn_o        (deliver_vpn),
        .deliver_asid_o       (deliver_asid),
        .deliver_write_cache_o(deliver_write_cache),
        `UNUSED_PIN(pending_entries_o)
    );

    assign ptw_if.req_data.tag.bank = '0;  // Filled later by the scheduler
    if (PTW_TAG_SLOT_W > MSHR_TAG_W) begin : g_slot_hi
        // zero out the unused high slot bits if the MSHR is smaller than the slot field.
        assign ptw_if.req_data.tag.mshr_slot[PTW_TAG_SLOT_W-1:MSHR_TAG_W] = '0;
    end

    // -------------------------------------------------------------------------
    // Response engine: serializes a coalesced deliver (or a single hit) onto the
    // response port, one src/cycle.  Payload-opaque - it receives finished rsp
    // structs (PTE expansion + the cache write stay here in the bank).
    // -------------------------------------------------------------------------
    // Entry for current TLB update
    tlb_entry_t deliver_entry;
    assign deliver_entry = entry_from_pte(deliver_pte, deliver_level, deliver_vpn, deliver_asid);
    // Response for upstream TLB update
    inter_tlb_rsp_data_t deliver_rsp;  // MSHR Deliver Response
    assign deliver_rsp = rsp_from_pte(deliver_pte, deliver_level, deliver_error);
    inter_tlb_rsp_data_t hit_rsp;  // TLB Hit Response
    always_comb begin
        hit_rsp           = '0;
        hit_rsp.tlb_entry = tlb_read_hit_entry;
    end

    logic deliver_engine_hit_ready;  // Hit/Deliver Arbitration (request ready back pressure)
    l2_tlb_bank_response_engine #(
        .NUM_CORES(NUM_SRCS)
    ) resp_engine (
        .clk_i               (clk_i),
        .rstn_i              (rstn_i),
        // MSHR Deliver (slave)
        .mshr_deliver_valid_i(deliver_valid),
        .mshr_deliver_ready_o(deliver_ready),
        .mshr_deliver_cores_i(deliver_cores),
        .mshr_deliver_rsp_i  (deliver_rsp),
        // TLB Hit (slave)
        .tlb_hit_valid_i     (req_valid_i && read_effective_hit),
        .tlb_hit_ready_o     (deliver_engine_hit_ready),
        .tlb_hit_core_i      (req_src_i),
        .tlb_hit_rsp_i       (hit_rsp),
        // Response (master)
        .rsp_valid_o         (rsp_valid_o),
        .rsp_ready_i         (rsp_ready_i),
        .rsp_data_o          (rsp_data_o),
        .rsp_src_o           (rsp_src_o)
    );


endmodule
`IGNORE_WARNINGS_END
