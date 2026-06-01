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

module l2_tlb_bank
    import mmu_pkg::*;
#(
    parameter int unsigned SRC_W       = 1,   // = LOG2UP(NUM_REQS)
    parameter int unsigned TLB_ENTRIES = 8
) (
    input logic clk_i,  // System clock signal.
    input logic rstn_i, // System reset signal (active low).

    // Request in (fire-once, from the request xbar output)
    input  logic                        req_valid_i,
    output logic                        req_ready_o,
    input  l1_l2_req_data_t             req_data_i,
    input  logic            [SRC_W-1:0] req_src_i,    // origin L1 (xbar sel_out)

    // Response out (fire-once, to the response xbar input)
    output logic                        rsp_valid_o,
    input  logic                        rsp_ready_i,
    output l2_l1_rsp_data_t             rsp_data_o,
    output logic            [SRC_W-1:0] rsp_src_o,    // threaded → rsp xbar sel_in

    //  PTW master
    output l2_ptw_comm_t l2_ptw_comm_o,
    input  ptw_l2_comm_t ptw_l2_comm_i
);

    localparam int unsigned TLB_IDX_SIZE = $clog2(TLB_ENTRIES);

    // -------------------------------------------------------------------------
    // Store (single read port - the bank serves one request at a time)
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

    // -------------------------------------------------------------------------
    // Combinational probe on the incoming request (only sampled on a req fire)
    // -------------------------------------------------------------------------
    assign tlb_storage_if.read_req[0].vpn  = req_data_i.vpn;
    assign tlb_storage_if.read_req[0].asid = req_data_i.asid;

    wire                    cam_hit   = tlb_storage_if.read_resp[0].is_hit;
    tlb_entry_t             hit_entry;
    logic [TLB_IDX_SIZE-1:0] hit_idx;
    assign hit_entry = tlb_storage_if.read_resp[0].hit_entry;
    assign hit_idx   = tlb_storage_if.read_resp[0].hit_idx;
    // store_hit is computed in the L1 (pte_perm_check) and forwarded.
    wire                    store_ok  = req_data_i.store_hit;
    wire                    eff_hit   = cam_hit && store_ok;

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE,
        S_WAIT_PTW,
        S_RESP
    } state_t;

    state_t           state_q, state_n;
    l1_l2_req_data_t  req_q;     // latched request (PTW fields + store write vpn/asid)
    logic [SRC_W-1:0] src_q;     // latched source id
    l2_l1_rsp_data_t  rsp_q;     // latched response to present

    wire req_fire = req_valid_i && req_ready_o;
    wire rsp_fire = rsp_valid_o && rsp_ready_i;
    wire ptw_done = (state_q == S_WAIT_PTW) && ptw_l2_comm_i.resp.valid;

    // PTW result -> L1 response. vpn/asid are filled by the L1 from its own
    // request when it writes its CAM, so they are left zero here.
    l2_l1_rsp_data_t ptw_as_rsp;
    always_comb begin
        ptw_as_rsp = '0;
        ptw_as_rsp.error = ptw_l2_comm_i.resp.error;
        ptw_as_rsp.tlb_entry.ppn = ptw_l2_comm_i.resp.pte.ppn;
        ptw_as_rsp.tlb_entry.level = 2'(ptw_l2_comm_i.resp.level);
        ptw_as_rsp.tlb_entry.dirty = ptw_l2_comm_i.resp.pte.d;
        ptw_as_rsp.tlb_entry.access = ptw_l2_comm_i.resp.pte.a;
        ptw_as_rsp.tlb_entry.perms.ur = ptw_l2_comm_i.resp.pte.r &  ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
        ptw_as_rsp.tlb_entry.perms.uw = ptw_l2_comm_i.resp.pte.w &  ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
        ptw_as_rsp.tlb_entry.perms.ux = ptw_l2_comm_i.resp.pte.x &  ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
        ptw_as_rsp.tlb_entry.perms.sr = ptw_l2_comm_i.resp.pte.r & ~ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
        ptw_as_rsp.tlb_entry.perms.sw = ptw_l2_comm_i.resp.pte.w & ~ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
        ptw_as_rsp.tlb_entry.perms.sx = ptw_l2_comm_i.resp.pte.x & ~ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
        ptw_as_rsp.tlb_entry.valid = ptw_l2_comm_i.resp.valid & ~ptw_l2_comm_i.resp.error;
        ptw_as_rsp.tlb_entry.nempty = ptw_l2_comm_i.resp.valid;
    end

    // Hit response (cached entry returned directly).
    l2_l1_rsp_data_t hit_rsp;
    always_comb begin
        hit_rsp           = '0;
        hit_rsp.error     = 1'b0;
        hit_rsp.tlb_entry = hit_entry;
    end

    always_comb begin
        state_n = state_q;
        if (!rstn_i) begin
            state_n = S_IDLE;
        end else begin
            unique case (state_q)
                S_IDLE:     if (req_fire) state_n = eff_hit ? S_RESP : S_WAIT_PTW;
                S_WAIT_PTW: if (ptw_l2_comm_i.resp.valid) state_n = S_RESP;
                S_RESP:     if (rsp_fire) state_n = S_IDLE;
                default:    state_n = S_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            state_q <= S_IDLE;
            req_q   <= '0;
            src_q   <= '0;
            rsp_q   <= '0;
        end else begin
            state_q <= state_n;
            if (req_fire) begin
                req_q <= req_data_i;
                src_q <= req_src_i;
                if (eff_hit) rsp_q <= hit_rsp;   // L2 hit: respond from the cache
            end
            if (ptw_done) begin
                rsp_q <= ptw_as_rsp;             // miss resolved: respond from the walk
            end
        end
    end

    // -------------------------------------------------------------------------
    // Eviction (NRU). Single hit port.
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
    // Store updates: fill on a completed walk; flush on invalidate or on a
    // store to a clean (non-dirty) hit (forces a re-walk to set the dirty bit).
    // -------------------------------------------------------------------------
    assign write_tlb = ptw_done;

    logic [TLB_ENTRIES-1:0] clear_mask;
    logic                   clear_tlb;
    always_comb begin
        clear_tlb  = 1'b0;
        clear_mask = '0;
        if (ptw_l2_comm_i.invalidate_tlb) begin
            clear_tlb  = 1'b1;
            clear_mask = {TLB_ENTRIES{1'b1}};
        end else if (req_fire && cam_hit && !store_ok) begin
            clear_tlb           = 1'b1;
            clear_mask[hit_idx] = 1'b1;   // drop the clean entry; the walk re-fills it dirty
        end
    end

    assign tlb_storage_if.update_req.write_tlb        = write_tlb;
    assign tlb_storage_if.update_req.write_idx        = eviction_idx;
    assign tlb_storage_if.update_req.write_entry.vpn  = req_q.vpn;
    assign tlb_storage_if.update_req.write_entry.asid = req_q.asid;
    assign tlb_storage_if.update_req.write_entry.ppn     = ptw_l2_comm_i.resp.pte.ppn;
    assign tlb_storage_if.update_req.write_entry.level   = ptw_l2_comm_i.resp.level;
    assign tlb_storage_if.update_req.write_entry.dirty   = ptw_l2_comm_i.resp.pte.d;
    assign tlb_storage_if.update_req.write_entry.access  = ptw_l2_comm_i.resp.pte.a;
    assign tlb_storage_if.update_req.write_entry.perms.ur = ptw_l2_comm_i.resp.pte.r &  ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
    assign tlb_storage_if.update_req.write_entry.perms.uw = ptw_l2_comm_i.resp.pte.w &  ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
    assign tlb_storage_if.update_req.write_entry.perms.ux = ptw_l2_comm_i.resp.pte.x &  ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
    assign tlb_storage_if.update_req.write_entry.perms.sr = ptw_l2_comm_i.resp.pte.r & ~ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
    assign tlb_storage_if.update_req.write_entry.perms.sw = ptw_l2_comm_i.resp.pte.w & ~ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
    assign tlb_storage_if.update_req.write_entry.perms.sx = ptw_l2_comm_i.resp.pte.x & ~ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
    assign tlb_storage_if.update_req.write_entry.valid    = !ptw_l2_comm_i.resp.error;
    assign tlb_storage_if.update_req.write_entry.nempty   = 1'b1;
    assign tlb_storage_if.clear_req.clear_tlb  = clear_tlb;
    assign tlb_storage_if.clear_req.clear_mask = clear_mask;

    // -------------------------------------------------------------------------
    // Outputs
    // -------------------------------------------------------------------------
    assign req_ready_o = (state_q == S_IDLE);

    // PTW request held stable while the walk is in flight.
    always_comb begin
        l2_ptw_comm_o = '0;
        if (state_q == S_WAIT_PTW) begin
            l2_ptw_comm_o.req.valid = 1'b1;
            l2_ptw_comm_o.req.vpn   = req_q.vpn;
            l2_ptw_comm_o.req.asid  = req_q.asid;
            l2_ptw_comm_o.req.prv   = req_q.prv;
            l2_ptw_comm_o.req.store = req_q.store;
            l2_ptw_comm_o.req.fetch = req_q.fetch;
        end
    end

    assign rsp_valid_o = (state_q == S_RESP);
    assign rsp_data_o  = rsp_q;
    assign rsp_src_o   = src_q;

endmodule

`IGNORE_WARNINGS_END
