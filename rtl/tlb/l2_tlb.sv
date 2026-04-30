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
    parameter int unsigned NUM_TLB_PORTS = 1
) (
    input logic clk_i,  // System clock signal.
    input logic rstn_i, // System reset signal (active low).

    // TLB request-response
    input  l1_l2_comm_t l1_l2_comms_i[NUM_TLB_PORTS],
    output l2_l1_comm_t l2_l1_comms_o[NUM_TLB_PORTS],

    // PTW request-response
    input  ptw_l2_comm_t ptw_l2_comm_i,
    output l2_ptw_comm_t l2_ptw_comm_o
);

    tlb_entry_t [TLB_ENTRIES-1:0] tlb_entries;

    // Truncate function
    function [TLB_IDX_SIZE-1:0] trunc_tlb_idx_size(input [31:0] val_in);
        trunc_tlb_idx_size = val_in[TLB_IDX_SIZE-1:0];
    endfunction

    function [TLB_IDX_SIZE-1:0] trunc_tlb_idx_size_4in(input [3:0] val_in);
        trunc_tlb_idx_size_4in = val_in[TLB_IDX_SIZE-1:0];
    endfunction

    // -------------------------------------------------------------------------
    // Parallel CAM hit logic
    // -------------------------------------------------------------------------
    logic                    hit_per_lvl_per_port[NUM_TLB_PORTS] [LEVELS];
    logic                    hit_cam_per_port    [NUM_TLB_PORTS];
    logic [TLB_IDX_SIZE-1:0] hit_idx_per_port    [NUM_TLB_PORTS];
    logic [      VPN_SIZE:0] cache_vpn_per_port  [NUM_TLB_PORTS];

    // CAM hit logic
    for (genvar port = 0; port < NUM_TLB_PORTS; ++port) begin : g_cache_req
        logic [TLB_ENTRIES-1:0] hits_per_lvl[LEVELS];
        logic [TLB_ENTRIES-1:0] hits_cam;

        // Per-level hit vectors indexed by PTW level (0 = largest page).
        // For PTW level l, compare the top (l+1)*PAGE_LVL_BITS bits of the VPN:
        //   SV39 (LEVELS=3, PAGE_LVL_BITS=9): l=0→vpn[26:18], l=1→vpn[26:9], l=2→vpn[26:0]
        //   SV32 (LEVELS=2, PAGE_LVL_BITS=10): l=0→vpn[19:10], l=1→vpn[19:0]

        assign cache_vpn_per_port[port] = l1_l2_comms_i[port].req.vpn;
        logic [ASID_SIZE-1:0] cache_asid;
        assign cache_asid = l1_l2_comms_i[port].req.asid;

        for (genvar lvl = 0; lvl < LEVELS; lvl++) begin : g_cam_hits
            // Number of VPN bits to compare for a leaf at PTW level lvl.
            // lvl=0 (largest page): only the top PAGE_LVL_BITS bits matter.
            // lvl=LEVELS-1 (4 KB): all VPN_SIZE bits must match.
            localparam int VPN_CMP_BITS = (lvl + 1) * PAGE_LVL_BITS;
            always_comb begin
                for (int i = 0; i < TLB_ENTRIES; i++) begin
                    hits_per_lvl[lvl][i] = (
                        (tlb_entries[i].vpn[VPN_SIZE-1 -: VPN_CMP_BITS] == cache_vpn_per_port[port][VPN_SIZE-1 -: VPN_CMP_BITS])
                        && (tlb_entries[i].asid == cache_asid)
                        && tlb_entries[i].valid
                        && (tlb_entries[i].level == 2'(lvl))
                    ) ? 1'b1 : 1'b0;
                end
            end
            assign hit_per_lvl[lvl] = |hits_per_lvl[lvl];
        end

        // OR all per-level hits; at most one entry in hits_cam will be '1'
        always_comb begin
            hits_cam = '0;
            for (int l = 0; l < LEVELS; l++) hits_cam[lvl] |= hits_per_lvl[lvl];
        end
        assign hit_cam = |hits_cam;

        // encodes the hit index
        logic found;
        always_comb begin
            hit_idx[port] = '0;  // don't care if no 'in' bits set
            found         = 0;
            for (int i = 0; (i < TLB_ENTRIES) && (!found); i++) begin
                if (hits_cam[i] == 1'b1) begin
                    hit_idx[port] = trunc_tlb_idx_size($unsigned(i));
                    found         = 1;
                end
            end
        end
    end

    // Parallel Hit logic
    logic tlb_hit_per_port                 [NUM_TLB_PORTS];
    logic tlb_miss_per_port                [NUM_TLB_PORTS];
    logic store_hit_per_port               [NUM_TLB_PORTS];
    logic vm_enable_per_port               [NUM_TLB_PORTS];
    logic passthrough_per_port             [NUM_TLB_PORTS];
    // These information are needed to update flags in the TLB entry
    logic tlb_entry_access_is_zero_per_port[NUM_TLB_PORTS];
    logic tlb_entry_dirty_is_zero_per_port [NUM_TLB_PORTS];

    logic xcpt_ifs[NUM_TLB_PORTS], xcpt_sts[NUM_TLB_PORTS], xcpt_lds[NUM_TLB_PORTS];
    for (genvar port = 0; port < NUM_TLB_PORTS; ++port) begin : g_hit_logic
        logic read_ok;
        logic write_ok;
        logic exec_ok;
        logic sv_priv_lvl;  // value chagned by permission checking logic
        assign sv_priv_lvl = (l1_l2_comms_i[port].req.prv != '0) ? 1'b1 : 1'b0; // if we are not user -> supervisor

        // Compute `store_hit_per_port`:
        // Store to an entry that is NOT dirty (Need to update the PT)
        always_comb begin
            if (l1_l2_comms_i[port].req.store) begin
                if (tlb_entries[hit_idx].dirty) begin  // dirty page, no problem
                    store_hit_per_port[port] = 1'b1;
                end else if (!write_ok) begin // we dont have write perms, so hit in order to raise STORE xcpt
                    store_hit_per_port[port] = 1'b1;
                end else begin // we have the right permissions, but the page is not set as dirty, we have to mark it as so in the PT
                    store_hit_per_port[port] = 1'b0;
                end
            end else begin  // not a store, no problem
                store_hit_per_port[port] = 1'b1;
            end
        end

        assign vm_enable_per_port[port]   = l1_l2_comms_i[port].vm_enable;
        assign passthrough_per_port[port] = l1_l2_comms_i[port].req.passthrough;
        assign tlb_miss_per_port[port]    = vm_enable_per_port[port] && !(hit_cam);
    end

    // -------------------------------------------------------------------------
    // Serialised TLB Miss Handling
    // -------------------------------------------------------------------------

    // Select one TLB miss to serve
    // On simultanious TLB miss on the same TLB entry, after the first serve, all other CAM
    // will become hits
    logic                             grand_valid;
    logic [$clog2(NUM_TLB_PORTS)-1:0] grant_idx;
    VX_generic_arbiter #(
        .NUM_REQS(NUM_TLB_PORTS),
        .TYPE    ("P"),
        .STICKY  (1)
    ) tlb_miss_arbiter (
        .clk        (clk_i),
        .reset      (~rstn_i),
        .requests   (tlb_miss_per_port),
        `UNUSED_PIN(grant_onehot),
        .grant_index(grant_idx),
        .grant_valid(grand_valid)
    );

    typedef enum logic [1:0] {
        MS_IDLE,
        MS_WAIT_FOR_RSP
    } tlb_miss_state_t;
    tlb_miss_state_t                             mstate;
    logic            [$clog2(NUM_TLB_PORTS)-1:0] inflight_idx;
    always_ff @(posedge clk_i) begin : g_tlb_miss_fsm
        if (!rstn_i) begin
            inflight_idx <= '0;
        end else begin
            case (mstate)
                MS_IDLE: begin
                    if (grand_valid) begin
                        inflight_idx <= grant_idx;
                        mstate       <= MS_WAIT_FOR_RSP;
                    end
                end
                MS_WAIT_FOR_RSP: begin
                    if (ptw_l2_comm_i.resp.valid) begin
                        inflight_idx <= '0;
                        // NOTE: the response must be consumed in the same cycle
                        //       it is received.
                        mstate       <= MS_IDLE;
                    end
                end
                default: begin
                    inflight_idx <= '0;
                    mstate       <= MS_IDLE;
                end
            endcase
        end
    end

    logic tlb_hit, tlb_miss, store_hit, vm_enable, passthrough;
    logic [VPN_SIZE:0] cache_vpn;  // for reconstructing the PPN in superpage cases
    always_comb begin : g_miss_serialised
        if (mstate == MS_WAIT_FOR_RSP) begin
            tlb_hit     = tlb_hit_per_port[inflight_idx];
            tlb_miss    = tlb_miss_per_port[inflight_idx];
            store_hit   = store_hit_per_port[inflight_idx];
            vm_enable   = vm_enable_per_port[inflight_idx];
            passthrough = passthrough_per_port[inflight_idx];
            cache_vpn   = cache_vpn_per_port[inflight_idx];
        end else begin
            tlb_hit     = '0;
            tlb_miss    = '0;
            store_hit   = '0;
            vm_enable   = '0;
            passthrough = '0;
            cache_vpn   = '0;
        end
    end

    // Flush
    logic clean_tlb;  // TLB FSM changes this value

    always_comb begin
        clear_tlb  = 1'b0;
        clear_mask = '0;
        if (ptw_l2_comm_i.invalidate_tlb) begin
            clear_tlb  = 1'b1;
            clear_mask = 'hFF;
        end else if (clean_tlb) begin // flush invalid entries and cam hit in a non-dirty page when store arrives
            clear_tlb = 1'b1;
            for (int i = 0; i < TLB_ENTRIES; ++i) begin
                if (!tlb_entries[i].valid || (($unsigned(
                        i
                    ) == hit_idx) && hit_cam && !store_hit)) begin
                    clear_mask[i] = 1'b1; // invalidate the TLB entry because we do not have dirty bit on it and is required or entry is invalid
                end
            end
        end
    end

    // TLB FSM, in case of TLB miss
    ///////////////////////////////

    typedef enum logic [1:0] {
        PS_IDLE,
        PS_SEND_REQUEST,
        PS_WAIT_RESPONSE,
        PS_INVALIDATED_WAIT_RESPONSE
    } ptw_state_t;

    ptw_state_t current_state, next_state;
    logic store_tlb_req, send_tlb_req, tlb_ready;
    logic pmu_tlb_access, pmu_tlb_miss;
    tlb_req_tmp_storage_t tlb_req_tmp;

    always_comb begin
        store_tlb_req  = 1'b0;
        send_tlb_req   = 1'b0;
        write_tlb      = 1'b0;
        clean_tlb      = 1'b0;
        tlb_ready      = 1'b0;
        pmu_tlb_access = 1'b0;
        pmu_tlb_miss   = 1'b0;
        next_state     = current_state;  // By default, we remain in the same state
        case (current_state)
            PS_IDLE: begin
                tlb_ready = 1'b1;
                if (l1_l2_comms_i.req.valid) begin // if we have a valid request always try to clean the tlb
                    clean_tlb      = 1'b1;  // flush invalid pages, and not dirty page case
                    pmu_tlb_access = 1'b1;  // tlb access event for PMU
                    if (tlb_miss) begin
                        store_tlb_req = 1'b1;  // store req to send it in the next state
                        pmu_tlb_miss  = 1'b1;  // tlb miss event for PMU
                        next_state    = PS_SEND_REQUEST;
                    end
                end
            end
            PS_SEND_REQUEST: begin
                send_tlb_req = 1'b1;  // send stored request to PTW
                if (!ptw_l2_comm_i.ptw_ready && ptw_l2_comm_i.invalidate_tlb) begin
                    next_state = PS_IDLE;  // TLB request cancelled
                end else if (ptw_l2_comm_i.ptw_ready) begin
                    if (ptw_l2_comm_i.invalidate_tlb) begin
                        next_state = PS_INVALIDATED_WAIT_RESPONSE;
                    end else begin
                        next_state = PS_WAIT_RESPONSE;  // go to waiting for response state
                    end
                end
            end
            PS_WAIT_RESPONSE: begin
                if (ptw_l2_comm_i.resp.valid) begin
                    write_tlb  = 1'b1;
                    next_state = PS_IDLE;
                end else if (ptw_l2_comm_i.invalidate_tlb) begin
                    next_state = PS_INVALIDATED_WAIT_RESPONSE;
                end
            end
            PS_INVALIDATED_WAIT_RESPONSE: begin
                if (ptw_l2_comm_i.resp.valid) begin
                    next_state = PS_IDLE;  // we catched the request in progress
                end
            end
        endcase
    end

    always_ff @(posedge clk_i, negedge rstn_i) begin
        if (!rstn_i) begin
            current_state <= PS_IDLE;
        end else begin
            current_state <= next_state;
        end
    end


    // Eviction: serailised, one evict at a time for selected TLB miss
    logic has_invalid_entry, access_hit;
    logic unsigned [TLB_IDX_SIZE-1:0] eviction_idx, invalid_idx, plru_eviction_idx;

    assign access_hit = tlb_hit & l1_l2_comms_i.req.valid;

    pseudoLRU #(
        .ENTRIES(TLB_ENTRIES)
    ) tlb_PLRU (
        .clk_i            (clk_i),
        .rstn_i           (rstn_i),
        .access_hit_i     (access_hit),
        .access_idx_i     (hit_idx),
        .replacement_idx_o(plru_eviction_idx)
    );

    // Detect and identify if and entry is not being used
    always_comb begin
        invalid_idx       = '0;
        has_invalid_entry = ~tlb_entries[invalid_idx].nempty;
        while (!has_invalid_entry && (invalid_idx != $unsigned(
            TLB_ENTRIES - 1
        ))) begin
            invalid_idx       = trunc_tlb_idx_size_4in(invalid_idx + 1'b1);
            has_invalid_entry = ~tlb_entries[invalid_idx].nempty;
        end
    end

    assign eviction_idx = has_invalid_entry ? invalid_idx : plru_eviction_idx;

    // TLB-PTW request storage
    always_ff @(posedge clk_i, negedge rstn_i) begin
        if (!rstn_i) begin
            tlb_req_tmp <= '0;
        end else if (store_tlb_req) begin
            tlb_req_tmp.vpn       <= l1_l2_comms_i.req.vpn[VPN_SIZE-1:0];
            tlb_req_tmp.asid      <= l1_l2_comms_i.req.asid;
            tlb_req_tmp.store     <= l1_l2_comms_i.req.store;
            tlb_req_tmp.fetch     <= l1_l2_comms_i.req.instruction;
            tlb_req_tmp.write_idx <= eviction_idx;
        end
    end

    // TLB-PTW send request
    always_comb begin
        if (send_tlb_req) begin
            l2_ptw_comm_o.req.valid = 1'b1;
            l2_ptw_comm_o.req.vpn = tlb_req_tmp.vpn;
            l2_ptw_comm_o.req.asid = tlb_req_tmp.asid;
            l2_ptw_comm_o.req.prv = l1_l2_comms_i.priv_lvl; // note that we send the current cycle prv lvl
            l2_ptw_comm_o.req.store = tlb_req_tmp.store;
            l2_ptw_comm_o.req.fetch = tlb_req_tmp.fetch;
        end else begin
            l2_ptw_comm_o.req = '0;
        end
    end

    // PPN ASSIGNMENT
    ///////////////////////////////
    // PTW encodes superpages as if they were 4 KB pages (LowRISC convention).
    // For a leaf found at PTW level l, the lower (LEVELS-1-l)*PAGE_LVL_BITS
    // bits of the stored PPN are meaningless; those bits come from the VPN instead.
    //   l=LEVELS-1 (4 KB page): use stored PPN directly.
    //   l=0        (largest superpage): replace bottom (LEVELS-1)*PAGE_LVL_BITS bits.

    logic [PPN_SIZE-1:0] ppn_per_lvl[LEVELS];

    for (genvar ppn_l = 0; ppn_l < LEVELS; ppn_l++) begin : g_ppn_lvl
        localparam int SUPER_PAGE_BITS = (LEVELS - 1 - ppn_l) * PAGE_LVL_BITS;
        if (SUPER_PAGE_BITS == 0) begin : g_kilo
            // Deepest level (4 KB): PPN comes directly from the TLB entry.
            assign ppn_per_lvl[ppn_l] = tlb_entries[hit_idx].ppn;
        end else begin : g_super
            // Superpage: replace the lower SUPER_PAGE_BITS of PPN with VPN bits.
            assign ppn_per_lvl[ppn_l] = {
                tlb_entries[hit_idx].ppn[PPN_SIZE-1 : SUPER_PAGE_BITS],
                cache_vpn[SUPER_PAGE_BITS-1 : 0]
            };
        end
    end

    // OR per-level translated PPNs (at most one level hits at a time).
    logic [PPN_SIZE-1:0] ppn_translated;
    always_comb begin
        ppn_translated = '0;
        for (int l = 0; l < LEVELS; l++) begin
            ppn_translated |= ppn_per_lvl[l] & {PPN_SIZE{hit_per_lvl[l] & vm_enable & ~passthrough}};
        end
    end

    // TLB RESPONSE
    ///////////////////////////////
    // ---------------------------------------------------------
    // TLB Response
    // ---------------------------------------------------------
    assign l2_l1_comms_o[inflight_idx].tlb_ready = tlb_ready;
    assign l2_l1_comms_o[inflight_idx].resp.miss = tlb_miss_per_port[inflight_idx];
    // In translation mode: use per-level reconstructed PPN.
    // In passthrough/bare mode (vm_enable=0 or passthrough=1): PPN = VPN (identity).
    assign l2_l1_comms_o.resp.ppn =
    ppn_translated |
    {{(PPN_SIZE-VPN_SIZE-1){1'b0}}, cache_vpn & {(VPN_SIZE+1){~(vm_enable & ~passthrough)}}};
    // TODO: In L2, if the idx is found, there's no error to return as a PTW interface
    //       the error bit is set only when we use PTW and an error is returned from the PTW
    assign l2_l1_comms_o[inflight_idx].resp.xcpt.load = xcpt_lds[inflight_idx];
    assign l2_l1_comms_o[inflight_idx].resp.xcpt.store = xcpt_sts[inflight_idx];
    assign l2_l1_comms_o[inflight_idx].resp.xcpt.fetch = xcpt_ifs[inflight_idx];

    assign l2_l1_comms_o.resp.hit_idx = 'h0;

    // PMU EVENTS
    ///////////////////////////////
    assign pmu_tlb_access_o = pmu_tlb_access;
    assign pmu_tlb_miss_o = pmu_tlb_miss;

    ///////////////////////////////
    // TLB WRITE LOGIC
    ///////////////////////////////

    logic clear_tlb, write_tlb;
    logic [ TLB_ENTRIES-1:0] clear_mask;
    logic [TLB_IDX_SIZE-1:0] write_idx;

    assign write_idx = tlb_req_tmp.write_idx; // stored write_idx with the eviction idx (calculated in the first cycle of the req)
    always_ff @(posedge clk_i, negedge rstn_i) begin
        if (~rstn_i) begin
            for (int i = 0; i < TLB_ENTRIES; ++i) begin
                tlb_entries[i] <= '0;
            end
        end else begin
            if (clear_tlb) begin
                for (int i = 0; i < TLB_ENTRIES; ++i) begin
                    if (clear_mask[i]) tlb_entries[i] <= '0;
                end
            end else if (write_tlb) begin
                tlb_entries[write_idx].vpn <= tlb_req_tmp.vpn;
                tlb_entries[write_idx].asid <= tlb_req_tmp.asid;
                tlb_entries[write_idx].ppn <= ptw_l2_comm_i.resp.pte.ppn;
                tlb_entries[write_idx].level <= ptw_l2_comm_i.resp.level;
                tlb_entries[write_idx].dirty <= ptw_l2_comm_i.resp.pte.d;
                tlb_entries[write_idx].access <= ptw_l2_comm_i.resp.pte.a;
                tlb_entries[write_idx].perms.ur <= ptw_l2_comm_i.resp.pte.r & ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v; // this is slightly different
                tlb_entries[write_idx].perms.uw <= ptw_l2_comm_i.resp.pte.w & ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
                tlb_entries[write_idx].perms.ux <= ptw_l2_comm_i.resp.pte.x & ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
                tlb_entries[write_idx].perms.sr <= ptw_l2_comm_i.resp.pte.r & !ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
                tlb_entries[write_idx].perms.sw <= ptw_l2_comm_i.resp.pte.w & !ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
                tlb_entries[write_idx].perms.sx <= ptw_l2_comm_i.resp.pte.x & !ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
                tlb_entries[write_idx].valid <= !ptw_l2_comm_i.resp.error;
                tlb_entries[write_idx].nempty <= 1'b1;  // < can error and non-empty!
            end
        end
    end
endmodule

`IGNORE_WARNINGS_END
