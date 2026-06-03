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

`IGNORE_WARNINGS_BEGIN

// L1 TLB request engine: turns the CAM's per-port miss queries into a single
// fire-once L2 request, and hands the fill back to the CAM.  It hides the miss
// serialiser, the request lifecycle FSM (which owns the L2 handshake - this is
// what used to be l2_req_fsm plus the l1_l2_adapter's sent_q), and the response
// register, so the CAM datapath only sees "miss in / fill out".
//
//   PS_IDLE  -> PS_SEND on the granted port's miss; present req_valid
//   PS_SEND  -> PS_WAIT_RESPONSE on req_ready (the request fires);
//               -> PS_IDLE if the core squashes or a TLBI arrives before the fire
//   PS_WAIT_RESPONSE -> PS_IDLE on rsp_valid (fill the CAM);
//                       -> PS_INVALIDATED_WAIT_RESPONSE on a TLBI
//   PS_INVALIDATED_WAIT_RESPONSE -> PS_IDLE on rsp_valid (drop the stale fill)
//
// req_valid is driven from current_state (PS_SEND), never next_state: presenting
// it in the IDLE-with-miss cycle could fire before the FSM records the send and
// re-present the request next cycle (a duplicate walk).
module l1_tlb_request_engine
    import mmu_pkg::*;
#(
    parameter  int unsigned NUM_TLB_PORTS = 1,
    localparam int unsigned PORT_IDX_W    = (NUM_TLB_PORTS > 1) ? $clog2(NUM_TLB_PORTS) : 1
) (
    input logic clk_i,
    input logic rstn_i,

    // Per-port miss queries + L2 request payload (from the CAM datapath).
    input logic [NUM_TLB_PORTS-1:0] req_valid_i,  // core request valid, per port
    input logic [NUM_TLB_PORTS-1:0] tlb_miss_i,   // CAM miss, per port
    input l1_l2_req_data_t          req_data_i [NUM_TLB_PORTS],

    // Control back to the CAM datapath.
    output logic [PORT_IDX_W-1:0] active_port_o,  // granted port (stable SEND..WAIT)
    output logic                  clear_req_o,    // IDLE+req: enable store-to-clean clear
    output logic                  fill_valid_o,   // write the CAM this cycle
    output l2_l1_rsp_data_t       fill_data_o,    // the (registered) L2 response
    output logic                  invalidate_o,   // broadcast flush (registered)

    // Fire-once L2 link
    l1_l2_if.l1 l2_if
);

    // -------------------------------------------------------------------------
    // Miss serialiser: pick one missing port, hold the grant until req_finished
    // so the presented request data is stable across the whole SEND+WAIT span.
    // -------------------------------------------------------------------------
    logic                  miss_grant_next;
    logic                  miss_active;
    logic [PORT_IDX_W-1:0] miss_port_raw;
    request_serialiser #(
        .NUM_PORTS(NUM_TLB_PORTS)
    ) serialiser (
        .clk_i       (clk_i),
        .rstn_i      (rstn_i),
        .tlb_misses_i(tlb_miss_i),
        .grant_next_i(miss_grant_next),
        .active_o    (miss_active),
        .active_idx_o(miss_port_raw)
    );

    // Clamp for the single-port case (--x-initial unique can init a 1-bit reg to 1,
    // an out-of-bounds index before the synchronous reset takes effect).
    logic [PORT_IDX_W-1:0] port_idx;
    assign port_idx      = (NUM_TLB_PORTS == 1) ? '0 : miss_port_raw;
    assign active_port_o = port_idx;

    // -------------------------------------------------------------------------
    // Register the L2 response: captures the fire-once fill, breaks the comb
    // feedback from the response path to request generation. rsp_ready=1 - the
    // engine is one-outstanding, so it always accepts the response it awaits.
    // -------------------------------------------------------------------------
    assign l2_if.rsp_ready = 1'b1;
    logic            rsp_valid_q;
    l2_l1_rsp_data_t rsp_data_q;
    logic            invalidate_q;
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
    assign fill_data_o  = rsp_data_q;
    assign invalidate_o = invalidate_q;

    // -------------------------------------------------------------------------
    // Request lifecycle FSM
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        PS_IDLE,
        PS_SEND,
        PS_WAIT_RESPONSE,
        PS_INVALIDATED_WAIT_RESPONSE
    } req_state_t;
    req_state_t req_state, req_state_n;

    wire core_req_valid = req_valid_i[port_idx];
    wire selected_miss  = tlb_miss_i[port_idx];
    wire req_fire       = l2_if.req_valid && l2_if.req_ready;

    logic write_tlb;
    always_comb begin
        req_state_n = req_state;
        write_tlb   = 1'b0;
        if (!rstn_i) begin
            req_state_n = PS_IDLE;
        end else begin
            case (req_state)
                PS_IDLE:
                    if (core_req_valid && selected_miss) req_state_n = PS_SEND;
                PS_SEND:
                    if (!core_req_valid)   req_state_n = PS_IDLE;  // squashed before the fire
                    else if (req_fire)     req_state_n = invalidate_q ? PS_INVALIDATED_WAIT_RESPONSE
                                                                      : PS_WAIT_RESPONSE;
                    else if (invalidate_q) req_state_n = PS_IDLE;  // TLBI before the fire -> abort
                PS_WAIT_RESPONSE:
                    if (rsp_valid_q) begin
                        write_tlb   = 1'b1;
                        req_state_n = PS_IDLE;
                    end else if (invalidate_q) req_state_n = PS_INVALIDATED_WAIT_RESPONSE;
                PS_INVALIDATED_WAIT_RESPONSE:
                    if (rsp_valid_q) req_state_n = PS_IDLE;
                default: req_state_n = PS_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) req_state <= PS_IDLE;
        else         req_state <= req_state_n;
    end

    // Release the grant exactly when the FSM returns to IDLE.
    assign miss_grant_next = (req_state != PS_IDLE) && (req_state_n == PS_IDLE);

    // Present the request once, only while in PS_SEND.
    assign l2_if.req_valid = (req_state == PS_SEND);
    assign l2_if.req_data  = req_data_i[port_idx];

    assign clear_req_o  = (req_state == PS_IDLE) && core_req_valid;
    assign fill_valid_o = write_tlb;

endmodule

`IGNORE_WARNINGS_END
