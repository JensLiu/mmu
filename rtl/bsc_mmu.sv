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


module bsc_mmu
    import mmu_pkg::*;
#(
    parameter int unsigned XLEN               = 32,
    parameter int unsigned NUM_CORES          = 1,
    parameter int unsigned NUM_DTLBS_PER_CORE = 1,
    parameter int unsigned L1_TLB_ENTRIES     = 16
) (
    input logic clk_i,
    input logic rstn_i,

    // iTLB / dTLB request-response (per-port handshake interfaces)
    core_tlb_if.slave itlb_core_if[NUM_CORES],
    core_tlb_if.slave dtlb_core_if[NUM_CORES * NUM_DTLBS_PER_CORE],

    // CSR interface
    input csr_ptw_comm_t csr_ptw_comm_i,

    // PTW - Memory Interface
    output ptw_dmem_comm_t ptw_dmem_comm_o,
    input  dmem_ptw_comm_t dmem_ptw_comm_i
);

    // Unified ready/valid PTW links, shared between the L2 frontend (tlb side)
    // and the PTW pool (ptw side).  NUM_PTWS>1 also needs a dmem arbiter, so it
    // stays 1 until that is built.
    localparam int unsigned NUM_PTWS = 1;
    ptw_if ptw_link[NUM_PTWS] ();

    // L1 <-> L2 fire-once links (interleaved: [i*2] = iTLB, [i*2+1] = dTLB).
    // Each L1 TLB drives its inter_tlb_if master directly.
    inter_tlb_if l1_l2_links[2 * NUM_CORES] ();

    // L1 TLBs
    // Fully-associative, small size, multiport CAM could be feasible
    for (genvar i = 0; i < NUM_CORES; ++i) begin : g_itlb
        l1_tlb #(
            .NUM_TLB_PORTS(1),
            .TLB_ENTRIES  (L1_TLB_ENTRIES)
        ) l1_itlb_inst (
            .clk_i  (clk_i),
            .rstn_i (rstn_i),
            .core_if(itlb_core_if[i+:1]),
            .l2_if  (l1_l2_links[i*2])
        );

        // TODO: coalesce core requests:
        //       expensive to fit `NUM_DTLBS_PER_CORE` CAM in real GPU configuration.
        //       NVIDIA has 32 threads per warp.
        l1_tlb #(
            .NUM_TLB_PORTS(NUM_DTLBS_PER_CORE),
            .TLB_ENTRIES  (L1_TLB_ENTRIES)
        ) l1_dtlb_inst (
            .clk_i  (clk_i),
            .rstn_i (rstn_i),
            .core_if(dtlb_core_if[i*NUM_DTLBS_PER_CORE+:NUM_DTLBS_PER_CORE]),
            .l2_if  (l1_l2_links[i*2+1])
        );
    end

    // Decoupled shared L2 TLB: request scatter -> single bank (PTE cache) ->
    // response gather. NUM_BANKS = 1 today; bump it to bank by VPN.
    // The bank's CAM is single-ported - no NUM_CORES-wide parallel lookup.
    l2_tlb_frontend #(
        .NUM_REQS   (2 * NUM_CORES),
        .NUM_BANKS  (4),
        .NUM_PTWS   (NUM_PTWS)
    ) l2_tlb_frontend_inst (
        .clk_i        (clk_i),
        .rstn_i       (rstn_i),
        .l1_l2_if     (l1_l2_links),
        .ptw_if       (ptw_link)
    );


    // TODO: Multiple PTWs per Socket.
    ptw #(
        .XLEN(XLEN)
    ) ptw_inst (
        .clk_i          (clk_i),
        .rstn_i         (rstn_i),

        .ptw_if(ptw_link[0]),

        // dmem request-response
        .dmem_ptw_comm_i(dmem_ptw_comm_i),
        .ptw_dmem_comm_o(ptw_dmem_comm_o),

        // csr interface
        .csr_ptw_comm_i(csr_ptw_comm_i)
    );

endmodule
