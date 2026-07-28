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

module tlb_bank #(
    parameter int unsigned SRC_W = 1,  // = LOG2UP(NUM_SRCS)
    parameter int unsigned NUM_SRCS = 2,  // requesters served by this bank
    parameter int unsigned NUM_TLB_SETS = 128,
    parameter int unsigned NUM_TLB_WAYS = 8,
    parameter int unsigned MSHR_ENTRIES = 4,
    localparam int unsigned PTW_TAG_SLOT_WIDTH = mmu_pkg::PTW_TAG_SLOT_WIDTH,
    localparam int unsigned MSHR_TAG_WIDTH = (MSHR_ENTRIES > 1) ? $clog2(MSHR_ENTRIES) : 1
) (
    input logic clk_i,
    input logic rst_i,

    // Request (slave)
    input  logic                                     req_valid_i,
    output logic                                     req_ready_o,
    /* verilator lint_off UNUSEDSIGNAL */
    input  mmu_pkg::inter_tlb_req_data_t             req_data_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                         [SRC_W-1:0] req_src_i,

    // Response (master)
    output logic                                     rsp_valid_o,
    input  logic                                     rsp_ready_i,
    output mmu_pkg::inter_tlb_rsp_data_t             rsp_data_o,
    output logic                         [SRC_W-1:0] rsp_src_o,

    // lower-level TLB/PTW (master)
    inter_tlb_if.master out_if
);

    // -------------------------------------------------------------------------
    // Store
    // -------------------------------------------------------------------------
    wire  set_dirty = req_data_i.set_dirty;  // computed in the L1 (pte_perm_check)
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
        .rst_i        (rst_i),
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
        .clear_valid_i(out_if.invalidate_tlb),
        .clear_ready_o(tlb_clear_ready)
    );

    wire tlb_read_fire = tlb_read_valid && tlb_read_ready;
    wire read_cam_hit = tlb_read_fire && tlb_read_hit;
    // Dirty bit should NOT return until it's been written
    // TODO: check if L2  dirty bit is set
    wire read_effective_hit = read_cam_hit && !set_dirty;

    // -------------------------------------------------------------------------
    // Request acceptance
    // -------------------------------------------------------------------------
    always_comb begin
        if (rst_i) begin
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
    logic                           allocate_ready;
    logic                           deliver_valid;
    logic                           deliver_ready;
    logic          [  NUM_SRCS-1:0] deliver_cores;
    mmu_pkg::tlb_entry_t            deliver_entry;
    logic                           deliver_error;
    logic                           deliver_write_cache;
    wire                            deliver_fire = deliver_valid && deliver_ready;
    wire                            alloc_valid = req_valid_i && !read_effective_hit;

    banked_tlb_mshr #(
        .MSHR_ENTRIES(MSHR_ENTRIES),
        .NUM_CORES(NUM_SRCS)
    ) mshr (
        .clk_i                (clk_i),
        .rst_i                (rst_i),
        // Allocate (slave)
        .allocate_valid_i     (alloc_valid),
        .allocate_ready_o     (allocate_ready),
        .allocate_vpn_i       (req_data_i.vpn),
        .allocate_asid_i      (req_data_i.asid),
        .allocate_set_dirty_i (req_data_i.set_dirty),
        .allocate_core_id_i   (req_src_i),
        // PTW Issue (master)
        .issue_valid_o        (out_if.req_valid),
        .issue_ready_i        (out_if.req_ready),
        .issue_id_o           (out_if.req_tag.mshr_slot[MSHR_TAG_WIDTH-1:0]),
        .issue_vpn_o          (out_if.req_data.vpn),
        .issue_asid_o         (out_if.req_data.asid),
        .issue_set_dirty_o    (out_if.req_data.set_dirty),
        // PTW Fill (slave)
        .fill_valid_i         (out_if.rsp_valid),
        .fill_ready_o         (out_if.rsp_ready),
        .fill_error_i         (out_if.rsp_data.error),
        .fill_id_i            (MSHR_TAG_WIDTH'(out_if.rsp_tag.mshr_slot)),
        .fill_tlb_entry_i     (out_if.rsp_data.tlb_entry),
        // Deliver (master)
        .deliver_valid_o      (deliver_valid),
        .deliver_ready_i      (deliver_ready),
        .deliver_cores_o      (deliver_cores),
        .deliver_tlb_entry_o  (deliver_entry),
        .deliver_error_o      (deliver_error),
        .deliver_write_cache_o(deliver_write_cache)
    );

    assign out_if.req_tag.bank = '0;  // Filled later by the scheduler
    if (PTW_TAG_SLOT_WIDTH > MSHR_TAG_WIDTH) begin : g_slot_hi
        // zero out the unused high slot bits if the MSHR is smaller than the slot field.
        assign out_if.req_tag.mshr_slot[PTW_TAG_SLOT_WIDTH-1:MSHR_TAG_WIDTH] = '0;
    end

    // -------------------------------------------------------------------------
    // Response engine
    // -------------------------------------------------------------------------
    // Entry for current TLB update
    mmu_pkg::inter_tlb_rsp_data_t deliver_rsp, hit_rsp;
    always_comb begin
        deliver_rsp.tlb_entry = deliver_entry;
        deliver_rsp.error     = deliver_error;
        hit_rsp.tlb_entry     = tlb_read_hit_entry;
        hit_rsp.error         = 1'b0;
    end

    logic deliver_engine_hit_ready;
    tlb_bank_response_engine #(
        .NUM_CORES(NUM_SRCS)
    ) resp_engine (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
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
