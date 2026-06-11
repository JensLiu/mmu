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

module ptw #(
    parameter  int unsigned XLEN              = mmu_pkg::XLEN,
    localparam int unsigned LEVELS            = mmu_pkg::LEVELS,
    localparam int unsigned PPN_WIDTH         = mmu_pkg::PPN_WIDTH,
    localparam int unsigned VPN_WIDTH         = mmu_pkg::VPN_WIDTH,
    localparam int unsigned PADDR_WIDTH       = mmu_pkg::PADDR_WIDTH,
    localparam int unsigned PAGE_LVL_BITS     = mmu_pkg::PAGE_LVL_BITS,
    localparam int unsigned LEVEL_CNT_WIDTH   = $clog2(LEVELS),
    localparam int unsigned ADDR_OFFSET_WIDTH = $clog2(XLEN / 8)
) (
    input logic clk_i,
    input logic rst_i,

    ptw_if.slave      ptw_if,
    ptw_mem_if.master mem_if,

    /* verilator lint_off UNUSEDSIGNAL */
    input mmu_pkg::csr_ptw_comm_t csr_ptw_comm_i
    /* verilater lint_on UNUSEDSIGNAL */
);

    wire [63:0] mem_rsp_data = mem_if.rsp_data;
    wire        mem_rsp_valid = mem_if.rsp_valid;
    wire        mem_rsp_error = mem_if.rsp_error;
    wire        mem_req_ready = mem_if.req_ready;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_READY,
        S_REQ,
        S_WAIT,
        S_WRITE_REQ,
        S_DONE,
        S_ERROR
    } ptw_state_t;
    ptw_state_t current_state, next_state;

    logic [LEVEL_CNT_WIDTH-1:0] count_r, count_n;  // current walk level (0 = root)
    wire not_last_level = (count_r < LEVEL_CNT_WIDTH'(LEVELS - 1));

    mmu_pkg::ptw_req_data_t req_r;
    mmu_pkg::pte_t pte_r;
    mmu_pkg::pte_t mem_pte;

    wire ptw_ready = (current_state == S_READY);

    // Page Walk Cache
    logic pwc_hit;
    logic [PPN_WIDTH-1:0] pwc_data;

    // -------------------------------------------------------------------------
    // VPN slice for the current level
    // -------------------------------------------------------------------------
    logic [PAGE_LVL_BITS-1:0] vpn_per_lvl[LEVELS-1:0];
    for (genvar lvl = 0; lvl < LEVELS; lvl++) begin : g_vpn_per_lvl
        logic [VPN_WIDTH-1:0] vpn_shifted;
        assign vpn_shifted      = (req_r.vpn >> ((LEVELS - lvl - 1) * PAGE_LVL_BITS));
        assign vpn_per_lvl[lvl] = vpn_shifted[PAGE_LVL_BITS-1:0];
    end
    wire [PAGE_LVL_BITS-1:0] vpn_lvl = vpn_per_lvl[count_r];

    // -------------------------------------------------------------------------
    // Decode the PTE from the memory response
    // -------------------------------------------------------------------------
    assign mem_pte.ppn = mem_rsp_data[10+:(PPN_WIDTH)];
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
    /* verilator lint_off UNOPTFLAT */
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
    assign mem_pte.v                   = pte_valid_per_lvl[count_r];
    /* verilator lint_on UNOPTFLAT */

    // -------------------------------------------------------------------------
    // Classify the PTE
    // -------------------------------------------------------------------------
    wire is_pte_table = mem_pte.v && !mem_pte.x && !mem_pte.w && !mem_pte.r;
    wire is_pte_leaf = mem_pte.v && (mem_pte.x || mem_pte.w || mem_pte.r);

    // N, PBMT and reserved bits must be zero; a non-leaf must not set D/A/U.
    wire invalid_pte = ((mem_rsp_data >> (PPN_WIDTH + 10)) != '0)
                    || (is_pte_table && mem_pte.v && (mem_pte.d || mem_pte.a || mem_pte.u));

    // page capability per {s|u}{r|w|x}; uw/sw fold in W=>R
    wire is_pte_ur = is_pte_leaf && mem_pte.u && mem_pte.r;
    wire is_pte_uw = is_pte_ur && mem_pte.w;
    wire is_pte_ux = mem_pte.v && mem_pte.x && mem_pte.u;
    wire is_pte_sr = is_pte_leaf && mem_pte.r && !mem_pte.u;
    wire is_pte_sw = is_pte_sr && mem_pte.w;
    wire is_pte_sx = mem_pte.v && mem_pte.x && !mem_pte.u;

    // A non-writable leaf skips the write
    // TLB permission check should raise the store fault from the returned perms
    wire do_dirty_write = req_r.set_dirty && is_pte_leaf && mem_pte.w && !mem_pte.d;

    // -------------------------------------------------------------------------
    // PTE address for the current level: (walk_ppn << 12) + (vpn_lvl << log2(PTE))
    // PADDR_WIDTH clamps the PA to the platform width (SV39: full 56-bit PA;
    // SV32: 32 bits, dropping ppn[21:20] -- see mmu_pkg).
    // -------------------------------------------------------------------------
    logic [PADDR_WIDTH-1:0] pte_addr;
    logic [PADDR_WIDTH-1:0] pte_addr_r;  // address of the last fetched PTE
    assign pte_addr =
        PADDR_WIDTH'((XLEN'(pte_r.ppn) << 12) | (XLEN'(vpn_lvl) << ADDR_OFFSET_WIDTH));

    // -------------------------------------------------------------------------
    // Walk registers: latch the request, advance the walk pointer
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            req_r      <= '0;
            pte_r      <= '0;
            pte_addr_r <= '0;
        end else if ((current_state == S_WAIT) && mem_rsp_valid) begin
            pte_r      <= mem_pte;  // latch the fetched PTE
            pte_r.d    <= mem_pte.d | do_dirty_write;  // response/write-back see the
            pte_r.a    <= mem_pte.a | do_dirty_write;  // updated PTE, not the read one
            pte_addr_r <= pte_addr;  // the PTE's own address, for the dirty write-back
        end else if ((current_state == S_REQ) && pwc_hit && not_last_level) begin
            pte_r.ppn <= pwc_data;  // PWC supplied the next pointer
        end else if (ptw_ready && ptw_if.req_valid) begin
            req_r     <= ptw_if.req_data;  // new walk: seed from SATP
            pte_r.ppn <= csr_ptw_comm_i.satp[PPN_WIDTH-1:0];
        end
    end

    // -------------------------------------------------------------------------
    // Page Walk Cache (caches non-leaf PTEs by their physical address)
    // -------------------------------------------------------------------------
`ifndef NO_PTW_CACHE
    // A read hit in S_REQ lets the FSM skip the dmem read. Only real dmem
    // responses for table PTEs are installed (a hit skips the read, so no write
    // happens for that level); the cache de-dups on write. Gated on S_WAIT so a
    // stray response outside the read phase can never pollute the cache.
    wire pwc_write = (current_state == S_WAIT) && mem_rsp_valid && is_pte_table;
    logic pwc_read_ready, pwc_read_hit;
    ptw_cache ptw_cache_inst (
        .clk_i        (clk_i),
        .rst_i        (rst_i),
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
    wire pwc_skip = pwc_hit && not_last_level;  // skip the dmem read this level

    // -------------------------------------------------------------------------
    // Memory request
    // -------------------------------------------------------------------------
    always_comb begin
        mem_if.req_addr  = pte_addr;
        mem_if.req_wbe   = '0;
        mem_if.rsp_ready = 1'b1;  // single outstanding; always accept the response
        mem_if.req_cmd   = mmu_pkg::PTW_MEM_READ;
        mem_if.req_wdata = '0;
        if (current_state == S_WRITE_REQ) begin
            // Posted write-back of the updated PTE (D/A already set in pte_r),
            // at the PTE's own address (pte_r.ppn now holds the leaf, so the
            // live pte_addr would point into the target page instead).
            // TODO: support AMO_OR operation
            mem_if.req_cmd   = mmu_pkg::PTW_MEM_WRITE;
            mem_if.req_addr  = pte_addr_r;
            mem_if.req_wdata = XLEN'(pte_r);
            mem_if.req_wbe   = '1;  // whole PTE; the adapter shifts it into line position
        end
    end

    // -------------------------------------------------------------------------
    // TLB response
    // -------------------------------------------------------------------------
    wire                                rsp_error = (current_state == S_ERROR);
    wire                                rsp_valid = (current_state == S_DONE) || rsp_error;

    // In S_DONE pte_r holds the leaf PTE, so its PPN is the translation base
    // (full width, not clamped to the platform PA like pte_addr).
    wire [PPN_WIDTH-1:0]                leaf_ppn_base = pte_r.ppn;
    wire [   LEVELS-1:0][PPN_WIDTH-1:0] rsp_ppn_per_lvl;
    for (genvar j = 0; j < LEVELS; j++) begin : g_rsp_ppn_per_lvl
        localparam int unsigned SUPER_BITS = (LEVELS - j - 1) * PAGE_LVL_BITS;
        if (SUPER_BITS == 0) begin : g_leaf
            assign rsp_ppn_per_lvl[j] = leaf_ppn_base[PPN_WIDTH-1:0];
        end else begin : g_super
            assign rsp_ppn_per_lvl[j] = {
                leaf_ppn_base[PPN_WIDTH-1 : SUPER_BITS], req_r.vpn[SUPER_BITS-1 : 0]
            };
        end
    end
    wire [PPN_WIDTH-1:0] rsp_ppn = rsp_ppn_per_lvl[count_r];

    assign ptw_if.rsp_valid        = rsp_valid;
    assign ptw_if.rsp_data.error   = rsp_error;
    assign ptw_if.rsp_data.level   = count_r;
    assign ptw_if.rsp_data.pte.ppn = rsp_ppn;
    assign ptw_if.rsp_data.pte.rfs = pte_r.rfs;
    assign ptw_if.rsp_data.pte.d   = pte_r.d;
    assign ptw_if.rsp_data.pte.a   = pte_r.a;
    assign ptw_if.rsp_data.pte.g   = pte_r.g;
    assign ptw_if.rsp_data.pte.u   = pte_r.u;
    assign ptw_if.rsp_data.pte.x   = pte_r.x;
    assign ptw_if.rsp_data.pte.w   = pte_r.w;
    assign ptw_if.rsp_data.pte.r   = pte_r.r;
    assign ptw_if.rsp_data.pte.v   = pte_r.v;
    assign ptw_if.rsp_data.tag     = req_r.tag;
    assign ptw_if.req_ready        = ptw_ready;
    assign ptw_if.invalidate_tlb   = csr_ptw_comm_i.flush;

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            current_state <= S_READY;
            count_r       <= '0;
        end else begin
            current_state <= next_state;
            count_r       <= count_n;
        end
    end

    always_comb begin
        count_n          = count_r;
        mem_if.req_valid = 1'b0;
        next_state       = current_state;
        case (current_state)
            S_READY: begin
                count_n = '0;
                if (ptw_if.req_valid) next_state = S_REQ;
            end
            S_REQ: begin
                if (pwc_skip) begin
                    // Cached non-leaf pointer: descend without a memory read.
                    count_n    = count_r + LEVEL_CNT_WIDTH'(1);
                    next_state = S_REQ;
                end else begin
                    mem_if.req_valid = 1'b1;
                    if (mem_req_ready) next_state = S_WAIT;
                end
            end
            S_WAIT: begin
                // A fired request is guaranteed a response (ready/valid memory).
                if (mem_rsp_valid) begin
                    if (invalid_pte || mem_rsp_error) begin
                        next_state = S_ERROR;
                    end else if (is_pte_table && not_last_level) begin
                        count_n    = count_r + LEVEL_CNT_WIDTH'(1);  // descend
                        next_state = S_REQ;
                    end else if (is_pte_leaf) begin
                        next_state = do_dirty_write ? S_WRITE_REQ : S_DONE;
                    end else next_state = S_ERROR;
                end
            end
            S_WRITE_REQ: begin
                // no write response needed for store
                mem_if.req_valid = 1'b1;
                if (mem_req_ready) next_state = S_DONE;
            end
            S_DONE:  next_state = ptw_if.rsp_ready ? S_READY : S_DONE;  // hold until accepted
            S_ERROR: next_state = ptw_if.rsp_ready ? S_READY : S_ERROR;
            default: next_state = S_READY;
        endcase
    end
endmodule
