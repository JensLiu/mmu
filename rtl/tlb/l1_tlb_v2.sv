/*
 * Copyright 2023 BSC*
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

`IGNORE_WARNINGS_BEGIN

// L1 TLB: per-core, fully-associative, multi-ported CAM datapath.  Miss handling
// (serialise -> single fire-once L2 request -> fill) is delegated to
// l1_tlb_request_engine; this module owns the CAM, the permission checks, the
// replacement policy, the storage writes/flushes, and the core response.
module l1_tlb_v2
    import mmu_pkg::*;
#(
    parameter int unsigned NUM_TLB_PORTS = 1,
    parameter int unsigned TLB_ENTRIES   = 8
) (
    input logic clk_i,  // System clock signal.
    input logic rstn_i, // System reset signal (active low).

    // TLB request-response
    input  core_tlb_comm_t core_tlb_comms_i[NUM_TLB_PORTS],  // Communication from translation requester to L1 TLB.
    output tlb_core_comm_t tlb_core_comms_o[NUM_TLB_PORTS],  // Communication from L1 TLB to translation requester.

    // L2 TLB interface (fire-once handshake)
    l1_l2_if.l1 l2_if
);

    localparam int unsigned TLB_IDX_SIZE   = $clog2(TLB_ENTRIES);
    localparam int unsigned TLB_PORT_IDX_W = (NUM_TLB_PORTS > 1) ? $clog2(NUM_TLB_PORTS) : 1;

    // -------------------------------------------------------------------------
    // TLB Storage: A generalisation of the TLB Table
    // -------------------------------------------------------------------------
    tlb_storage_if #(
        .TLB_ENTRIES   (TLB_ENTRIES),
        .NUM_READ_PORTS(NUM_TLB_PORTS)
    ) tlb_storage_if ();

    tlb_storage #(
        .NUM_READ_PORTS(NUM_TLB_PORTS),
        .TLB_ENTRIES   (TLB_ENTRIES)
    ) storage (
        .clk_i         (clk_i),
        .rstn_i        (rstn_i),
        .tlb_storage_if(tlb_storage_if)
    );

    // -------------------------------------------------------------------------
    // Parallel CAM hit logic
    // -------------------------------------------------------------------------
    logic                           hit_cam_per_port  [NUM_TLB_PORTS];
    tlb_entry_t                     hit_entry_per_port[NUM_TLB_PORTS];
    logic       [   LEVEL_BITS-1:0] hit_level_per_port[NUM_TLB_PORTS];
    logic       [ TLB_IDX_SIZE-1:0] hit_idx_per_port  [NUM_TLB_PORTS];
    logic       [NUM_TLB_PORTS-1:0] tlb_miss_per_port;
    logic       [NUM_TLB_PORTS-1:0] req_valid_per_port;
    logic       [     VPN_SIZE-1:0] vpn_per_port      [NUM_TLB_PORTS];
    for (genvar i = 0; i < NUM_TLB_PORTS; ++i) begin : g_cam_logic
        logic vm_enable;
        assign vm_enable = core_tlb_comms_i[i].vm_enable;
        assign tlb_storage_if.read_req[i].vpn = core_tlb_comms_i[i].req.vpn;
        assign tlb_storage_if.read_req[i].asid = core_tlb_comms_i[i].req.asid;
        assign hit_cam_per_port[i] = tlb_storage_if.read_resp[i].is_hit;
        assign hit_entry_per_port[i] = tlb_storage_if.read_resp[i].hit_entry;
        assign hit_level_per_port[i] = tlb_storage_if.read_resp[i].hit_level;
        assign hit_idx_per_port[i] = tlb_storage_if.read_resp[i].hit_idx;
        assign req_valid_per_port[i] = core_tlb_comms_i[i].req.valid;
        assign tlb_miss_per_port[i] = core_tlb_comms_i[i].req.valid && vm_enable && !(hit_cam_per_port[i]);
        assign vpn_per_port[i] = core_tlb_comms_i[i].req.vpn;
    end

    // -------------------------------------------------------------------------
    // Parallel TLB Hit/Miss logic and Permission Check
    // -------------------------------------------------------------------------
    logic tlb_hit_per_port  [NUM_TLB_PORTS];
    logic store_hit_per_port[NUM_TLB_PORTS];

    logic xcpt_ifs[NUM_TLB_PORTS], xcpt_sts[NUM_TLB_PORTS], xcpt_lds[NUM_TLB_PORTS];
    for (genvar port = 0; port < NUM_TLB_PORTS; ++port) begin : g_hit_logic
        logic store_hit, read_ok, write_ok, exec_ok;
        pte_perm_check pte_perm_check_it (
            .tlb_entry_i  (hit_entry_per_port[port]),
            .sv_priv_lvl_i(core_tlb_comms_i[port].priv_lvl != '0),
            .is_store_i   (core_tlb_comms_i[port].req.store),
            .store_hit_o  (store_hit),
            .read_ok_o    (read_ok),
            .write_ok_o   (write_ok),
            .exec_ok_o    (exec_ok)
        );
        assign store_hit_per_port[port] = store_hit;

        logic vm_enable, passthrough;
        assign vm_enable   = core_tlb_comms_i[port].vm_enable;
        assign passthrough = core_tlb_comms_i[port].req.passthrough;

        // These information are needed to update the Access and Dirty flags in the TLB entry
        // This should be combinational, since multiple ports may hit the same entry
        logic entry_no_access_bit, entry_no_dirty_bit;
        assign entry_no_access_bit = !hit_entry_per_port[port].access && hit_entry_per_port[port].valid;
        assign entry_no_dirty_bit = !store_hit_per_port[port] && hit_entry_per_port[port].valid;
        assign tlb_hit_per_port[port] = vm_enable && hit_cam_per_port[port] && store_hit_per_port[port];

        // Exception Responses
        // Instruction Fetch
        assign xcpt_ifs[port] = (vm_enable &&
                ((tlb_hit_per_port[port] && !exec_ok) || entry_no_access_bit)
            ) ? 1'b1 : 1'b0;
        // Store
        assign xcpt_sts[port] = (vm_enable &&(
                (tlb_hit_per_port[port] && !write_ok)
                || entry_no_access_bit
                || entry_no_dirty_bit)
            ) ? 1'b1 : 1'b0;
        // Load
        assign xcpt_lds[port] = (vm_enable && ((tlb_hit_per_port[port] && !read_ok)
                ||entry_no_access_bit)
            ) ? 1'b1 : 1'b0;
    end

    // -------------------------------------------------------------------------
    // L2 request payload, per port (the engine selects the granted one).
    // -------------------------------------------------------------------------
    l1_l2_req_data_t req_data_per_port[NUM_TLB_PORTS];
    for (genvar i = 0; i < NUM_TLB_PORTS; ++i) begin : g_req_data
        assign req_data_per_port[i].vpn       = core_tlb_comms_i[i].req.vpn[VPN_SIZE-1:0];
        assign req_data_per_port[i].asid      = core_tlb_comms_i[i].req.asid;
        assign req_data_per_port[i].prv       = core_tlb_comms_i[i].priv_lvl;
        assign req_data_per_port[i].store     = core_tlb_comms_i[i].req.store;
        assign req_data_per_port[i].store_hit = store_hit_per_port[i];
        assign req_data_per_port[i].fetch     = core_tlb_comms_i[i].req.instruction;
    end

    // -------------------------------------------------------------------------
    // Miss request engine: serialise misses -> single fire-once L2 request -> fill
    // -------------------------------------------------------------------------
    logic [TLB_PORT_IDX_W-1:0] active_port;
    logic                      clear_req;
    logic                      fill_valid;
    l2_l1_rsp_data_t           fill_data;
    logic                      invalidate;

    l1_tlb_request_engine #(
        .NUM_TLB_PORTS(NUM_TLB_PORTS)
    ) request_engine (
        .clk_i        (clk_i),
        .rstn_i       (rstn_i),
        .req_valid_i  (req_valid_per_port),
        .tlb_miss_i   (tlb_miss_per_port),
        .req_data_i   (req_data_per_port),
        .active_port_o(active_port),
        .clear_req_o  (clear_req),
        .fill_valid_o (fill_valid),
        .fill_data_o  (fill_data),
        .invalidate_o (invalidate),
        .l2_if        (l2_if)
    );

    // Granted-port selections (used for the store-to-clean clear and the fill).
    wire                    hit_cam   = hit_cam_per_port[active_port];
    wire                    store_hit = store_hit_per_port[active_port];
    wire [TLB_IDX_SIZE-1:0] hit_idx   = hit_idx_per_port[active_port];

    // -------------------------------------------------------------------------
    // Flush: TLBI clears all; otherwise a store to a clean hit drops that entry.
    // -------------------------------------------------------------------------
    logic                   clear_tlb;
    logic [TLB_ENTRIES-1:0] clear_mask;
    always_comb begin
        clear_tlb  = 1'b0;
        clear_mask = '0;
        if (invalidate) begin
            clear_tlb  = 1'b1;
            clear_mask = {TLB_ENTRIES{1'b1}};
        end else if (clear_req) begin
            clear_tlb           = 1'b1;
            clear_mask[hit_idx] = (hit_cam && !store_hit);
        end
    end

    // -------------------------------------------------------------------------
    // Eviction / Victim Selection
    // -------------------------------------------------------------------------
    logic unsigned [TLB_IDX_SIZE-1:0] eviction_idx;
    eviction_policy #(
        .NUM_ENTRIES  (TLB_ENTRIES),
        .NUM_HIT_PORTS(NUM_TLB_PORTS)
    ) eviction_policy (
        .clk_i                  (clk_i),
        .rstn_i                 (rstn_i),
        .access_hit_i           (hit_cam_per_port),
        .access_idx_i           (hit_idx_per_port),
        .write_event_i          (fill_valid),
        .write_idx_i            (eviction_idx),
        .tlb_has_invalid_entry_i(tlb_storage_if.tlb_has_invalid_entry),
        .tlb_invalid_entry_idx_i(tlb_storage_if.tlb_invalid_entry_idx),
        .evict_idx_o            (eviction_idx)
    );

    // -------------------------------------------------------------------------
    // TLB Storage communication. Fill uses the engine's registered L2 response,
    // with the VPN/ASID of the granted miss port (held stable by the engine).
    // -------------------------------------------------------------------------
    assign tlb_storage_if.update_req.write_tlb = fill_valid;
    assign tlb_storage_if.update_req.write_idx = eviction_idx;
    assign tlb_storage_if.update_req.write_entry.vpn = core_tlb_comms_i[active_port].req.vpn[VPN_SIZE-1:0];
    assign tlb_storage_if.update_req.write_entry.asid = core_tlb_comms_i[active_port].req.asid;
    assign tlb_storage_if.update_req.write_entry.ppn = fill_data.tlb_entry.ppn;
    assign tlb_storage_if.update_req.write_entry.level = fill_data.tlb_entry.level;
    assign tlb_storage_if.update_req.write_entry.dirty = fill_data.tlb_entry.dirty;
    assign tlb_storage_if.update_req.write_entry.access = fill_data.tlb_entry.access;
    assign tlb_storage_if.update_req.write_entry.perms = fill_data.tlb_entry.perms;
    assign tlb_storage_if.update_req.write_entry.valid = !fill_data.error;
    assign tlb_storage_if.update_req.write_entry.nempty = 1'b1;
    assign tlb_storage_if.clear_req.clear_tlb = clear_tlb;
    assign tlb_storage_if.clear_req.clear_mask = clear_mask;

    // ----------------------------------------------------------
    // PPN ASSIGNMENT
    // ----------------------------------------------------------
    // PTW encodes superpages as if they were 4 KB pages (LowRISC convention).
    // For a leaf found at PTW level l, the lower (LEVELS-1-l)*PAGE_LVL_BITS
    // bits of the stored PPN are meaningless; those bits come from the VPN instead.
    //   l=LEVELS-1 (4 KB page): use stored PPN directly.
    //   l=0        (largest superpage): replace bottom (LEVELS-1)*PAGE_LVL_BITS bits.
    logic [PPN_SIZE-1:0] ppn_per_port_per_lvl   [NUM_TLB_PORTS] [LEVELS];
    logic [  LEVELS-1:0] hit_per_port_per_lvl   [NUM_TLB_PORTS];
    logic [PPN_SIZE-1:0] ppn_translated_per_port[NUM_TLB_PORTS];
    for (genvar port = 0; port < NUM_TLB_PORTS; ++port) begin : g_ppn_assignment
        logic vm_enable, passthrough;
        assign vm_enable   = core_tlb_comms_i[port].vm_enable;
        assign passthrough = core_tlb_comms_i[port].req.passthrough;

        for (genvar lvl = 0; lvl < LEVELS; ++lvl) begin : g_hit_per_lvl
            assign hit_per_port_per_lvl[port][lvl] =  hit_cam_per_port[port] && (
                hit_level_per_port[port] == LEVEL_BITS'(lvl));
        end

        for (genvar ppn_l = 0; ppn_l < LEVELS; ppn_l++) begin : g_ppn_per_lvl
            localparam int SUPER_PAGE_BITS = (LEVELS - 1 - ppn_l) * PAGE_LVL_BITS;
            if (SUPER_PAGE_BITS == 0) begin : g_kilo
                // Deepest level (4 KB): PPN comes directly from the TLB entry.
                assign ppn_per_port_per_lvl[port][ppn_l] = hit_entry_per_port[port].ppn;
            end else begin : g_super
                // Superpage: replace the lower SUPER_PAGE_BITS of PPN with VPN bits.
                assign ppn_per_port_per_lvl[port][ppn_l] = {
                    hit_entry_per_port[port].ppn[PPN_SIZE-1 : SUPER_PAGE_BITS],
                    vpn_per_port[port][SUPER_PAGE_BITS-1 : 0]
                };
            end
        end

        // PPN is considered translated if any level hits (at most one level hits at a time)
        logic [PPN_SIZE-1:0] ppn_translation_mask_per_lvl[LEVELS];
        for (genvar lvl = 0; lvl < LEVELS; ++lvl) begin : g_ppn_translation_mask
            assign ppn_translation_mask_per_lvl[lvl] = {PPN_SIZE{hit_per_port_per_lvl[port][lvl] & vm_enable & ~passthrough}};
        end
        always_comb begin : g_ppn_selection
            ppn_translated_per_port[port] = '0;
            for (int l = 0; l < LEVELS; l++) begin
                ppn_translated_per_port[port] |=
                    ppn_per_port_per_lvl[port][l] & ppn_translation_mask_per_lvl[l];
            end
        end
    end

    // ---------------------------------------------------------
    // TLB Response
    // ---------------------------------------------------------
    for (genvar i = 0; i < NUM_TLB_PORTS; ++i) begin : g_tlb_resp
        // Not bypass implemented to simplify wiring
        // the PTW/L2 TLB response will update the TLB and we will find hit in the next cycle
        assign tlb_core_comms_o[i].resp.miss       = core_tlb_comms_i[i].req.valid ? tlb_miss_per_port[i] : 1'b0;
        assign tlb_core_comms_o[i].resp.xcpt.load = xcpt_lds[i];
        assign tlb_core_comms_o[i].resp.xcpt.store = xcpt_sts[i];
        assign tlb_core_comms_o[i].resp.xcpt.fetch = xcpt_ifs[i];
        assign tlb_core_comms_o[i].resp.ppn = ppn_translated_per_port[i];
        assign tlb_core_comms_o[i].resp.hit_idx = 'h0;
    end

endmodule

`IGNORE_WARNINGS_END
