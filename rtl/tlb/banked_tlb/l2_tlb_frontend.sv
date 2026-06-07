/*
 * Copyright 2026 BSC*
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


module l2_tlb_frontend
    import mmu_pkg::*;
#(
    parameter int unsigned NUM_REQS  = 1,
    parameter int unsigned NUM_BANKS = 1,
    parameter int unsigned NUM_PTWS  = 1
) (
    input logic clk_i,  // System clock signal.
    input logic rstn_i, // System reset signal (active low).

    // L1-L2 TLB interface (one fire-once link per L1)
    inter_tlb_if.slave l1_l2_if[NUM_REQS],
    ptw_if.master      ptw_if  [NUM_PTWS]
);

    localparam int unsigned SRC_SEL_W = (NUM_REQS > 1) ? $clog2(NUM_REQS) : 1;
    localparam int unsigned BANK_SEL_W = (NUM_BANKS > 1) ? $clog2(NUM_BANKS) : 1;
    localparam int unsigned REQ_W = $bits(inter_tlb_req_data_t);
    localparam int unsigned RSP_W = $bits(inter_tlb_rsp_data_t);

    // VPN -> bank. Constant 0 for a single bank; low-bit map as a placeholder for
    // multi-bank (replace with an XOR-fold over page-size-invariant bits).
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [BANK_SEL_W-1:0] bank_sel(input logic [VPN_SIZE-1:0] vpn);
        bank_sel = (NUM_BANKS == 1) ? '0 : vpn[BANK_SEL_W-1:0];
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------------------------
    // Source-side packing (interface -> flat buses)
    // -------------------------------------------------------------------------
    logic [NUM_REQS-1:0]                 src_req_valid;
    logic [NUM_REQS-1:0]                 src_req_ready;
    logic [NUM_REQS-1:0][     REQ_W-1:0] src_req_data;
    logic [NUM_REQS-1:0][BANK_SEL_W-1:0] src_bank_sel;

    logic [NUM_REQS-1:0]                 src_rsp_valid;
    logic [NUM_REQS-1:0]                 src_rsp_ready;
    logic [NUM_REQS-1:0][     RSP_W-1:0] src_rsp_data;

    for (genvar i = 0; i < NUM_REQS; ++i) begin : g_src
        assign src_req_valid[i]           = l1_l2_if[i].req_valid;
        assign src_req_data[i]            = l1_l2_if[i].req_data;
        assign src_bank_sel[i]            = bank_sel(l1_l2_if[i].req_data.vpn);
        assign l1_l2_if[i].req_ready      = src_req_ready[i];

        assign l1_l2_if[i].rsp_valid      = src_rsp_valid[i];
        assign l1_l2_if[i].rsp_data       = mmu_pkg::inter_tlb_rsp_data_t'(src_rsp_data[i]);
        assign src_rsp_ready[i]           = l1_l2_if[i].rsp_ready;

        // Broadcast flush to every L1 (not request-matched). All PTWs carry the
        // same CSR flush, so any one of them is representative.
        assign l1_l2_if[i].invalidate_tlb = ptw_if[0].invalidate_tlb;
    end

    // -------------------------------------------------------------------------
    // Request routing: sources -> banks (sel = bank_sel(vpn))
    // -------------------------------------------------------------------------
    logic [NUM_BANKS-1:0]                bank_req_valid;
    logic [NUM_BANKS-1:0]                bank_req_ready;
    logic [NUM_BANKS-1:0][    REQ_W-1:0] bank_req_data;
    logic [NUM_BANKS-1:0][SRC_SEL_W-1:0] bank_src_id;  // sel_out: which L1 each bank serves

    VX_stream_xbar #(
        .NUM_INPUTS (NUM_REQS),
        .NUM_OUTPUTS(NUM_BANKS),
        .DATAW      (REQ_W),
        .ARBITER    ("R"),
        .OUT_BUF    (2)           // per-bank capture / skid buffer
    ) req_xbar (
        .clk      (clk_i),
        .reset    (~rstn_i),
        .valid_in (src_req_valid),
        .data_in  (src_req_data),
        .sel_in   (src_bank_sel),
        .ready_in (src_req_ready),
        .valid_out(bank_req_valid),
        .data_out (bank_req_data),
        .sel_out  (bank_src_id),
        .ready_out(bank_req_ready),
        `UNUSED_PIN(collisions)
    );

    // -------------------------------------------------------------------------
    // Banks
    // -------------------------------------------------------------------------
    logic [NUM_BANKS-1:0]                bank_rsp_valid;
    logic [NUM_BANKS-1:0]                bank_rsp_ready;
    logic [NUM_BANKS-1:0][    RSP_W-1:0] bank_rsp_data;
    logic [NUM_BANKS-1:0][SRC_SEL_W-1:0] bank_rsp_src;  // threaded src id -> rsp sel_in

    ptw_if bank_ptw[NUM_BANKS] ();

    for (genvar b = 0; b < NUM_BANKS; ++b) begin : g_banks
        mmu_pkg::inter_tlb_rsp_data_t bank_rsp_struct;

        l2_tlb_bank #(
            .SRC_W   (SRC_SEL_W),
            .NUM_SRCS(NUM_REQS)
        ) tlb_bank (
            .clk_i      (clk_i),
            .rstn_i     (rstn_i),
            .req_valid_i(bank_req_valid[b]),
            .req_ready_o(bank_req_ready[b]),
            .req_data_i (inter_tlb_req_data_t'(bank_req_data[b])),
            .req_src_i  (bank_src_id[b]),
            .rsp_valid_o(bank_rsp_valid[b]),
            .rsp_ready_i(bank_rsp_ready[b]),
            .rsp_data_o (bank_rsp_struct),
            .rsp_src_o  (bank_rsp_src[b]),
            .ptw_if     (bank_ptw[b])
        );

        assign bank_rsp_data[b] = bank_rsp_struct;
    end

    ptw_scheduler #(
        .NUM_BANKS(NUM_BANKS),
        .NUM_PTWS (NUM_PTWS)
    ) ptw_scheduler (
        .clk_i    (clk_i),
        .rstn_i   (rstn_i),
        .bank_reqs(bank_ptw),
        .ptw_reqs (ptw_if)
    );

    // -------------------------------------------------------------------------
    // Response routing: banks -> sources (sel = threaded src id)
    // -------------------------------------------------------------------------
    VX_stream_xbar #(
        .NUM_INPUTS (NUM_BANKS),
        .NUM_OUTPUTS(NUM_REQS),
        .DATAW      (RSP_W),
        .ARBITER    ("R"),
        .OUT_BUF    (2)
    ) rsp_xbar (
        .clk      (clk_i),
        .reset    (~rstn_i),
        .valid_in (bank_rsp_valid),
        .data_in  (bank_rsp_data),
        .sel_in   (bank_rsp_src),
        .ready_in (bank_rsp_ready),
        .valid_out(src_rsp_valid),
        .data_out (src_rsp_data),
        `UNUSED_PIN(sel_out),
        .ready_out(src_rsp_ready),
        `UNUSED_PIN(collisions)
    );

endmodule
