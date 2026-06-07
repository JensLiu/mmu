/*
 * Copyright 2025 BSC*
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
module ptw
    import mmu_pkg::*;
#(
    parameter int unsigned XLEN = 64
) (
    input logic clk_i,
    input logic rstn_i,

    // TLB request-response (unified ready/valid)
    ptw_if.slave ptw_if,

    // Memory interface (PTE reads; A/D write-back to be added on top)
    ptw_mem_if.ptw mem_if,

    // csr interface
    input csr_ptw_comm_t csr_ptw_comm_i
);
    // Memory response aliases (lean ptw_mem_if).
    wire [63:0] dmem_data = mem_if.rsp_data;
    wire        dmem_valid = mem_if.rsp_valid;
    wire        dmem_error = mem_if.rsp_error;
    wire        dmem_ready = mem_if.req_ready;

    // Page-Table Walker FSM States
    typedef enum logic [2:0] {
        S_READY,
        S_REQ,
        S_WAIT,
        S_DONE,
        S_ERROR
    } ptw_state;

    // Signal declaration
    logic unsigned [$clog2(LEVELS)-1:0] count_d, count_q;
    logic unsigned [$clog2(LEVELS):0] count;

    ptw_state current_state, next_state;

    logic                              ptw_ready;
    ptw_req_data_t                     r_req;
    pte_t                              r_pte;
    pte_t                              pte;

    logic          [PAGE_LVL_BITS-1:0] vpn_req      [LEVELS-1:0];
    logic          [PAGE_LVL_BITS-1:0] vpn_idx;
    logic          [     SIZE_VADDR:0] pte_addr;
    logic                              invalid_pte;
    logic                              valid_pte_lvl[LEVELS-1:0];
    logic is_pte_leaf, is_pte_table;
    logic is_pte_ur, is_pte_uw, is_pte_ux;
    logic is_pte_sr, is_pte_sw, is_pte_sx;

    logic [1:0] prv_req;
    logic       perm_ok;

    logic resp_err, resp_val;
    logic [        63:0] r_resp_ppn;
    logic [PPN_SIZE-1:0] resp_ppn_lvl   [LEVELS-1:0];
    logic [PPN_SIZE-1:0] resp_ppn;

    logic                pte_cache_hit;
    logic [PPN_SIZE-1:0] pte_cache_data;

    // VPN indexation depending on the page level
    genvar lvl;
    generate
        for (lvl = 0; lvl < LEVELS; lvl++) begin
            logic [VPN_SIZE-1:0] aux_vpn_req;
            assign aux_vpn_req  = (r_req.vpn >> ((LEVELS - lvl - 1) * PAGE_LVL_BITS));
            assign vpn_req[lvl] = aux_vpn_req[PAGE_LVL_BITS-1:0];
        end
    endgenerate
    assign vpn_idx = vpn_req[count_q];

    // Formatting pte data from dmem
    assign pte.ppn = dmem_data[10+:(PPN_SIZE)];
    assign pte.rfs = dmem_data[9:8];
    assign pte.d   = dmem_data[7];
    assign pte.a   = dmem_data[6];
    assign pte.g   = dmem_data[5];
    assign pte.u   = dmem_data[4];
    assign pte.x   = dmem_data[3];
    assign pte.w   = dmem_data[2];
    assign pte.r   = dmem_data[1];

    genvar c;
    generate
        for (c = 0; c < (LEVELS - 1); c++) begin
            always_comb begin
                if (pte.r || pte.w || pte.x) begin
                    valid_pte_lvl[c] = (pte.ppn[((LEVELS-c-1)*PAGE_LVL_BITS)-1:0] == '0) ? dmem_data[0] : 1'b0; //Make sure PPN LSB are 0
                end else begin
                    valid_pte_lvl[c] = dmem_data[0];
                end
            end
        end
    endgenerate
    assign valid_pte_lvl[LEVELS-1] = dmem_data[0];
    assign pte.v = valid_pte_lvl[count_q];

    assign invalid_pte = (((dmem_data >> (PPN_SIZE+10)) != '0) ||
                      ((is_pte_table & pte.v & (pte.d || pte.a || pte.u)))) ? 1'b1 : 1'b0; //Make sure that N, PBMT and Reserved are 0

    assign is_pte_table = pte.v && !pte.x && !pte.w && !pte.r;
    assign is_pte_leaf = pte.v && (pte.x || pte.w || pte.r);

    assign is_pte_ur = is_pte_leaf && pte.u && pte.r;
    assign is_pte_uw = is_pte_ur && pte.w;
    assign is_pte_ux = pte.v && pte.x && pte.u;
    assign is_pte_sr = is_pte_leaf && pte.r && !pte.u;
    assign is_pte_sw = is_pte_sr && pte.w;
    assign is_pte_sx = pte.v && pte.x && !pte.u;

    // Page Table Entry pointer
    logic [63:0] aux_pte_addr;
    assign aux_pte_addr = {
        {(64 - (PPN_SIZE + PAGE_LVL_BITS + $clog2(XLEN / 8))) {1'b0}},
        {r_pte.ppn, vpn_idx, {{($clog2(XLEN / 8))} {1'b0}}}
    };
    assign pte_addr = aux_pte_addr[SIZE_VADDR:0];  // For Sv39: (r_pte.ppn << 12) + (vpn_idx << 3)

    // PTW Ready
    assign ptw_ready = (current_state == S_READY);

    // Catch Request from TLB(Arb) & PTE response from dmem
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            r_req <= '0;
            r_pte <= '0;
        end else begin
            if ((current_state == S_WAIT) && dmem_valid) begin
                r_pte <= pte;
            end else if ((current_state == S_REQ) && pte_cache_hit && (count_q < $unsigned(
                    LEVELS - 1
                ))) begin
                r_pte.ppn <= pte_cache_data;
            end else if (ptw_ready & ptw_if.req_valid) begin
                r_req     <= ptw_if.req_data;
                r_pte.ppn <= csr_ptw_comm_i.satp[PPN_SIZE-1:0];
            end
        end
    end
`ifndef NO_PTW_CACHE
    // Page Walk Cache: caches non-leaf PTEs (page-table pointers) keyed by the
    // PTE physical address. A read hit in S_REQ lets the FSM skip the dmem read.
    // Only real dmem responses for table PTEs are installed (a cache hit skips
    // the read, so no write occurs for that level); the cache de-dups on write.
    wire ptw_cache_write = dmem_valid && is_pte_table;
    logic ptw_cache_rd_ready, ptw_cache_raw_hit;
    ptw_cache ptw_cache_inst (
        .clk_i        (clk_i),
        .rstn_i       (rstn_i),
        .read_valid_i (current_state == S_REQ),
        .read_ready_o (ptw_cache_rd_ready),
        .read_is_hit_o(ptw_cache_raw_hit),
        .read_tag_i   (pte_addr),
        .read_data_o  (pte_cache_data),
        .write_valid_i(ptw_cache_write),
        `UNUSED_PIN(write_ready_o),
        .write_tag_i  (pte_addr),
        .write_data_i (pte.ppn),
        .clear_valid_i(csr_ptw_comm_i.flush),
        `UNUSED_PIN(clear_ready_o)
    );
    // Only trust a hit when the read actually fired: the cache blocks reads
    // during a write/flush, so that cycle's lookup must not be used.
    assign pte_cache_hit = ptw_cache_raw_hit && ptw_cache_rd_ready;
`else
    assign pte_cache_hit  = 1'b0;
    assign pte_cache_data = '0;
`endif

    // Check permissons for set_dirty
    assign prv_req = r_req.prv;

    always_comb begin
        if (prv_req[0]) begin  //Supervisor
            if (csr_ptw_comm_i.mstatus.sum) begin
                if (r_req.fetch) perm_ok = is_pte_sx || is_pte_ux;
                else begin
                    if (r_req.store) perm_ok = is_pte_sw || is_pte_uw;
                    else if (csr_ptw_comm_i.mstatus.mxr)
                        perm_ok = is_pte_sr || is_pte_ur || is_pte_ux || is_pte_sx;
                    else perm_ok = is_pte_sr || is_pte_ur;
                end
            end else begin
                if (r_req.fetch) perm_ok = is_pte_sx;
                else begin
                    if (r_req.store) perm_ok = is_pte_sw;
                    else if (csr_ptw_comm_i.mstatus.mxr) perm_ok = is_pte_sr || is_pte_sx;
                    else perm_ok = is_pte_sr;
                end
            end
        end else begin  //User
            if (r_req.fetch) perm_ok = is_pte_ux;
            else begin
                if (r_req.store) perm_ok = is_pte_uw;
                else if (csr_ptw_comm_i.mstatus.mxr) perm_ok = is_pte_ur || is_pte_ux;
                else perm_ok = is_pte_ur;
            end
        end
    end

    // Memory request. Walks are read-only for now; A/D write-back (PTW_MEM_WRITE
    // / PTW_MEM_AMO_OR with req_wdata) will be added with the S_WRITE state.
    assign mem_if.req_addr = pte_addr;
    assign mem_if.req_cmd = PTW_MEM_READ;
    assign mem_if.req_wdata = '0;
    assign mem_if.rsp_ready = 1'b1;  // single outstanding; always accept the response

    // TLB Response
    assign resp_err = (current_state == S_ERROR);
    assign resp_val = (current_state == S_DONE) || resp_err;

    assign r_resp_ppn = {
        {(64 - (SIZE_VADDR - 11)) {1'b0}}, pte_addr[SIZE_VADDR:12]
    };  // pte_addr >> 12
    genvar j;
    generate
        for (j = 0; j < (LEVELS - 1); j++) begin
            logic [63:0] aux_resp_ppn_lvl;
            assign aux_resp_ppn_lvl = {
                {(64 - $bits(
                    r_resp_ppn[63:(LEVELS-j-1)*PAGE_LVL_BITS]
                ) - $bits(
                    r_req.vpn[PAGE_LVL_BITS*(LEVELS-j-1)-1:0]
                )) {1'b0}},
                r_resp_ppn[63:(LEVELS-j-1)*PAGE_LVL_BITS],
                r_req.vpn[PAGE_LVL_BITS*(LEVELS-j-1)-1:0]
            };
            assign resp_ppn_lvl[j] = aux_resp_ppn_lvl[PPN_SIZE-1:0];
        end
    endgenerate
    assign resp_ppn_lvl[LEVELS-1]  = r_resp_ppn[PPN_SIZE-1:0];
    assign resp_ppn                = resp_ppn_lvl[count_q];

    // Send TLB Response (unified ready/valid; tag echoed from the latched request)
    assign ptw_if.rsp_valid        = resp_val;
    assign ptw_if.rsp_data.error   = resp_err;
    assign ptw_if.rsp_data.level   = count_q;
    assign ptw_if.rsp_data.pte.ppn = resp_ppn;
    assign ptw_if.rsp_data.pte.rfs = r_pte.rfs;
    assign ptw_if.rsp_data.pte.d   = r_pte.d;
    assign ptw_if.rsp_data.pte.a   = r_pte.a;
    assign ptw_if.rsp_data.pte.g   = r_pte.g;
    assign ptw_if.rsp_data.pte.u   = r_pte.u;
    assign ptw_if.rsp_data.pte.x   = r_pte.x;
    assign ptw_if.rsp_data.pte.w   = r_pte.w;
    assign ptw_if.rsp_data.pte.r   = r_pte.r;
    assign ptw_if.rsp_data.pte.v   = r_pte.v;
    assign ptw_if.rsp_data.tag     = r_req.tag;
    assign ptw_if.req_ready        = ptw_ready;
    assign ptw_if.invalidate_tlb   = csr_ptw_comm_i.flush;

    // Page-Table Walker FSM
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            current_state <= S_READY;
            count_q       <= '0;
        end else begin
            current_state <= next_state;
            count_q       <= count_d;
        end
    end

    always_comb begin
        count_d          = count_q;
        count            = count_q + 1'b1;
        mem_if.req_valid = 1'b0;
        next_state       = current_state;
        case (current_state)
            S_READY: begin
                count_d = '0;
                if (ptw_if.req_valid) next_state = S_REQ;
                else next_state = S_READY;
            end
            S_REQ: begin
                mem_if.req_valid = 1'b1;
                if (pte_cache_hit && (count_q < $unsigned(LEVELS - 1))) begin
                    mem_if.req_valid = 1'b0;
                    count_d          = count[1:0];
                    next_state       = S_REQ;
                end else if (dmem_ready) begin
                    next_state = S_WAIT;
                end else begin
                    next_state = S_REQ;
                end
            end
            S_WAIT: begin
                if (dmem_valid) begin
                    if (invalid_pte || dmem_error) begin
                        next_state = S_ERROR;
                    end else if (is_pte_table && (count_q < $unsigned(LEVELS - 1))) begin
                        count_d    = count[1:0];
                        next_state = S_REQ;
                    end else if (is_pte_leaf) begin
                        next_state = S_DONE;
                    end else begin
                        next_state = S_ERROR;
                    end
                end else begin
                    next_state = S_WAIT;
                end
            end
            S_DONE: begin
                // Hold the response until the TLB accepts it (backpressured rsp channel).
                next_state = ptw_if.rsp_ready ? S_READY : S_DONE;
            end
            S_ERROR: begin
                next_state = ptw_if.rsp_ready ? S_READY : S_ERROR;
            end
        endcase
    end
endmodule

`IGNORE_WARNINGS_END
