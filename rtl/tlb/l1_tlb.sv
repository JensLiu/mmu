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

module l1_tlb
    import mmu_pkg::*;
#(
    parameter int unsigned NUM_TLB_PORTS = 1
) (
    input logic clk_i,  // System clock signal.
    input logic rstn_i, // System reset signal (active low).

    // TLB request-response
    input  core_tlb_comm_t core_tlb_comms_i[NUM_TLB_PORTS],  // Communication from translation requester to L1 TLB.
    output tlb_core_comm_t tlb_core_comms_o[NUM_TLB_PORTS],  // Communication from L1 TLB to translation requester.

    // PTW request-response
    input  l2_l1_comm_t l2_l1_comm_i,  // Communication from L1 TLB to PTW/L2 TLB.
    output l1_l2_comm_t l1_l2_comm_o   // Communication from PTW/L2 TLB to L1 TLB.
);
    // Break combinational feedback from the PTW/L2 response path to request generation.
    l2_l1_comm_t l2_l1_comm_q;
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            l2_l1_comm_q <= '0;
        end else begin
            l2_l1_comm_q <= l2_l1_comm_i;
        end
    end

    // -------------------------------------------------------------------------
    // TLB Storage: A generalisation of the TLB Table
    // -------------------------------------------------------------------------
    tlb_storage_read_comm_t                    tlb_storage_read_comms [NUM_TLB_PORTS];
    storage_tlb_read_comm_t                    storage_tlb_read_comms [NUM_TLB_PORTS];
    tlb_storage_write_comm_t                   tlb_storage_write_comm;
    // metadata used for replacement/victim selection
    logic                                      tlb_has_invalid_entry;
    logic                    [TLB_ENTRIES-1:0] tlb_invalid_entry_idx;
    tlb_storage #(
        .NUM_READ_PORTS(NUM_TLB_PORTS)
    ) storage (
        .clk_i                       (clk_i),
        .rstn_i                      (rstn_i),
        .tlb_storage_read_comms_i    (tlb_storage_read_comms),
        .storage_tlb_read_comms_o    (storage_tlb_read_comms),
        .tlb_storage_write_comm_i    (tlb_storage_write_comm),
        .tlb_has_invalid_entry_o     (tlb_has_invalid_entry),
        .some_tlb_invalid_entry_idx_o(tlb_invalid_entry_idx)
    );


    // -------------------------------------------------------------------------
    // Parallel CAM hit logic
    // -------------------------------------------------------------------------
    logic                           hit_cam_per_port  [NUM_TLB_PORTS];
    tlb_entry_t                     hit_entry_per_port[NUM_TLB_PORTS];
    logic       [   LEVEL_BITS-1:0] hit_level_per_port[NUM_TLB_PORTS];
    logic       [ TLB_IDX_SIZE-1:0] hit_idx_per_port  [NUM_TLB_PORTS];
    logic       [NUM_TLB_PORTS-1:0] tlb_miss_per_port;
    logic       [     VPN_SIZE-1:0] vpn_per_port      [NUM_TLB_PORTS];
    for (genvar i = 0; i < NUM_TLB_PORTS; ++i) begin : g_cam_logic
        logic vm_enable;
        assign vm_enable = core_tlb_comms_i[i].vm_enable;
        assign tlb_storage_read_comms[i].read_req.vpn = core_tlb_comms_i[i].req.vpn;
        assign tlb_storage_read_comms[i].read_req.asid = core_tlb_comms_i[i].req.asid;
        assign hit_cam_per_port[i] = storage_tlb_read_comms[i].read_resp.is_hit;
        assign hit_entry_per_port[i] = storage_tlb_read_comms[i].read_resp.hit_entry;
        assign hit_level_per_port[i] = storage_tlb_read_comms[i].read_resp.hit_level;
        assign hit_idx_per_port[i] = storage_tlb_read_comms[i].read_resp.hit_idx;
        assign tlb_miss_per_port[i] = core_tlb_comms_i[i].req.valid && vm_enable && !(hit_cam_per_port[i]);
        assign vpn_per_port[i] = core_tlb_comms_i[i].req.vpn;
    end

    // -------------------------------------------------------------------------
    // Parallel TLB Hit/Miss logic and Permission Check
    // -------------------------------------------------------------------------
    // Parallel Hit logic
    logic tlb_hit_per_port  [NUM_TLB_PORTS];
    logic store_hit_per_port[NUM_TLB_PORTS];

    logic xcpt_ifs[NUM_TLB_PORTS], xcpt_sts[NUM_TLB_PORTS], xcpt_lds[NUM_TLB_PORTS];
    for (genvar port = 0; port < NUM_TLB_PORTS; ++port) begin : g_hit_logic
        logic store_hit, read_ok, write_ok, exec_ok;
        pte_perm_check pte_perm_check_it (
            .ptw_status_i (l2_l1_comm_q.ptw_status),
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
                || entry_no_access_bit)
            ) ? 1'b1 : 1'b0;

    end

    // -------------------------------------------------------------------------
    // Serialised TLB Miss Handling
    // -------------------------------------------------------------------------

    // Select one TLB miss to serve, on simultanious TLB miss on the same TLB entry,
    // after the first serve, all other CAM will become hits
    logic                                                       miss_grant_next;
    logic                                                       miss_active;
    logic [(NUM_TLB_PORTS > 1 ? $clog2(NUM_TLB_PORTS) : 1)-1:0] miss_port;

    request_serialiser #(
        .NUM_PORTS(NUM_TLB_PORTS)
    ) tlb_miss_serialiser (
        .clk_i       (clk_i),
        .rstn_i      (rstn_i),
        .tlb_misses_i(tlb_miss_per_port),
        .grant_next_i(miss_grant_next),
        .active_o    (miss_active),
        .active_idx_o(miss_port)
    );

    // TODO: check this logic?
    // We can grant the next miss when the FSM has finished processing the current miss;
    assign miss_grant_next = fsm_finished;

    logic tlb_hit, tlb_miss, store_hit, vm_enable, passthrough, hit_cam;
    tlb_entry_t                    hit_entry;
    logic       [TLB_IDX_SIZE-1:0] hit_idx;
    assign hit_entry   = tlb_hit_per_port[miss_port] ? hit_entry_per_port[miss_port] : '0;
    assign tlb_hit     = tlb_hit_per_port[miss_port];
    assign tlb_miss    = tlb_miss_per_port[miss_port];
    assign hit_idx     = hit_idx_per_port[miss_port];
    assign store_hit   = store_hit_per_port[miss_port];
    assign vm_enable   = core_tlb_comms_i[miss_port].vm_enable;
    assign passthrough = core_tlb_comms_i[miss_port].req.passthrough;
    assign hit_cam     = hit_cam_per_port[miss_port];

    // Flush
    logic [TLB_ENTRIES-1:0] clear_mask;
    logic                   clear_tlb_req;
    always_comb begin
        clear_tlb  = 1'b0;
        clear_mask = '0;
        if (l2_l1_comm_q.invalidate_tlb) begin
            clear_tlb  = 1'b1;
            clear_mask = 'hFF;
        end else if (clear_tlb_req) begin
            clear_tlb           = 1'b1;
            // Flush cam hit in a non-dirty page when store arrives
            clear_mask[hit_idx] = (hit_cam && !store_hit);
        end
    end

    // L1 Miss Request FSM
    logic store_tlb_req, send_tlb_req, write_tlb, clear_tlb, fsm_finished;
    miss_req_fsm miss_req_fsm (
        .clk_i           (clk_i),
        .rstn_i          (rstn_i),
        // Input Flags
        .req_valid_i     (core_tlb_comms_i[miss_port].req.valid),
        .tlb_miss_i      (tlb_miss),
        .ptw_ready_i     (l2_l1_comm_q.ptw_ready),
        .invalidate_tlb_i(l2_l1_comm_q.invalidate_tlb),
        .rsp_valid_i     (l2_l1_comm_q.resp.valid),
        // Output Flags
        .fsm_finished_o  (fsm_finished),
        .store_tlb_req_o (store_tlb_req),
        .send_tlb_req_o  (send_tlb_req),
        .write_tlb_o     (write_tlb),
        .clear_tlb_o     (clear_tlb_req)
    );


    // Eviction / Victim Selection
    logic unsigned [TLB_IDX_SIZE-1:0] eviction_idx;
    eviction_policy eviction_policy (
        .clk_i                  (clk_i),
        .rstn_i                 (rstn_i),
        .access_hit_i           (hit_cam),
        .access_idx_i           (hit_idx),
        .write_event_i          (write_tlb),
        .write_idx_i            (tlb_req_tmp.write_idx),
        .tlb_has_invalid_entry_i(tlb_has_invalid_entry),
        .tlb_invalid_entry_idx_i(tlb_invalid_entry_idx),
        .evict_idx_o            (eviction_idx)
    );

    // L1-L2 TLB request temporary storage
    tlb_req_tmp_storage_t tlb_req_tmp;
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            tlb_req_tmp <= '0;
        end else if (store_tlb_req) begin
            tlb_req_tmp.vpn       <= core_tlb_comms_i[miss_port].req.vpn[VPN_SIZE-1:0];
            tlb_req_tmp.asid      <= core_tlb_comms_i[miss_port].req.asid;
            tlb_req_tmp.store     <= core_tlb_comms_i[miss_port].req.store;
            tlb_req_tmp.fetch     <= core_tlb_comms_i[miss_port].req.instruction;
            tlb_req_tmp.write_idx <= eviction_idx;
        end
    end

    // L1-L2 TLB send request
    always_comb begin
        if (send_tlb_req) begin
            l1_l2_comm_o.req.valid = 1'b1;
            l1_l2_comm_o.req.vpn = tlb_req_tmp.vpn;
            l1_l2_comm_o.req.asid = tlb_req_tmp.asid;
            l1_l2_comm_o.req.prv = core_tlb_comms_i[miss_port].priv_lvl; // note that we send the current cycle prv lvl
            l1_l2_comm_o.req.store = tlb_req_tmp.store;
            l1_l2_comm_o.req.fetch = tlb_req_tmp.fetch;
        end else begin
            l1_l2_comm_o.req = '0;
        end
    end

    // TLB Storage communication
    assign tlb_storage_write_comm.update_req.write_tlb = write_tlb;
    assign tlb_storage_write_comm.update_req.write_idx = tlb_req_tmp.write_idx;
    assign tlb_storage_write_comm.update_req.write_entry.vpn = tlb_req_tmp.vpn;
    assign tlb_storage_write_comm.update_req.write_entry.asid = tlb_req_tmp.asid;
    assign tlb_storage_write_comm.update_req.write_entry.ppn = l2_l1_comm_q.resp.pte.ppn;
    assign tlb_storage_write_comm.update_req.write_entry.level = l2_l1_comm_q.resp.level;
    assign tlb_storage_write_comm.update_req.write_entry.dirty = l2_l1_comm_q.resp.pte.d;
    assign tlb_storage_write_comm.update_req.write_entry.access = l2_l1_comm_q.resp.pte.a;
    assign tlb_storage_write_comm.update_req.write_entry.perms.ur = l2_l1_comm_q.resp.pte.r & l2_l1_comm_q.resp.pte.u & l2_l1_comm_q.resp.pte.v;
    assign tlb_storage_write_comm.update_req.write_entry.perms.uw = l2_l1_comm_q.resp.pte.w & l2_l1_comm_q.resp.pte.u & l2_l1_comm_q.resp.pte.v;
    assign tlb_storage_write_comm.update_req.write_entry.perms.ux = l2_l1_comm_q.resp.pte.x & l2_l1_comm_q.resp.pte.u & l2_l1_comm_q.resp.pte.v;
    assign tlb_storage_write_comm.update_req.write_entry.perms.sr = l2_l1_comm_q.resp.pte.r & !l2_l1_comm_q.resp.pte.u & l2_l1_comm_q.resp.pte.v;
    assign tlb_storage_write_comm.update_req.write_entry.perms.sw = l2_l1_comm_q.resp.pte.w & !l2_l1_comm_q.resp.pte.u & l2_l1_comm_q.resp.pte.v;
    assign tlb_storage_write_comm.update_req.write_entry.perms.sx = l2_l1_comm_q.resp.pte.x & !l2_l1_comm_q.resp.pte.u & l2_l1_comm_q.resp.pte.v;
    assign tlb_storage_write_comm.update_req.write_entry.valid = !l2_l1_comm_q.resp.error;
    assign tlb_storage_write_comm.update_req.write_entry.nempty = 1'b1;
    assign tlb_storage_write_comm.clear_req.clear_tlb = clear_tlb;
    assign tlb_storage_write_comm.clear_req.clear_mask = clear_mask;


    // ----------------------------------------------------------
    // PPN ASSIGNMENT
    // ----------------------------------------------------------
    // PTW encodes superpages as if they were 4 KB pages (LowRISC convention).
    // For a leaf found at PTW level l, the lower (LEVELS-1-l)*PAGE_LVL_BITS
    // bits of the stored PPN are meaningless; those bits come from the VPN instead.
    //   l=LEVELS-1 (4 KB page): use stored PPN directly.
    //   l=0        (largest superpage): replace bottom (LEVELS-1)*PAGE_LVL_BITS bits.

    // Each level's PPN assignment
    logic [PPN_SIZE-1:0] ppn_per_port_per_lvl   [NUM_TLB_PORTS] [LEVELS];
    logic [  LEVELS-1:0] hit_per_port_per_lvl   [NUM_TLB_PORTS];
    logic [PPN_SIZE-1:0] ppn_translated_per_port[NUM_TLB_PORTS];
    for (genvar port = 0; port < NUM_TLB_PORTS; ++port) begin : g_ppn_assignment

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
        assign tlb_core_comms_o[i].resp.xcpt.load  = xcpt_lds[i];
        assign tlb_core_comms_o[i].resp.xcpt.store = xcpt_sts[i];
        assign tlb_core_comms_o[i].resp.xcpt.fetch = xcpt_ifs[i];
        assign tlb_core_comms_o[i].resp.ppn        = ppn_translated_per_port[i];
        assign tlb_core_comms_o[i].resp.hit_idx    = 'h0;
    end

endmodule

`IGNORE_WARNINGS_END
