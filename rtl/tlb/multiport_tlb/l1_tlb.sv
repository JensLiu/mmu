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


// Multiport L1 TLB.
//
//   core req[P] -> parallel-CAM tlb_storage (CAM + LRU + write) -> per-port
//                  datapath (perm check, PPN assembly, exceptions) -> core resp[P]
//   effective miss[P] -> request/deliver engine -> single fire-once L2 walk
//                        -> success: fill the CAM ;  error: per-port page fault
//
// A store to a clean (non-dirty) page, or a hit on an entry with its access
// bit clear, is NOT an effective hit: it falls into the miss path so the walk
// re-fetches the entry with the A/D bits set, and tlb_storage overwrites the
// stale copy in place (it de-dups by VPN on write).  Coalescing and fault
// delivery live in the engine; see l1_tlb_request_engine.
//
// Naming mirrors the L2 bank (l2_tlb_bank): tlb_read_hit / tlb_read_hit_entry,
// read_cam_hit, read_effective_hit, write_dirty_bit (= req set_dirty_bit).
module l1_tlb
    import mmu_pkg::*;
#(
    parameter int unsigned NUM_TLB_PORTS = 1,
    parameter int unsigned TLB_ENTRIES   = 8
) (
    input logic clk_i,  // System clock signal.
    input logic rstn_i, // System reset signal (active low).

    // TLB request-response (per-port handshake interface)
    core_tlb_if.slave core_if[NUM_TLB_PORTS],

    // Fire-once L2 TLB link
    inter_tlb_if.master l2_if
);

    // -------------------------------------------------------------------------
    // TLB Storage
    // -------------------------------------------------------------------------
    logic                        tlb_read_valid    [NUM_TLB_PORTS];
    logic                        tlb_read_ready    [NUM_TLB_PORTS];
    logic                        tlb_read_hit      [NUM_TLB_PORTS];
    logic       [ ASID_SIZE-1:0] tlb_read_asid     [NUM_TLB_PORTS];
    logic       [  VPN_SIZE-1:0] tlb_read_vpn      [NUM_TLB_PORTS];
    logic       [LEVEL_BITS-1:0] tlb_read_level    [NUM_TLB_PORTS];
    tlb_entry_t                  tlb_read_hit_entry[NUM_TLB_PORTS];

    logic                        tlb_write_valid;
    logic       [  VPN_SIZE-1:0] tlb_write_vpn;
    logic       [ ASID_SIZE-1:0] tlb_write_asid;
    tlb_entry_t                  tlb_write_entry;
    logic                        tlb_clear_valid;

    tlb_storage_parallel_cam #(
        .NUM_READ_PORTS (NUM_TLB_PORTS),
        .NUM_TLB_ENTRIES(TLB_ENTRIES)
    ) tlb_storage (
        .clk_i        (clk_i),
        .rstn_i       (rstn_i),
        .read_valid_i (tlb_read_valid),
        .read_ready_o (tlb_read_ready),
        .read_is_hit_o(tlb_read_hit),
        .read_asid_i  (tlb_read_asid),
        .read_vpn_i   (tlb_read_vpn),
        .read_level_o (tlb_read_level),
        .read_entry_o (tlb_read_hit_entry),
        .write_valid_i(tlb_write_valid),
        `UNUSED_PIN(write_ready_o),
        .write_vpn_i  (tlb_write_vpn),
        .write_asid_i (tlb_write_asid),
        .write_entry_i(tlb_write_entry),
        .clear_valid_i(tlb_clear_valid),
        `UNUSED_PIN(clear_ready_o)
    );

    // -------------------------------------------------------------------------
    // Per-port hit / effective-miss + permission datapath
    // -------------------------------------------------------------------------
    logic read_cam_hit[NUM_TLB_PORTS];
    logic read_effective_hit[NUM_TLB_PORTS];
    logic [NUM_TLB_PORTS-1:0] read_effective_miss;
    logic [NUM_TLB_PORTS-1:0] write_dirty_bit;  // per-port store-ness (= req set_dirty_bit)
    logic [NUM_TLB_PORTS-1:0] is_fetch;
    logic xcpt_ld[NUM_TLB_PORTS];
    logic xcpt_st[NUM_TLB_PORTS];
    logic xcpt_if[NUM_TLB_PORTS];
    logic [VPN_SIZE-1:0] vpn_per_port[NUM_TLB_PORTS];

    for (genvar p = 0; p < NUM_TLB_PORTS; p++) begin : g_datapath
        wire        vm_enable = core_if[p].req_data.vm_enable;
        wire        req_valid = core_if[p].req_valid;
        wire        store = core_if[p].req_data.store;
        wire        instr = core_if[p].req_data.instruction;
        tlb_entry_t entry = tlb_read_hit_entry[p];

        // A read only fires when the storage is ready; during a fill it blocks
        // reads, so that cycle is neither a hit nor a miss (the request holds).
        wire read_fire = tlb_read_valid[p] && tlb_read_ready[p];

        assign tlb_read_valid[p]  = req_valid && vm_enable;
        assign tlb_read_vpn[p]    = core_if[p].req_data.vpn;
        assign tlb_read_asid[p]   = core_if[p].req_data.asid;
        assign vpn_per_port[p]    = core_if[p].req_data.vpn;
        assign read_cam_hit[p]    = read_fire && tlb_read_hit[p];
        assign write_dirty_bit[p] = store;
        assign is_fetch[p]        = instr;

        logic store_hit, read_ok, write_ok, exec_ok;
        pte_perm_check pte_perm_check_it (
            .tlb_entry_i  (entry),
            .sv_priv_lvl_i(core_if[p].req_data.priv_lvl != '0),
            .is_store_i   (store),
            .store_hit_o  (store_hit),
            .read_ok_o    (read_ok),
            .write_ok_o   (write_ok),
            .exec_ok_o    (exec_ok)
        );

        // Effective hit: resident, accessed, and (for a store) dirty-or-not-
        // permitted.  A store-to-clean (store_hit==0) and a hit on an entry
        // with access==0 both fall through to the miss path so the walk sets
        // the A/D bits.  Mirrors l2_tlb_bank's read_effective_hit.
        assign read_effective_hit[p]  = read_cam_hit[p] && entry.access && store_hit;
        assign read_effective_miss[p] = read_fire && !read_effective_hit[p];

        // Permission faults are real, re-derivable from the resident entry, so
        // they ride the hit path (gated by the access type of this request).
        // PTW page faults (no resident entry) are added from the engine below.
        assign xcpt_if[p]             = read_effective_hit[p] && instr && !exec_ok;
        assign xcpt_st[p]             = read_effective_hit[p] && store && !write_ok;
        assign xcpt_ld[p]             = read_effective_hit[p] && !store && !instr && !read_ok;
    end

    // -------------------------------------------------------------------------
    // Request / deliver engine
    // -------------------------------------------------------------------------
    inter_tlb_req_data_t                     req_data    [NUM_TLB_PORTS];
    logic                [NUM_TLB_PORTS-1:0] resp_ready;
    logic                [NUM_TLB_PORTS-1:0] fault_valid;
    logic                                    fill_valid;
    tlb_entry_t                              fill_entry;
    logic                [     VPN_SIZE-1:0] fill_vpn;
    logic                [    ASID_SIZE-1:0] fill_asid;
    logic                                    invalidate;

    for (genvar p = 0; p < NUM_TLB_PORTS; p++) begin : g_req_data
        assign req_data[p].vpn           = core_if[p].req_data.vpn[VPN_SIZE-1:0];
        assign req_data[p].asid          = core_if[p].req_data.asid;
        assign req_data[p].prv           = core_if[p].req_data.priv_lvl;
        assign req_data[p].set_dirty_bit = write_dirty_bit[p];  // Rule 1: OR'd in the engine
        assign resp_ready[p]             = core_if[p].rsp_ready;
    end

    l1_tlb_request_engine #(
        .NUM_TLB_PORTS(NUM_TLB_PORTS)
    ) request_engine (
        .clk_i        (clk_i),
        .rstn_i       (rstn_i),
        .eff_miss_i   (read_effective_miss),
        .req_data_i   (req_data),
        .resp_ready_i (resp_ready),
        // TLB Refill (master)
        .fill_valid_o (fill_valid),
        .fill_entry_o (fill_entry),
        .fill_vpn_o   (fill_vpn),
        .fill_asid_o  (fill_asid),
        .fault_valid_o(fault_valid),
        .invalidate_o (invalidate),
        .l2_if        (l2_if)
    );

    // TLB write/clear: write only on a successful (non-error) refill; the engine
    // never asserts fill_valid on an error.  clear is the broadcast TLBI.
    assign tlb_write_valid = fill_valid;
    assign tlb_write_vpn   = fill_vpn;
    assign tlb_write_asid  = fill_asid;
    assign tlb_write_entry = fill_entry;
    assign tlb_clear_valid = invalidate;

    // -------------------------------------------------------------------------
    // PPN ASSIGNMENT
    // ----------------------------------------------------------
    // PTW encodes superpages as if they were 4 KB pages (LowRISC convention).
    // For a leaf found at PTW level l, the lower (LEVELS-1-l)*PAGE_LVL_BITS
    // bits of the stored PPN are meaningless; those bits come from the VPN instead.
    logic [PPN_SIZE-1:0] ppn_per_port_per_lvl   [NUM_TLB_PORTS] [LEVELS];
    logic [  LEVELS-1:0] hit_per_port_per_lvl   [NUM_TLB_PORTS];
    logic [PPN_SIZE-1:0] ppn_translated_per_port[NUM_TLB_PORTS];
    for (genvar p = 0; p < NUM_TLB_PORTS; ++p) begin : g_ppn_assignment
        wire        vm_enable = core_if[p].req_data.vm_enable;
        tlb_entry_t entry = tlb_read_hit_entry[p];
        `UNUSED_VAR(entry)  // only entry.ppn is used in the PPN assembly

        for (genvar lvl = 0; lvl < LEVELS; ++lvl) begin : g_hit_per_lvl
            assign hit_per_port_per_lvl[p][lvl] =
                read_cam_hit[p] && (tlb_read_level[p] == LEVEL_BITS'(lvl));
        end

        for (genvar ppn_l = 0; ppn_l < LEVELS; ppn_l++) begin : g_ppn_per_lvl
            localparam int SUPER_PAGE_BITS = (LEVELS - 1 - ppn_l) * PAGE_LVL_BITS;
            if (SUPER_PAGE_BITS == 0) begin : g_kilo
                assign ppn_per_port_per_lvl[p][ppn_l] = entry.ppn;
            end else begin : g_super
                assign ppn_per_port_per_lvl[p][ppn_l] = {
                    entry.ppn[PPN_SIZE-1 : SUPER_PAGE_BITS], vpn_per_port[p][SUPER_PAGE_BITS-1 : 0]
                };
            end
        end

        logic [PPN_SIZE-1:0] ppn_translation_mask_per_lvl[LEVELS];
        for (genvar lvl = 0; lvl < LEVELS; ++lvl) begin : g_ppn_translation_mask
            assign ppn_translation_mask_per_lvl[lvl] =
                {PPN_SIZE{hit_per_port_per_lvl[p][lvl] & vm_enable}};
        end
        always_comb begin : g_ppn_selection
            ppn_translated_per_port[p] = '0;
            for (int l = 0; l < LEVELS; l++) begin
                ppn_translated_per_port[p] |=
                    ppn_per_port_per_lvl[p][l] & ppn_translation_mask_per_lvl[l];
            end
        end
    end

    // -------------------------------------------------------------------------
    // TLB Response
    //   rsp_valid: a definitive answer exists (effective hit, fault, or a no-VM
    //   pass-through).  A still-walking miss simply leaves rsp_valid low.
    //   req_ready: the storage accepts the lookup this cycle (low during a
    //   fill/clear, so the requester holds).
    // -------------------------------------------------------------------------
    for (genvar p = 0; p < NUM_TLB_PORTS; ++p) begin : g_tlb_resp
        wire vm_enable = core_if[p].req_data.vm_enable;
        wire req_valid = core_if[p].req_valid;
        wire pass = !vm_enable;

        assign core_if[p].req_ready = tlb_read_ready[p];

        assign core_if[p].rsp_valid =
            req_valid && (pass || read_effective_hit[p] || fault_valid[p]);
        assign core_if[p].rsp_data.ppn = ppn_translated_per_port[p];

        // Exceptions: permission faults on the hit path, plus the PTW page
        // fault routed to this port by access type.
        assign core_if[p].rsp_data.xcpt.fetch = xcpt_if[p] || (fault_valid[p] && is_fetch[p]);
        assign core_if[p].rsp_data.xcpt.store =
            xcpt_st[p] || (fault_valid[p] && write_dirty_bit[p]);
        assign core_if[p].rsp_data.xcpt.load =
            xcpt_ld[p] || (fault_valid[p] && !write_dirty_bit[p] && !is_fetch[p]);

        assign core_if[p].rsp_data.hit_idx = '0;
    end

endmodule
