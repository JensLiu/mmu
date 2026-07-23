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

module l1_tlb_request_engine
    import mmu_pkg::*;
#(
    parameter  int unsigned NUM_TLB_PORTS = 1,
    localparam int unsigned PORT_IDX_WIDTH    = (NUM_TLB_PORTS > 1) ? $clog2(NUM_TLB_PORTS) : 1
) (
    input logic clk_i,
    input logic rst_i,

    input logic                         [NUM_TLB_PORTS-1:0] eff_miss_i,
    input mmu_pkg::inter_tlb_req_data_t                     req_data_i[NUM_TLB_PORTS],

    output logic                       fill_valid_o,
    output tlb_entry_t                 fill_entry_o,
    output logic       [ VPN_WIDTH-1:0] fill_vpn_o,
    output logic       [ASID_WIDTH-1:0] fill_asid_o,

    input  logic [NUM_TLB_PORTS-1:0] rsp_ready_i,  // core ready to accept fault delivery
    output logic [NUM_TLB_PORTS-1:0] fault_valid_o,

    // Broadcast flush from L2 (registered).
    output logic invalidate_o,

    inter_tlb_if.master l2_if
);

    typedef enum logic [2:0] {
        S_IDLE,
        S_GET_MISS,
        S_SEND,
        S_WAIT_RESPONSE,
        S_FAULT_DRAIN,
        S_INVALIDATED_WAIT_RESPONSE
    } req_state_t;
    req_state_t req_state, req_state_n;

    // -------------------------------------------------------------------------
    // Miss arbiter
    // -------------------------------------------------------------------------
    logic [PORT_IDX_WIDTH-1:0] grant_index;
    logic                  grant_valid;
    wire                   grant_ready = (req_state == S_IDLE);

    VX_generic_arbiter #(
        .NUM_REQS(NUM_TLB_PORTS),
        .TYPE    ("R"),
        .STICKY  (1)
    ) miss_arbiter (
        .clk        (clk_i),
        .reset      (rst_i),
        .requests   (eff_miss_i),
        `UNUSED_PIN(grant_onehot),
        .grant_index(grant_index),
        .grant_valid(grant_valid),
        .grant_ready(grant_ready)
    );

    logic [PORT_IDX_WIDTH-1:0] port_idx_r;
    // Clamp for the single-port case (--x-initial can init a 1-bit reg to 1,
    // an out-of-bounds index before the synchronous reset takes effect).
    wire  [PORT_IDX_WIDTH-1:0] port_idx = (NUM_TLB_PORTS == 1) ? '0 : port_idx_r;

    // -------------------------------------------------------------------------
    // Register the L2 response
    // -------------------------------------------------------------------------
    assign l2_if.rsp_ready = 1'b1;
    logic                rsp_valid_r;
    mmu_pkg::inter_tlb_rsp_data_t rsp_data_r;
    logic                invalidate_r;
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            rsp_valid_r  <= 1'b0;
            invalidate_r <= 1'b0;
        end else begin
            rsp_valid_r  <= l2_if.rsp_valid;
            rsp_data_r   <= l2_if.rsp_data;
            invalidate_r <= l2_if.invalidate_tlb;
        end
    end
    assign invalidate_o = invalidate_r;
    wire                      rsp_error = rsp_data_r.error;

    // -------------------------------------------------------------------------
    // In-flight key
    // -------------------------------------------------------------------------
    logic [     VPN_WIDTH-1:0] inflight_vpn_r;
    logic [    ASID_WIDTH-1:0] inflight_asid_r;

    logic [NUM_TLB_PORTS-1:0] inflight_match;
    for (genvar p = 0; p < NUM_TLB_PORTS; p++) begin : g_inflight_match
        assign inflight_match[p] = (req_data_i[p].vpn  == inflight_vpn_r)
                                && (req_data_i[p].asid == inflight_asid_r);
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
            if (eff_miss_i[p] && req_data_i[p].set_dirty
                && (req_data_i[p].vpn  == req_data_i[port_idx].vpn)
                && (req_data_i[p].asid == req_data_i[port_idx].asid)) begin
                l2_set_dirty = 1'b1;
            end
        end
    end

    inter_tlb_req_data_t l2_req;
    always_comb begin
        l2_req               = req_data_i[port_idx];
        l2_req.set_dirty = l2_set_dirty;
    end
    assign l2_if.req_data = l2_req;

    wire granted_miss = eff_miss_i[port_idx];
    wire req_fire = l2_if.req_valid && l2_if.req_ready;

    // Fault bitmap: who still owes us an acknowledgement.
    logic [NUM_TLB_PORTS-1:0] fault_pending, fault_pending_n;
    wire [NUM_TLB_PORTS-1:0] fault_ack = fault_valid_o & rsp_ready_i;
    wire                     fault_busy = |fault_pending;

    assign fault_valid_o = (req_state == S_FAULT_DRAIN) ? fault_pending : '0;

    logic write_tlb;
    logic fault_capture;
    always_comb begin
        req_state_n   = req_state;
        write_tlb     = 1'b0;
        fault_capture = 1'b0;
        if (rst_i) begin
            req_state_n = S_IDLE;
        end else begin
            case (req_state)
                S_IDLE: begin
                    if (grant_valid && !fault_busy) req_state_n = S_GET_MISS;
                end
                S_GET_MISS: begin
                    req_state_n = S_SEND;  // winner latched into port_idx_r
                end
                S_SEND: begin
                    if (!granted_miss) begin
                        req_state_n = S_IDLE;  // squashed before the fire
                    end else if (req_fire) begin
                        req_state_n = invalidate_r ?
                        S_INVALIDATED_WAIT_RESPONSE : S_WAIT_RESPONSE;
                    end else if (invalidate_r) begin
                        req_state_n = S_IDLE;  // TLBI before the fire -> abort
                    end
                end
                S_WAIT_RESPONSE: begin
                    if (rsp_valid_r) begin
                        if (rsp_error) begin
                            fault_capture = 1'b1;
                            req_state_n   = S_FAULT_DRAIN;
                        end else begin
                            write_tlb   = 1'b1;
                            req_state_n = S_IDLE;
                        end
                    end else if (invalidate_r) begin
                        req_state_n = S_INVALIDATED_WAIT_RESPONSE;
                    end
                end
                S_FAULT_DRAIN: begin
                    if (fault_pending_n == '0) begin
                        req_state_n = S_IDLE;
                    end
                end
                S_INVALIDATED_WAIT_RESPONSE: begin
                    if (rsp_valid_r) begin
                        req_state_n = S_IDLE;
                    end
                end
                default: begin
                    req_state_n = S_IDLE;
                end
            endcase
        end
    end

    always_comb begin
        if (fault_capture) begin
            fault_pending_n = fault_match;
        end else if (req_state == S_FAULT_DRAIN) begin
            fault_pending_n = fault_pending & ~fault_ack;
        end else begin
            fault_pending_n = '0;
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            req_state     <= S_IDLE;
            fault_pending <= '0;
            port_idx_r    <= '0;
        end else begin
            req_state     <= req_state_n;
            fault_pending <= fault_pending_n;
            if (req_state == S_GET_MISS) begin
                port_idx_r <= grant_index;
            end
        end
    end

    // Latch the in-flight key when the walk fires.
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            inflight_vpn_r  <= '0;
            inflight_asid_r <= '0;
        end else if (req_fire) begin
            inflight_vpn_r  <= l2_req.vpn;
            inflight_asid_r <= l2_req.asid;
        end
    end

    // Present the request once, only while in S_SEND.
    assign l2_if.req_valid = (req_state == S_SEND);

    // Fill (success response only).
    assign fill_valid_o    = write_tlb;
    assign fill_entry_o    = rsp_data_r.tlb_entry;
    assign fill_vpn_o      = inflight_vpn_r;
    assign fill_asid_o     = inflight_asid_r;

endmodule

