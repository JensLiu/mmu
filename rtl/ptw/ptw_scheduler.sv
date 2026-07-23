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

module ptw_scheduler #(
    parameter  int unsigned NUM_BANKS          = 1,
    parameter  int unsigned NUM_PTWS           = 1,
    localparam int unsigned BANK_ID_WIDTH      = (NUM_BANKS > 1) ? $clog2(NUM_BANKS) : 1,
    localparam int unsigned PTW_ID_WIDTH       = (NUM_PTWS > 1) ? $clog2(NUM_PTWS) : 1,
    localparam int unsigned PTW_TAG_BANK_WIDTH = mmu_pkg::PTW_TAG_BANK_WIDTH
) (
    input logic clk_i,
    input logic rst_i,

    inter_tlb_if.slave  bank_reqs[NUM_BANKS],
    inter_tlb_if.master ptw_reqs [ NUM_PTWS]
);

    // -------------------------------------------------------------------------
    // Unpack the interface arrays into flat vectors (dynamic indexing needs this)
    // -------------------------------------------------------------------------
    logic [NUM_BANKS-1:0] bank_req_valid, bank_req_ready;
    mmu_pkg::inter_tlb_req_data_t [NUM_BANKS-1:0] bank_req_data;
    mmu_pkg::ptw_tag_t [NUM_BANKS-1:0] bank_req_tags;

    logic [NUM_BANKS-1:0] bank_rsp_valid, bank_rsp_ready;
    mmu_pkg::inter_tlb_rsp_data_t [NUM_BANKS-1:0] bank_rsp_data;
    mmu_pkg::ptw_tag_t [NUM_BANKS-1:0] bank_rsp_tags;

    logic [NUM_PTWS-1:0] ptw_req_valid, ptw_req_ready;
    mmu_pkg::inter_tlb_req_data_t [NUM_PTWS-1:0] ptw_req_data;
    mmu_pkg::ptw_tag_t [NUM_PTWS-1:0] ptw_req_tags;

    logic [NUM_PTWS-1:0] ptw_rsp_valid, ptw_rsp_ready;
    mmu_pkg::inter_tlb_rsp_data_t [NUM_PTWS-1:0] ptw_rsp_data;
    mmu_pkg::ptw_tag_t [NUM_PTWS-1:0] ptw_rsp_tags;

    logic                   [NUM_PTWS-1:0] ptw_invalidate;

    for (genvar b = 0; b < NUM_BANKS; b++) begin : g_bank
        assign bank_req_valid[b]           = bank_reqs[b].req_valid;
        assign bank_req_data[b]            = bank_reqs[b].req_data;
        assign bank_req_tags[b]            = bank_reqs[b].req_tag;
        assign bank_reqs[b].req_ready      = bank_req_ready[b];
        assign bank_reqs[b].rsp_valid      = bank_rsp_valid[b];
        assign bank_reqs[b].rsp_data       = bank_rsp_data[b];
        assign bank_reqs[b].rsp_tag        = bank_rsp_tags[b];
        assign bank_rsp_ready[b]           = bank_reqs[b].rsp_ready;
        assign bank_reqs[b].invalidate_tlb = |ptw_invalidate;  // broadcast CSR flush
    end

    for (genvar p = 0; p < NUM_PTWS; p++) begin : g_ptw
        assign ptw_req_ready[p]      = ptw_reqs[p].req_ready;
        assign ptw_reqs[p].req_valid = ptw_req_valid[p];
        assign ptw_reqs[p].req_data  = ptw_req_data[p];
        assign ptw_reqs[p].req_tag   = ptw_req_tags[p];
        assign ptw_rsp_valid[p]      = ptw_reqs[p].rsp_valid;
        assign ptw_rsp_data[p]       = ptw_reqs[p].rsp_data;
        assign ptw_rsp_tags[p]       = ptw_reqs[p].rsp_tag;
        assign ptw_reqs[p].rsp_ready = ptw_rsp_ready[p];
        assign ptw_invalidate[p]     = ptw_reqs[p].invalidate_tlb;
    end

    // -------------------------------------------------------------------------
    // Request: match one pending bank to one free PTW (one assignment / cycle)
    // -------------------------------------------------------------------------
    logic sel_bank_valid, sel_ptw_valid;
    logic [BANK_ID_WIDTH-1:0] sel_bank;
    logic [ PTW_ID_WIDTH-1:0] sel_ptw;
    wire                      assign_fire = sel_bank_valid && sel_ptw_valid;
    always_comb begin
        sel_bank_valid = 1'b0;
        sel_bank       = '0;
        sel_ptw_valid  = 1'b0;
        sel_ptw        = '0;
        for (int i = 0; i < NUM_BANKS; i++) begin
            if (!sel_bank_valid && bank_req_valid[i]) begin
                sel_bank_valid = 1'b1;
                sel_bank       = BANK_ID_WIDTH'(i);
            end
        end
        for (int j = 0; j < NUM_PTWS; j++) begin
            if (!sel_ptw_valid && ptw_req_ready[j]) begin
                sel_ptw_valid = 1'b1;
                sel_ptw       = PTW_ID_WIDTH'(j);
            end
        end
    end

    // selected bank's request with the bank id stamped into tag.bank
    mmu_pkg::ptw_tag_t sel_req_tag;
    always_comb begin
        sel_req_tag    = bank_req_tags[sel_bank];
        sel_req_tag.bank = PTW_TAG_BANK_WIDTH'(sel_bank);
    end

    always_comb begin
        ptw_req_valid  = '0;
        ptw_req_data   = '0;
        ptw_req_tags   = '0;
        bank_req_ready = '0;
        if (assign_fire) begin
            ptw_req_valid[sel_ptw]   = 1'b1;
            ptw_req_data[sel_ptw]    = bank_req_data[sel_bank];
            ptw_req_tags[sel_ptw]    = sel_req_tag;
            bank_req_ready[sel_bank] = 1'b1;  // selected PTW is ready -> bank issue fires
        end
    end

    // -------------------------------------------------------------------------
    // Response: pick one PTW with a result, route to the bank named in its tag
    // -------------------------------------------------------------------------
    logic                    rsp_valid;
    logic [PTW_ID_WIDTH-1:0] rsp_ptw;
    always_comb begin
        rsp_valid = 1'b0;
        rsp_ptw   = '0;
        for (int j = 0; j < NUM_PTWS; j++) begin
            if (!rsp_valid && ptw_rsp_valid[j]) begin
                rsp_valid = 1'b1;
                rsp_ptw   = PTW_ID_WIDTH'(j);
            end
        end
    end

    mmu_pkg::inter_tlb_rsp_data_t sel_rsp;
    mmu_pkg::ptw_tag_t            sel_rsp_tag;
    logic                   [BANK_ID_WIDTH-1:0] rsp_bank;
    assign sel_rsp  = ptw_rsp_data[rsp_ptw];
    assign sel_rsp_tag = ptw_rsp_tags[rsp_ptw];
    assign rsp_bank = BANK_ID_WIDTH'(sel_rsp_tag.bank);  // self-routes by the stamped field

    always_comb begin
        bank_rsp_valid = '0;
        bank_rsp_data  = '0;
        bank_rsp_tags  = '0;
        ptw_rsp_ready  = '0;
        if (rsp_valid) begin
            bank_rsp_valid[rsp_bank] = 1'b1;
            bank_rsp_data[rsp_bank]  = sel_rsp;  // bank reads only tag.slot
            bank_rsp_tags[rsp_bank]  = sel_rsp_tag;
            ptw_rsp_ready[rsp_ptw]   = bank_rsp_ready[rsp_bank];
        end
    end

`ifdef SIMULATION
    always_ff @(posedge clk_i)
        if (rst_i) begin
            if (rsp_valid)
                assert (int'(rsp_bank) < NUM_BANKS)
                else
                    $fatal(
                        1,
                        "ptw_scheduler: response tag names bank %0d (>= %0d)",
                        rsp_bank,
                        NUM_BANKS
                    );
        end
`endif

endmodule
