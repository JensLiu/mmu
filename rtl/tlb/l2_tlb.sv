
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

module l2_tlb
    import mmu_pkg::*;
#(
    parameter int unsigned NUM_TLB_PORTS = 1,
    parameter int unsigned TLB_ENTRIES   = 8
) (
    input logic clk_i,  // System clock signal.
    input logic rstn_i, // System reset signal (active low).

    // L1-L2 TLB interface
    input  l1_l2_comm_t l1_l2_comms_i[NUM_TLB_PORTS],  // Communication from L1 TLB to PTW/L2 TLB.
    output l2_l1_comm_t l2_l1_comms_o[NUM_TLB_PORTS],  // Communication from L1 TLB to PTW/L2 TLB.

    // PTW-L2 TLB interface
    output l2_ptw_comm_t l2_ptw_comm_o,  // Communication from L2 TLB to PTW.
    input  ptw_l2_comm_t ptw_l2_comm_i   // Communication from PTW to L2 TLB.
);

    // TODO: when multiple ports are hit, if SOME is write and should be written to dirty
    //       should be involked as well. NOT JUST MISSES

    localparam int unsigned TLB_IDX_SIZE = $clog2(TLB_ENTRIES);

    // Break combinational feedback from the PTW/L2 response path to request generation.
    ptw_l2_comm_t ptw_l2_comm_q;
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            ptw_l2_comm_q <= '0;
        end else begin
            ptw_l2_comm_q <= ptw_l2_comm_i;
        end
    end

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
    logic       [     VPN_SIZE-1:0] vpn_per_port      [NUM_TLB_PORTS];
    for (genvar i = 0; i < NUM_TLB_PORTS; ++i) begin : g_cam_logic
        assign tlb_storage_if.read_req[i].vpn = l1_l2_comms_i[i].req.vpn;
        assign tlb_storage_if.read_req[i].asid = l1_l2_comms_i[i].req.asid;
        assign hit_cam_per_port[i] = tlb_storage_if.read_resp[i].is_hit;
        assign hit_entry_per_port[i] = tlb_storage_if.read_resp[i].hit_entry;
        assign hit_level_per_port[i] = tlb_storage_if.read_resp[i].hit_level;
        assign hit_idx_per_port[i] = tlb_storage_if.read_resp[i].hit_idx;
        assign tlb_miss_per_port[i] = l1_l2_comms_i[i].req.valid && !(hit_cam_per_port[i]);
        assign vpn_per_port[i] = l1_l2_comms_i[i].req.vpn;
    end

    // -------------------------------------------------------------------------
    // Parallel TLB Hit/Miss logic
    // -------------------------------------------------------------------------
    // Parallel Hit logic
    logic tlb_hit_per_port  [NUM_TLB_PORTS];
    logic store_hit_per_port[NUM_TLB_PORTS];

    for (genvar port = 0; port < NUM_TLB_PORTS; ++port) begin : g_hit_logic

        // store_hit is forwarded from L1 TLB (computed by pte_perm_check there and passed via l1_l2_req_t)
        assign store_hit_per_port[port] = l1_l2_comms_i[port].req.store_hit;

        // These information are needed to update the Access and Dirty flags in the TLB entry
        // This should be combinational, since multiple ports may hit the same entry
        logic entry_no_access_bit, entry_no_dirty_bit;
        assign entry_no_access_bit = !hit_entry_per_port[port].access && hit_entry_per_port[port].valid;
        assign entry_no_dirty_bit = !store_hit_per_port[port] && hit_entry_per_port[port].valid;
        assign tlb_hit_per_port[port] = hit_cam_per_port[port] && store_hit_per_port[port];

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
    assign miss_grant_next = req_finished;

    logic tlb_hit, tlb_miss, store_hit, vm_enable, passthrough, hit_cam;
    tlb_entry_t                    hit_entry;
    logic       [TLB_IDX_SIZE-1:0] hit_idx;
    assign hit_entry   = tlb_hit_per_port[miss_port] ? hit_entry_per_port[miss_port] : '0;
    assign tlb_hit     = tlb_hit_per_port[miss_port];
    assign tlb_miss    = tlb_miss_per_port[miss_port];
    assign hit_idx     = hit_idx_per_port[miss_port];
    assign store_hit   = store_hit_per_port[miss_port];
    assign hit_cam     = hit_cam_per_port[miss_port];

    // Flush
    logic [TLB_ENTRIES-1:0] clear_mask;
    logic                   clear_tlb_req;
    always_comb begin
        clear_tlb  = 1'b0;
        clear_mask = '0;
        if (ptw_l2_comm_q.invalidate_tlb) begin
            clear_tlb  = 1'b1;
            clear_mask = 'hFF;
        end else if (clear_tlb_req) begin
            clear_tlb           = 1'b1;
            // Flush cam hit in a non-dirty page when store arrives
            clear_mask[hit_idx] = (hit_cam && !store_hit);
        end
    end

    // L2 Miss Request FSM
    logic write_tlb, clear_tlb, req_finished, req_inflight;
    ptw_req_fsm miss_req_fsm (
        .clk_i           (clk_i),
        .rstn_i          (rstn_i),
        // Input Flags
        .req_valid_i     (l1_l2_comms_i[miss_port].req.valid),
        .tlb_miss_i      (tlb_miss),
        .invalidate_tlb_i(ptw_l2_comm_q.invalidate_tlb),
        .rsp_valid_i     (ptw_l2_comm_q.resp.valid),
        // Output Flags
        .req_inflight_o  (req_inflight),
        .req_finished_o  (req_finished),
        .write_tlb_o     (write_tlb),
        .clear_tlb_o     (clear_tlb_req)
    );

    // Eviction / Victim Selection
    logic unsigned [TLB_IDX_SIZE-1:0] eviction_idx;
    eviction_policy #(
        .NUM_ENTRIES(TLB_ENTRIES)
    ) eviction_policy (
        .clk_i                  (clk_i),
        .rstn_i                 (rstn_i),
        .access_hit_i           (hit_cam),
        .access_idx_i           (hit_idx),
        .write_event_i          (write_tlb),
        .write_idx_i            (eviction_idx),
        .tlb_has_invalid_entry_i(tlb_storage_if.tlb_has_invalid_entry),
        .tlb_invalid_entry_idx_i(tlb_storage_if.tlb_invalid_entry_idx),
        .evict_idx_o            (eviction_idx)
    );

    // L1-L2 TLB send request
    always_comb begin
        // Problematic when always asserting the valid flag
        l2_ptw_comm_o.req.valid = req_inflight;
        l2_ptw_comm_o.req.vpn   = l1_l2_comms_i[miss_port].req.vpn[VPN_SIZE-1:0];
        l2_ptw_comm_o.req.asid  = l1_l2_comms_i[miss_port].req.asid;
        l2_ptw_comm_o.req.prv   = l1_l2_comms_i[miss_port].req.prv;
        l2_ptw_comm_o.req.store = l1_l2_comms_i[miss_port].req.store;
        l2_ptw_comm_o.req.fetch = l1_l2_comms_i[miss_port].req.fetch;
    end

    // TLB Storage communication
    assign tlb_storage_if.update_req.write_tlb = write_tlb;
    assign tlb_storage_if.update_req.write_idx = eviction_idx;
    assign tlb_storage_if.update_req.write_entry.vpn = l1_l2_comms_i[miss_port].req.vpn[VPN_SIZE-1:0];
    assign tlb_storage_if.update_req.write_entry.asid = l1_l2_comms_i[miss_port].req.asid;
    assign tlb_storage_if.update_req.write_entry.ppn = ptw_l2_comm_q.resp.pte.ppn;
    assign tlb_storage_if.update_req.write_entry.level = ptw_l2_comm_q.resp.level;
    assign tlb_storage_if.update_req.write_entry.dirty = ptw_l2_comm_q.resp.pte.d;
    assign tlb_storage_if.update_req.write_entry.access = ptw_l2_comm_q.resp.pte.a;
    assign tlb_storage_if.update_req.write_entry.perms.ur = ptw_l2_comm_q.resp.pte.r & ptw_l2_comm_q.resp.pte.u & ptw_l2_comm_q.resp.pte.v;
    assign tlb_storage_if.update_req.write_entry.perms.uw = ptw_l2_comm_q.resp.pte.w & ptw_l2_comm_q.resp.pte.u & ptw_l2_comm_q.resp.pte.v;
    assign tlb_storage_if.update_req.write_entry.perms.ux = ptw_l2_comm_q.resp.pte.x & ptw_l2_comm_q.resp.pte.u & ptw_l2_comm_q.resp.pte.v;
    assign tlb_storage_if.update_req.write_entry.perms.sr = ptw_l2_comm_q.resp.pte.r & !ptw_l2_comm_q.resp.pte.u & ptw_l2_comm_q.resp.pte.v;
    assign tlb_storage_if.update_req.write_entry.perms.sw = ptw_l2_comm_q.resp.pte.w & !ptw_l2_comm_q.resp.pte.u & ptw_l2_comm_q.resp.pte.v;
    assign tlb_storage_if.update_req.write_entry.perms.sx = ptw_l2_comm_q.resp.pte.x & !ptw_l2_comm_q.resp.pte.u & ptw_l2_comm_q.resp.pte.v;
    assign tlb_storage_if.update_req.write_entry.valid = !ptw_l2_comm_q.resp.error;
    assign tlb_storage_if.update_req.write_entry.nempty = 1'b1;
    assign tlb_storage_if.clear_req.clear_tlb = clear_tlb;
    assign tlb_storage_if.clear_req.clear_mask = clear_mask;

    // ---------------------------------------------------------
    // TLB Response
    // ---------------------------------------------------------
    for (genvar i = 0; i < NUM_TLB_PORTS; ++i) begin : g_tlb_resp
        // Not bypass implemented to simplify wiring
        // the PTW/L2 TLB response will update the TLB and we will find hit in the next cycle
        assign l2_l1_comms_o[i].resp.error = 1'b0;  // TODO: use error messages
        assign l2_l1_comms_o[i].resp.valid = !tlb_miss_per_port[i];
        assign l2_l1_comms_o[i].resp.tlb_entry = hit_entry_per_port[i];
        assign l2_l1_comms_o[i].invalidate_tlb = 1'b0;  // TODO: add invalidation
    end

endmodule

`IGNORE_WARNINGS_END
