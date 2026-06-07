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

// Page-table walker.
//
// Walks the in-memory radix page table one level at a time, starting from the
// SATP root, until it reaches a leaf PTE (or faults).  A Page Walk Cache (PWC)
// short-circuits already-seen non-leaf levels.  Single outstanding walk; one
// memory read per level.
//
//   S_READY -> S_REQ on a TLB request (latch req, seed the walk pointer)
//   S_REQ   -> issue a PTE read (or skip it on a PWC hit); -> S_WAIT on req fire
//   S_WAIT  -> on the PTE response: descend (table) / S_DONE (leaf) / S_ERROR
//   S_DONE / S_ERROR -> hold the result until the TLB accepts it, then S_READY
module ptw
    import mmu_pkg::*;
#(
    parameter int unsigned XLEN = 64
) (
    input logic clk_i,
    input logic rstn_i,

    // L2 TLB request-response (unified ready/valid)
    ptw_if.slave ptw_if,

    // Memory interface (PTE reads; A/D write-back to be added on top)
    ptw_mem_if.ptw mem_if,

    // CSR interface
    input csr_ptw_comm_t csr_ptw_comm_i
);
    localparam int unsigned LEVEL_CNT_W = $clog2(LEVELS);

    wire [63:0] mem_rsp_data = mem_if.rsp_data;
    wire        mem_rsp_valid = mem_if.rsp_valid;
    wire        mem_rsp_error = mem_if.rsp_error;  // PTE access/bus fault
    wire        mem_req_ready = mem_if.req_ready;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_READY,
        S_REQ,
        S_WAIT,
        S_DONE,
        S_ERROR
    } ptw_state_t;
    ptw_state_t current_state, next_state;

    logic [LEVEL_CNT_W-1:0] count_q, count_d;  // current walk level (0 = root)
    wire not_last_level = (count_q < LEVEL_CNT_W'(LEVELS - 1));

    ptw_req_data_t req_q;  // latched TLB request
    pte_t pte_q;  // latched PTE; pte_q.ppn doubles as the walk pointer
    pte_t mem_pte;  // PTE decoded from the current memory response

    wire ptw_ready = (current_state == S_READY);

    // Page Walk Cache lookup result (driven in the PWC section below).
    logic pwc_hit;
    logic [PPN_SIZE-1:0] pwc_data;

    // -------------------------------------------------------------------------
    // VPN slice for the current level
    // -------------------------------------------------------------------------
    logic [PAGE_LVL_BITS-1:0] vpn_per_lvl[LEVELS-1:0];
    for (genvar lvl = 0; lvl < LEVELS; lvl++) begin : g_vpn_per_lvl
        logic [VPN_SIZE-1:0] vpn_shifted;
        assign vpn_shifted      = (req_q.vpn >> ((LEVELS - lvl - 1) * PAGE_LVL_BITS));
        assign vpn_per_lvl[lvl] = vpn_shifted[PAGE_LVL_BITS-1:0];
    end
    wire [PAGE_LVL_BITS-1:0] vpn_lvl = vpn_per_lvl[count_q];

    // -------------------------------------------------------------------------
    // Decode the PTE from the memory response
    // -------------------------------------------------------------------------
    assign mem_pte.ppn = mem_rsp_data[10+:(PPN_SIZE)];
    assign mem_pte.rfs = mem_rsp_data[9:8];
    assign mem_pte.d   = mem_rsp_data[7];
    assign mem_pte.a   = mem_rsp_data[6];
    assign mem_pte.g   = mem_rsp_data[5];
    assign mem_pte.u   = mem_rsp_data[4];
    assign mem_pte.x   = mem_rsp_data[3];
    assign mem_pte.w   = mem_rsp_data[2];
    assign mem_pte.r   = mem_rsp_data[1];

    // Valid bit per level: a leaf at a superpage level is only valid if its low
    // PPN bits (that the VPN will fill in) are zero (misaligned superpage = fault).
    logic pte_valid_per_lvl[LEVELS-1:0];
    for (genvar c = 0; c < (LEVELS - 1); c++) begin : g_pte_valid_per_lvl
        always_comb begin
            if (mem_pte.r || mem_pte.w || mem_pte.x) begin
                pte_valid_per_lvl[c] =
                    (mem_pte.ppn[((LEVELS-c-1)*PAGE_LVL_BITS)-1:0] == '0) ? mem_rsp_data[0] : 1'b0;
            end else begin
                pte_valid_per_lvl[c] = mem_rsp_data[0];
            end
        end
    end
    assign pte_valid_per_lvl[LEVELS-1] = mem_rsp_data[0];
    assign mem_pte.v                   = pte_valid_per_lvl[count_q];

    // -------------------------------------------------------------------------
    // Classify the PTE
    // -------------------------------------------------------------------------
    wire is_pte_table = mem_pte.v && !mem_pte.x && !mem_pte.w && !mem_pte.r;
    wire is_pte_leaf = mem_pte.v && (mem_pte.x || mem_pte.w || mem_pte.r);

    // N, PBMT and reserved bits must be zero; a non-leaf must not set D/A/U.
    wire invalid_pte = ((mem_rsp_data >> (PPN_SIZE + 10)) != '0)
                    || (is_pte_table && mem_pte.v && (mem_pte.d || mem_pte.a || mem_pte.u));

    // Per-page capability: is_pte_<s|u><r|w|x>. u/!u selects a user vs supervisor
    // page; uw/sw fold in the spec rule that W requires R.
    wire is_pte_ur = is_pte_leaf && mem_pte.u && mem_pte.r;  // user-readable
    wire is_pte_uw = is_pte_ur && mem_pte.w;  // user-writable (=> readable)
    wire is_pte_ux = mem_pte.v && mem_pte.x && mem_pte.u;  // user-executable
    wire is_pte_sr = is_pte_leaf && mem_pte.r && !mem_pte.u;  // supervisor-readable
    wire is_pte_sw = is_pte_sr && mem_pte.w;  // supervisor-writable (=> readable)
    wire is_pte_sx = mem_pte.v && mem_pte.x && !mem_pte.u;  // supervisor-executable

    // -------------------------------------------------------------------------
    // PTE address for the current level: (walk_ppn << 12) + (vpn_lvl << log2(PTE))
    // -------------------------------------------------------------------------
    logic [SIZE_VADDR:0] pte_addr;
    logic [63:0] pte_addr_full;
    assign pte_addr_full = {
        {(64 - (PPN_SIZE + PAGE_LVL_BITS + $clog2(XLEN / 8))) {1'b0}},
        {pte_q.ppn, vpn_lvl, {{($clog2(XLEN / 8))} {1'b0}}}
    };
    assign pte_addr = pte_addr_full[SIZE_VADDR:0];

    // -------------------------------------------------------------------------
    // Walk registers: latch the request, advance the walk pointer
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            req_q <= '0;
            pte_q <= '0;
        end else if ((current_state == S_WAIT) && mem_rsp_valid) begin
            pte_q <= mem_pte;  // latch the fetched PTE
        end else if ((current_state == S_REQ) && pwc_hit && not_last_level) begin
            pte_q.ppn <= pwc_data;  // PWC supplied the next pointer
        end else if (ptw_ready && ptw_if.req_valid) begin
            req_q     <= ptw_if.req_data;  // new walk: seed from SATP
            pte_q.ppn <= csr_ptw_comm_i.satp[PPN_SIZE-1:0];
        end
    end

    // -------------------------------------------------------------------------
    // Page Walk Cache (caches non-leaf PTEs by their physical address)
    // -------------------------------------------------------------------------
`ifndef NO_PTW_CACHE
    // A read hit in S_REQ lets the FSM skip the dmem read. Only real dmem
    // responses for table PTEs are installed (a hit skips the read, so no write
    // happens for that level); the cache de-dups on write.
    wire pwc_write = mem_rsp_valid && is_pte_table;
    logic pwc_read_ready, pwc_read_hit;
    ptw_cache ptw_cache_inst (
        .clk_i        (clk_i),
        .rstn_i       (rstn_i),
        .read_valid_i (current_state == S_REQ),
        .read_ready_o (pwc_read_ready),
        .read_is_hit_o(pwc_read_hit),
        .read_tag_i   (pte_addr),
        .read_data_o  (pwc_data),
        .write_valid_i(pwc_write),
        `UNUSED_PIN(write_ready_o),
        .write_tag_i  (pte_addr),
        .write_data_i (mem_pte.ppn),
        .clear_valid_i(csr_ptw_comm_i.flush),
        `UNUSED_PIN(clear_ready_o)
    );
    // Only trust a hit when the read actually fired: the cache blocks reads
    // during a write/flush, so that cycle's lookup must not be used.
    assign pwc_hit = pwc_read_hit && pwc_read_ready;
`else
    assign pwc_hit  = 1'b0;
    assign pwc_data = '0;
`endif
    wire        pwc_skip = pwc_hit && not_last_level;  // skip the dmem read this level

    // -------------------------------------------------------------------------
    // Does the access pass permissions? Gates the hardware A/D update (set A, and
    // D on a store, only on a permitted access) for the upcoming S_WRITE state.
    // Selected by privilege x operation, modified by two mstatus bits:
    //   SUM = supervisor may also touch User pages (data only)
    //   MXR = a load may also use eXecute-only pages (treat X as Readable)
    // -------------------------------------------------------------------------
    wire  [1:0] req_prv = req_q.prv;
    logic       ad_write_perm_ok;
    always_comb begin
        if (req_prv[0]) begin  // Supervisor: own (S) pages, plus U pages if SUM
            if (csr_ptw_comm_i.mstatus.sum) begin
                if (req_q.fetch) ad_write_perm_ok = is_pte_sx || is_pte_ux;
                else if (req_q.store) ad_write_perm_ok = is_pte_sw || is_pte_uw;
                else if (csr_ptw_comm_i.mstatus.mxr)  // load: + executable pages
                    ad_write_perm_ok = is_pte_sr || is_pte_ur || is_pte_ux || is_pte_sx;
                else ad_write_perm_ok = is_pte_sr || is_pte_ur;
            end else begin  // SUM=0: no access to U pages
                if (req_q.fetch) ad_write_perm_ok = is_pte_sx;
                else if (req_q.store) ad_write_perm_ok = is_pte_sw;
                else if (csr_ptw_comm_i.mstatus.mxr) ad_write_perm_ok = is_pte_sr || is_pte_sx;
                else ad_write_perm_ok = is_pte_sr;
            end
        end else begin  // User: only U pages
            if (req_q.fetch) ad_write_perm_ok = is_pte_ux;
            else if (req_q.store) ad_write_perm_ok = is_pte_uw;
            else if (csr_ptw_comm_i.mstatus.mxr) ad_write_perm_ok = is_pte_ur || is_pte_ux;
            else ad_write_perm_ok = is_pte_ur;
        end
    end

    // -------------------------------------------------------------------------
    // Memory request (read-only walks for now; A/D write-back via the S_WRITE
    // state will drive PTW_MEM_WRITE / PTW_MEM_AMO_OR with req_wdata).
    // -------------------------------------------------------------------------
    assign mem_if.req_addr  = pte_addr;
    assign mem_if.req_cmd   = PTW_MEM_READ;
    assign mem_if.req_wdata = '0;
    assign mem_if.rsp_ready = 1'b1;  // single outstanding; always accept the response

    // -------------------------------------------------------------------------
    // TLB response: assemble the translated PPN and drive the ptw_if response
    // -------------------------------------------------------------------------
    wire resp_error = (current_state == S_ERROR);
    wire resp_valid = (current_state == S_DONE) || resp_error;

    // Leaf PPN base = pte_addr >> 12 (equals the leaf PTE's PPN, since the
    // vpn_lvl<<log2(PTE) term lives entirely in the low 12 bits).
    wire [63:0] leaf_ppn_base = {{(64 - (SIZE_VADDR - 11)) {1'b0}}, pte_addr[SIZE_VADDR:12]};

    // For a leaf found at level j, the low SUPER_BITS come from the VPN and the
    // upper bits from the PTE's PPN (superpage); the deepest level (SUPER_BITS=0)
    // uses the PPN as-is. Mirrors l1_tlb's PPN assembly.
    logic [PPN_SIZE-1:0] resp_ppn_per_lvl[LEVELS-1:0];
    for (genvar j = 0; j < LEVELS; j++) begin : g_resp_ppn_per_lvl
        localparam int unsigned SUPER_BITS = (LEVELS - j - 1) * PAGE_LVL_BITS;
        if (SUPER_BITS == 0) begin : g_leaf
            assign resp_ppn_per_lvl[j] = leaf_ppn_base[PPN_SIZE-1:0];
        end else begin : g_super
            assign resp_ppn_per_lvl[j] = {
                leaf_ppn_base[PPN_SIZE-1 : SUPER_BITS], req_q.vpn[SUPER_BITS-1 : 0]
            };
        end
    end
    wire [PPN_SIZE-1:0] resp_ppn = resp_ppn_per_lvl[count_q];

    // tag echoed from the latched request; invalidate broadcast on a CSR flush.
    assign ptw_if.rsp_valid        = resp_valid;
    assign ptw_if.rsp_data.error   = resp_error;
    assign ptw_if.rsp_data.level   = count_q;
    assign ptw_if.rsp_data.pte.ppn = resp_ppn;
    assign ptw_if.rsp_data.pte.rfs = pte_q.rfs;
    assign ptw_if.rsp_data.pte.d   = pte_q.d;
    assign ptw_if.rsp_data.pte.a   = pte_q.a;
    assign ptw_if.rsp_data.pte.g   = pte_q.g;
    assign ptw_if.rsp_data.pte.u   = pte_q.u;
    assign ptw_if.rsp_data.pte.x   = pte_q.x;
    assign ptw_if.rsp_data.pte.w   = pte_q.w;
    assign ptw_if.rsp_data.pte.r   = pte_q.r;
    assign ptw_if.rsp_data.pte.v   = pte_q.v;
    assign ptw_if.rsp_data.tag     = req_q.tag;
    assign ptw_if.req_ready        = ptw_ready;
    assign ptw_if.invalidate_tlb   = csr_ptw_comm_i.flush;

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
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
        mem_if.req_valid = 1'b0;
        next_state       = current_state;
        case (current_state)
            S_READY: begin
                count_d = '0;
                if (ptw_if.req_valid) next_state = S_REQ;
            end
            S_REQ: begin
                if (pwc_skip) begin
                    // Cached non-leaf pointer: descend without a memory read.
                    count_d    = count_q + LEVEL_CNT_W'(1);
                    next_state = S_REQ;
                end else begin
                    mem_if.req_valid = 1'b1;
                    if (mem_req_ready) next_state = S_WAIT;
                end
            end
            S_WAIT: begin
                // A fired request is guaranteed a response (ready/valid memory).
                if (mem_rsp_valid) begin
                    if (invalid_pte || mem_rsp_error) next_state = S_ERROR;
                    else if (is_pte_table && not_last_level) begin
                        count_d    = count_q + LEVEL_CNT_W'(1);  // descend
                        next_state = S_REQ;
                    end else if (is_pte_leaf) next_state = S_DONE;
                    else next_state = S_ERROR;
                end
            end
            S_DONE:  next_state = ptw_if.rsp_ready ? S_READY : S_DONE;  // hold until accepted
            S_ERROR: next_state = ptw_if.rsp_ready ? S_READY : S_ERROR;
            default: next_state = S_READY;
        endcase
    end
endmodule

`IGNORE_WARNINGS_END
