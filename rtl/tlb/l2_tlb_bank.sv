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
module l2_tlb_bank
    import mmu_pkg::*;
#(
    parameter int unsigned SRC_W       = 1,  // = LOG2UP(NUM_SRCS)
    parameter int unsigned NUM_SRCS    = 2,  // requesters served by this bank
    parameter int unsigned TLB_ENTRIES = 8,
    parameter int unsigned MSHR_SIZE   = 4
) (
    input logic clk_i,
    input logic rstn_i,

    // Request in (fire-once, from the request xbar output)
    input  logic                        req_valid_i,
    output logic                        req_ready_o,
    input  l1_l2_req_data_t             req_data_i,
    input  logic            [SRC_W-1:0] req_src_i,

    // Response out (fire-once, to the response xbar input)
    output logic                        rsp_valid_o,
    input  logic                        rsp_ready_i,
    output l2_l1_rsp_data_t             rsp_data_o,
    output logic            [SRC_W-1:0] rsp_src_o,

    // PTW master (unified ready/valid)
    l2_ptw_if.tlb ptw_if
);

    localparam int unsigned TLB_IDX_SIZE = $clog2(TLB_ENTRIES);
    localparam int unsigned MSHR_TAG_W = (MSHR_SIZE > 1) ? $clog2(MSHR_SIZE) : 1;

    // -------------------------------------------------------------------------
    // pte_t -> payload / cache entry helpers
    // -------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic l2_l1_rsp_data_t rsp_from_pte(
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
        rsp_from_pte.tlb_entry.nempty   = 1'b1;
    endfunction

    function automatic tlb_entry_t entry_from_pte(
        input pte_t pte, input logic [LEVEL_BITS-1:0] level, input logic [VPN_SIZE-1:0] vpn,
        input logic [ASID_SIZE-1:0] asid);
        l2_l1_rsp_data_t r = rsp_from_pte(pte, level, 1'b0);
        entry_from_pte      = r.tlb_entry;
        entry_from_pte.vpn  = vpn;
        entry_from_pte.asid = asid;
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------------------------
    // Store (single read port - probed combinationally per request)
    // -------------------------------------------------------------------------
    tlb_storage_if #(
        .TLB_ENTRIES   (TLB_ENTRIES),
        .NUM_READ_PORTS(1)
    ) tlb_storage_if ();

    tlb_storage #(
        .NUM_READ_PORTS(1),
        .TLB_ENTRIES   (TLB_ENTRIES)
    ) storage (
        .clk_i         (clk_i),
        .rstn_i        (rstn_i),
        .tlb_storage_if(tlb_storage_if)
    );

    assign tlb_storage_if.read_req[0].vpn  = req_data_i.vpn;
    assign tlb_storage_if.read_req[0].asid = req_data_i.asid;

    tlb_entry_t                    hit_entry;
    logic       [TLB_IDX_SIZE-1:0] hit_idx;
    assign hit_entry = tlb_storage_if.read_resp[0].hit_entry;
    assign hit_idx   = tlb_storage_if.read_resp[0].hit_idx;

    wire                   cam_hit = tlb_storage_if.read_resp[0].is_hit;
    wire                   store_hit = req_data_i.store_hit;  // computed in the L1 (pte_perm_check)
    wire                   eff_hit = cam_hit && store_hit;

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

    wire                   req_fire = req_valid_i && req_ready_o;
    wire                   alloc_valid = req_valid_i && !eff_hit;  // miss (incl. store-to-clean)

    l2_tlb_mshr #(
        .MSHR_SIZE(MSHR_SIZE),
        .NUM_CORES(NUM_SRCS)
    ) mshr (
        .clk_i                (clk_i),
        .rstn_i               (rstn_i),
        // allocate
        .allocate_valid_i     (alloc_valid),
        .allocate_ready_o     (allocate_ready),
        .allocate_vpn_i       (req_data_i.vpn),
        .allocate_asid_i      (req_data_i.asid),
        .allocate_set_dirty_i (req_data_i.store),
        .allocate_prv_i       (req_data_i.prv),
        .allocate_fetch_i     (req_data_i.fetch),
        .allocate_core_id_i   (req_src_i),
        // issue
        .issue_valid_o        (ptw_if.req_valid),
        .issue_ready_i        (ptw_if.req_ready),
        .issue_id_o           (ptw_if.req_data.tag[MSHR_TAG_W-1:0]),
        .issue_vpn_o          (ptw_if.req_data.vpn),
        .issue_asid_o         (ptw_if.req_data.asid),
        .issue_set_dirty_o    (ptw_if.req_data.store),
        .issue_prv_o          (ptw_if.req_data.prv),
        .issue_fetch_o        (ptw_if.req_data.fetch),
        // fill
        .fill_valid_i         (ptw_if.rsp_valid),
        .fill_ready_o         (ptw_if.rsp_ready),
        .fill_id_i            (MSHR_TAG_W'(ptw_if.rsp_data.tag)),
        .fill_pte_i           (ptw_if.rsp_data.pte),
        .fill_level_i         (ptw_if.rsp_data.level),
        .fill_error_i         (ptw_if.rsp_data.error),
        // deliver
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

    // The MSHR slot id (issue_id_o) drives the low tag bits above; zero-extend
    // the rest of the opaque PTW tag field (room for {bank,slot} later).
    if (PTW_TAG_W > MSHR_TAG_W) begin : g_tag_hi
        assign ptw_if.req_data.tag[PTW_TAG_W-1:MSHR_TAG_W] = '0;
    end

    // -------------------------------------------------------------------------
    // Response engine: serializes a coalesced deliver (or a single hit) onto the
    // response port, one src/cycle.  Payload-opaque - it receives finished rsp
    // structs (PTE expansion + the cache write stay here in the bank).
    // -------------------------------------------------------------------------
    l2_l1_rsp_data_t deliver_rsp, hit_rsp;
    assign deliver_rsp = rsp_from_pte(deliver_pte, deliver_level, deliver_error);
    always_comb begin
        hit_rsp           = '0;
        hit_rsp.tlb_entry = hit_entry;
    end

    logic eng_hit_ready;
    l2_tlb_bank_response_engine #(
        .NUM_CORES(NUM_SRCS)
    ) resp_engine (
        .clk_i               (clk_i),
        .rstn_i              (rstn_i),
        // MSHR deliver -> engine
        .mshr_deliver_valid_i(deliver_valid),
        .mshr_deliver_ready_o(deliver_ready),
        .mshr_deliver_cores_i(deliver_cores),
        .mshr_deliver_rsp_i  (deliver_rsp),
        // direct hit -> engine
        .tlb_hit_valid_i     (req_valid_i && eff_hit),
        .tlb_hit_ready_o     (eng_hit_ready),
        .tlb_hit_core_i      (req_src_i),
        .tlb_hit_rep_i       (hit_rsp),
        // engine -> bank response port
        .rsp_valid_o         (rsp_valid_o),
        .rsp_ready_i         (rsp_ready_i),
        .rsp_data_o          (rsp_data_o),
        .rsp_src_o           (rsp_src_o)
    );

    // -------------------------------------------------------------------------
    // Request acceptance
    //   eff_hit : the engine accepts the hit (deliver has priority internally)
    //   miss    : the MSHR accepts (its ready drops on a deliver snapshot)
    // -------------------------------------------------------------------------
    always_comb begin
        if (!rstn_i) req_ready_o = 1'b0;
        else if (eff_hit) req_ready_o = eng_hit_ready;
        else req_ready_o = allocate_ready;
    end

    // -------------------------------------------------------------------------
    // Eviction (NRU)
    // -------------------------------------------------------------------------
    logic                    acc_hit[1];
    logic [TLB_IDX_SIZE-1:0] acc_idx[1];
    assign acc_hit[0] = req_fire && cam_hit;
    assign acc_idx[0] = hit_idx;

    logic                    write_tlb;
    logic [TLB_IDX_SIZE-1:0] eviction_idx;
    eviction_policy #(
        .NUM_ENTRIES  (TLB_ENTRIES),
        .NUM_HIT_PORTS(1)
    ) eviction_policy (
        .clk_i                  (clk_i),
        .rstn_i                 (rstn_i),
        .access_hit_i           (acc_hit),
        .access_idx_i           (acc_idx),
        .write_event_i          (write_tlb),
        .write_idx_i            (eviction_idx),
        .tlb_has_invalid_entry_i(tlb_storage_if.tlb_has_invalid_entry),
        .tlb_invalid_entry_idx_i(tlb_storage_if.tlb_invalid_entry_idx),
        .evict_idx_o            (eviction_idx)
    );

    // -------------------------------------------------------------------------
    // Store updates: write on a terminal deliver; clear on invalidate or on a
    // store-to-clean hit (drop the clean entry so the dirty walk re-fills it).
    // (write and store-to-clean clear can never coincide: a miss cannot fire on
    //  a deliver_fire cycle.  TODO: invalidate does not squash in-flight MSHR.)
    // -------------------------------------------------------------------------
    wire deliver_fire = deliver_valid && deliver_ready;  // engine accepted the snapshot
    assign write_tlb = deliver_fire && deliver_write_cache;

    logic [TLB_ENTRIES-1:0] clear_mask;
    logic                   clear_tlb;
    always_comb begin
        clear_tlb  = 1'b0;
        clear_mask = '0;
        if (ptw_if.invalidate_tlb) begin
            clear_tlb  = 1'b1;
            clear_mask = {TLB_ENTRIES{1'b1}};
        end else if (req_fire && cam_hit && !store_hit) begin
            clear_tlb           = 1'b1;
            clear_mask[hit_idx] = 1'b1;
        end
    end

    tlb_entry_t deliver_entry;
    assign deliver_entry = entry_from_pte(deliver_pte, deliver_level, deliver_vpn, deliver_asid);

    assign tlb_storage_if.update_req.write_tlb = write_tlb;
    assign tlb_storage_if.update_req.write_idx = eviction_idx;
    assign tlb_storage_if.update_req.write_entry = deliver_entry;
    assign tlb_storage_if.clear_req.clear_tlb = clear_tlb;
    assign tlb_storage_if.clear_req.clear_mask = clear_mask;

endmodule
