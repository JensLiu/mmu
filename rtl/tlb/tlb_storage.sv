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

module tlb_storage
    import mmu_pkg::*;
#(
    parameter int unsigned NUM_READ_PORTS = 1
) (
    input logic clk_i,  // System clock signal.
    input logic rstn_i, // System reset signal (active low).

    // read ports
    input  tlb_storage_read_comm_t tlb_storage_read_comms_i[NUM_READ_PORTS],
    output storage_tlb_read_comm_t storage_tlb_read_comms_o[NUM_READ_PORTS],

    // write port
    input tlb_storage_write_comm_t tlb_storage_write_comm_i,
    // output storage_tlb_write_comm_t storage_tlb_write_comm_o

    // Storage Status Outputs
    output logic                   tlb_has_invalid_entry_o,
    output logic [TLB_ENTRIES-1:0] some_tlb_invalid_entry_idx_o
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
    // --------------------------------------------------------
    logic                    hit_per_lvl_per_port[NUM_READ_PORTS] [LEVELS];
    logic                    hit_cam_per_port    [NUM_READ_PORTS];
    logic [TLB_IDX_SIZE-1:0] hit_idx_per_port    [NUM_READ_PORTS];
    logic [      VPN_SIZE:0] cache_vpn_per_port  [NUM_READ_PORTS];
    // CAM hit logic
    for (genvar port = 0; port < NUM_READ_PORTS; ++port) begin : g_cache_req
        logic [TLB_ENTRIES-1:0] hits_per_lvl[LEVELS];
        logic [TLB_ENTRIES-1:0] hits_cam;

        // Per-level hit vectors indexed by PTW level (0 = largest page).
        // For PTW level l, compare the top (l+1)*PAGE_LVL_BITS bits of the VPN:
        //   SV39 (LEVELS=3, PAGE_LVL_BITS=9): l=0→vpn[26:18], l=1→vpn[26:9], l=2→vpn[26:0]
        //   SV32 (LEVELS=2, PAGE_LVL_BITS=10): l=0→vpn[19:10], l=1→vpn[19:0]

        assign cache_vpn_per_port[port] = tlb_storage_read_comms_i[port].req.vpn;
        logic [ASID_SIZE-1:0] cache_asid;
        assign cache_asid = tlb_storage_read_comms_i[port].req.asid;

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
            assign hit_per_lvl_per_port[port][lvl] = |hits_per_lvl[lvl];
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
            hit_idx_per_port[port] = '0;  // don't care if no 'in' bits set
            found                  = 0;
            for (int i = 0; (i < TLB_ENTRIES) && (!found); i++) begin
                if (hits_cam[i] == 1'b1) begin
                    hit_idx_per_port[port] = trunc_tlb_idx_size($unsigned(i));
                    found                  = 1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Invalid Entry Tracking Logic
    // -------------------------------------------------------------------------
    logic unsigned [TLB_IDX_SIZE-1:0] invalid_entry_idx;
    logic                             invalid_entry_found;
    assign tlb_has_invalid_entry_o      = invalid_entry_found;
    assign some_tlb_invalid_entry_idx_o = invalid_entry_idx;
    always_comb begin
        for (int i = 0; i < TLB_ENTRIES; i++) begin
            // NOTE: difference between nempty and valid
            if (!tlb_entries[i].nempty) begin
                invalid_entry_idx   = trunc_tlb_idx_size($unsigned(i));
                invalid_entry_found = 1;
            end
        end
    end


    // -------------------------------------------------------------------------
    // Write Logic
    // -------------------------------------------------------------------------

    logic clear_tlb, write_tlb;
    logic       [ TLB_ENTRIES-1:0] clear_mask;
    logic       [TLB_IDX_SIZE-1:0] write_idx;
    tlb_entry_t                    write_entry;

    assign clear_tlb   = tlb_storage_write_comm_i.req.clear_tlb;
    assign write_tlb   = tlb_storage_write_comm_i.req.write_tlb;
    assign write_idx   = tlb_storage_write_comm_i.req.write_idx;
    assign write_entry = tlb_storage_write_comm_i.req.write_entry;

    for (genvar i = 0; i < TLB_ENTRIES; ++i) begin : g_clear_mask
        // flush also invalid entries
        assign clear_mask[i] = !tlb_entries[i].valid || tlb_storage_write_comm_i.req.clear_mask[i];
    end

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
                tlb_entries[write_idx] <= write_entry;
            end
        end
    end

    // Read Response Logic
    always_comb begin
        for (integer port = 0; port < NUM_READ_PORTS; ++port) begin
            storage_tlb_read_comms_o[port].resp.is_hit = hit_cam_per_port[port];
            storage_tlb_read_comms_o[port].resp.hit_idx = hit_idx_per_port[port];
            storage_tlb_read_comms_o[port].resp.hit_level = hit_per_lvl_per_port[port][0] ? 0 :
                                                              (hit_per_lvl_per_port[port][1] ? 1 :
                                                              (hit_per_lvl_per_port[port][2] ? 2 : '0));
            storage_tlb_read_comms_o[port].resp.entry = tlb_entries[hit_idx_per_port[port]];
        end
    end

endmodule

`IGNORE_WARNINGS_END
