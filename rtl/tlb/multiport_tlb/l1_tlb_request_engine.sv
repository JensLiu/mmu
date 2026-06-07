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
 */


// L1 TLB request + deliver engine.
//
// Receives every port's effective miss and request payload, arbitrates one
// miss at a time onto a single fire-once L2 walk, latches the in-flight
// {vpn,asid}, and on the L2 response either fills the CAM (success) or delivers
// a page fault to every coalesced requester (error).  There is only ever one
// walk outstanding, so a port whose effective miss matches the latched in-flight
// key is NOT re-walked (coalescing); the match also lets a fault reach all such
// ports even though nothing was written to the CAM.
//
// Why a fault needs explicit, acknowledged delivery: a successful translation is
// written to the CAM and is re-derivable every cycle, so it self-heals under
// backpressure.  A page fault has no CAM backing - it is a one-shot event.  So
// on an error response we capture the coalesced faulting ports into a bitmap,
// hold fault_valid_o for each until it is acknowledged via rsp_ready_i, and
// block the next walk until the bitmap drains.  (The core ties ready=1 today,
// so this drains in one cycle, but the handshake exists for correctness.)
//
//   PS_IDLE     -> PS_GET_MISS when the arbiter has a grant (and not draining)
//   PS_GET_MISS -> PS_SEND, latching the granted port
//   PS_SEND     -> PS_WAIT_RESPONSE on req fire; -> PS_IDLE on squash / TLBI
//   PS_WAIT_RESPONSE -> PS_IDLE + fill on a success response
//                    -> PS_FAULT_DRAIN on an error response
//                    -> PS_INVALIDATED_WAIT_RESPONSE on a TLBI
//   PS_FAULT_DRAIN -> PS_IDLE once every faulting port has acknowledged
//   PS_INVALIDATED_WAIT_RESPONSE -> PS_IDLE on response (drop the stale fill)
module l1_tlb_request_engine
    import mmu_pkg::*;
#(
    parameter  int unsigned NUM_TLB_PORTS = 1,
    localparam int unsigned PORT_IDX_W    = (NUM_TLB_PORTS > 1) ? $clog2(NUM_TLB_PORTS) : 1
) (
    input logic clk_i,
    input logic rstn_i,

    // Per-port effective miss + request payload. req_data_i[p].set_dirty_bit
    // carries this port's store-ness (used for the coalesced dirty walk).
    input logic                         [NUM_TLB_PORTS-1:0] eff_miss_i,
    input mmu_pkg::inter_tlb_req_data_t                     req_data_i[NUM_TLB_PORTS],

    // Fill into the CAM (success response only). vpn/asid come from the latched
    // in-flight request; the rest of the entry from the L2 response.
    output logic                       fill_valid_o,
    output tlb_entry_t                 fill_entry_o,
    output logic       [ VPN_SIZE-1:0] fill_vpn_o,
    output logic       [ASID_SIZE-1:0] fill_asid_o,

    input  logic [NUM_TLB_PORTS-1:0] rsp_ready_i,  // core ready to accept fault delivery
    // Per-port PTW page-fault delivery, held until acknowledged.
    output logic [NUM_TLB_PORTS-1:0] fault_valid_o,

    // Broadcast flush from L2 (registered).
    output logic invalidate_o,

    // Fire-once L2 link.
    inter_tlb_if.master l2_if
);

    // -------------------------------------------------------------------------
    // Request lifecycle FSM
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        PS_IDLE,
        PS_GET_MISS,
        PS_SEND,
        PS_WAIT_RESPONSE,
        PS_FAULT_DRAIN,
        PS_INVALIDATED_WAIT_RESPONSE
    } req_state_t;
    req_state_t req_state, req_state_n;

    // -------------------------------------------------------------------------
    // Miss arbiter: round-robin, sticky.  We accept a grant only while idle
    // (grant_ready), latch the winner in PS_GET_MISS, and hold it for the rest
    // of the transaction.  Sticky keeps grant_index stable on the granted port
    // until it stops missing (served / faulted+acked).
    // -------------------------------------------------------------------------
    logic [PORT_IDX_W-1:0] grant_index;
    logic                  grant_valid;
    wire                   grant_ready = (req_state == PS_IDLE);

    VX_generic_arbiter #(
        .NUM_REQS(NUM_TLB_PORTS),
        .TYPE    ("R"),
        .STICKY  (1)
    ) miss_arbiter (
        .clk        (clk_i),
        .reset      (~rstn_i),
        .requests   (eff_miss_i),
        `UNUSED_PIN(grant_onehot),
        .grant_index(grant_index),
        .grant_valid(grant_valid),
        .grant_ready(grant_ready)
    );

    // Latched granted port, valid from PS_SEND onwards.
    logic [PORT_IDX_W-1:0] port_idx_q;
    // Clamp for the single-port case (--x-initial can init a 1-bit reg to 1,
    // an out-of-bounds index before the synchronous reset takes effect).
    wire  [PORT_IDX_W-1:0] port_idx = (NUM_TLB_PORTS == 1) ? '0 : port_idx_q;

    // -------------------------------------------------------------------------
    // Register the L2 response. rsp_ready=1: the engine is one-outstanding, so
    // it always accepts the response it awaits. Registering breaks the comb
    // feedback from the response path back into request generation.
    // -------------------------------------------------------------------------
    assign l2_if.rsp_ready = 1'b1;
    logic                rsp_valid_q;
    inter_tlb_rsp_data_t rsp_data_q;
    logic                invalidate_q;
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            rsp_valid_q  <= 1'b0;
            invalidate_q <= 1'b0;
        end else begin
            rsp_valid_q  <= l2_if.rsp_valid;
            rsp_data_q   <= l2_if.rsp_data;
            invalidate_q <= l2_if.invalidate_tlb;
        end
    end
    assign invalidate_o = invalidate_q;
    wire                      rsp_error = rsp_data_q.error;

    // -------------------------------------------------------------------------
    // In-flight key: latched when the walk fires; used to coalesce same-VPN
    // ports and to route the fault to them.
    // -------------------------------------------------------------------------
    logic [     VPN_SIZE-1:0] inflight_vpn_q;
    logic [    ASID_SIZE-1:0] inflight_asid_q;

    logic [NUM_TLB_PORTS-1:0] inflight_match;
    for (genvar p = 0; p < NUM_TLB_PORTS; p++) begin : g_inflight_match
        assign inflight_match[p] = (req_data_i[p].vpn  == inflight_vpn_q)
                                && (req_data_i[p].asid == inflight_asid_q);
    end
    // Ports that are missing AND aliased to the in-flight walk = the fault set.
    wire  [NUM_TLB_PORTS-1:0] fault_match = eff_miss_i & inflight_match;

    // -------------------------------------------------------------------------
    // Outgoing L2 request
    // -------------------------------------------------------------------------
    logic                     l2_set_dirty; // coaleased dirty walk
    always_comb begin
        l2_set_dirty = 1'b0;
        for (int p = 0; p < NUM_TLB_PORTS; p++) begin
            if (eff_miss_i[p] && req_data_i[p].set_dirty_bit
                && (req_data_i[p].vpn  == req_data_i[port_idx].vpn)
                && (req_data_i[p].asid == req_data_i[port_idx].asid)) begin
                l2_set_dirty = 1'b1;
            end
        end
    end

    inter_tlb_req_data_t l2_req;
    always_comb begin
        l2_req               = req_data_i[port_idx];
        l2_req.set_dirty_bit = l2_set_dirty;
    end
    assign l2_if.req_data = l2_req;

    wire granted_miss = eff_miss_i[port_idx];
    wire req_fire = l2_if.req_valid && l2_if.req_ready;

    // Fault bitmap: who still owes us an acknowledgement.
    logic [NUM_TLB_PORTS-1:0] fault_pending, fault_pending_n;
    wire [NUM_TLB_PORTS-1:0] fault_ack = fault_valid_o & rsp_ready_i;
    wire                     fault_busy = |fault_pending;

    assign fault_valid_o = (req_state == PS_FAULT_DRAIN) ? fault_pending : '0;

    logic write_tlb;
    logic fault_capture;
    always_comb begin
        req_state_n   = req_state;
        write_tlb     = 1'b0;
        fault_capture = 1'b0;
        if (!rstn_i) begin
            req_state_n = PS_IDLE;
        end else begin
            case (req_state)
                PS_IDLE: begin
                    if (grant_valid && !fault_busy) req_state_n = PS_GET_MISS;
                end
                PS_GET_MISS: begin
                    req_state_n = PS_SEND;  // winner latched into port_idx_q
                end
                PS_SEND: begin
                    if (!granted_miss) begin
                        req_state_n = PS_IDLE;  // squashed before the fire
                    end else if (req_fire) begin
                        req_state_n = invalidate_q ?
                        PS_INVALIDATED_WAIT_RESPONSE : PS_WAIT_RESPONSE;
                    end else if (invalidate_q) begin
                        req_state_n = PS_IDLE;  // TLBI before the fire -> abort
                    end
                end
                PS_WAIT_RESPONSE: begin
                    if (rsp_valid_q) begin
                        if (rsp_error) begin
                            fault_capture = 1'b1;
                            req_state_n   = PS_FAULT_DRAIN;
                        end else begin
                            write_tlb   = 1'b1;
                            req_state_n = PS_IDLE;
                        end
                    end else if (invalidate_q) begin
                        req_state_n = PS_INVALIDATED_WAIT_RESPONSE;
                    end
                end
                PS_FAULT_DRAIN: begin
                    if (fault_pending_n == '0) begin
                        req_state_n = PS_IDLE;
                    end
                end
                PS_INVALIDATED_WAIT_RESPONSE: begin
                    if (rsp_valid_q) begin
                        req_state_n = PS_IDLE;
                    end
                end
                default: begin
                    req_state_n = PS_IDLE;
                end
            endcase
        end
    end

    // Capture the coalesced faulting set on the error response; drain by acks.
    // Late same-VPN arrivals are NOT folded in (they would re-assert eff_miss in
    // the same cycle they are acked and stall the drain); they simply re-walk
    // and re-fault after the engine returns to IDLE.
    always_comb begin
        if (fault_capture) begin
            fault_pending_n = fault_match;
        end else if (req_state == PS_FAULT_DRAIN) begin
            fault_pending_n = fault_pending & ~fault_ack;
        end else begin
            fault_pending_n = '0;
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            req_state     <= PS_IDLE;
            fault_pending <= '0;
            port_idx_q    <= '0;
        end else begin
            req_state     <= req_state_n;
            fault_pending <= fault_pending_n;
            if (req_state == PS_GET_MISS) begin
                port_idx_q <= grant_index;
            end
        end
    end

    // Latch the in-flight key when the walk fires.
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            inflight_vpn_q  <= '0;
            inflight_asid_q <= '0;
        end else if (req_fire) begin
            inflight_vpn_q  <= l2_req.vpn;
            inflight_asid_q <= l2_req.asid;
        end
    end

    // Present the request once, only while in PS_SEND.
    assign l2_if.req_valid = (req_state == PS_SEND);

    // Fill (success response only).
    assign fill_valid_o    = write_tlb;
    assign fill_entry_o    = rsp_data_q.tlb_entry;
    assign fill_vpn_o      = inflight_vpn_q;
    assign fill_asid_o     = inflight_asid_q;

endmodule

