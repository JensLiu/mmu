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


module mmu #(
    parameter int unsigned XLEN               = 32,
    parameter int unsigned NUM_CORES          = 1,
    parameter int unsigned NUM_DTLBS_PER_CORE = 1,
    parameter int unsigned L1_TLB_ENTRIES     = 16
) (
    input logic clk_i,
    input logic rst_i,

    core_tlb_if.slave itlb_core_if[                     NUM_CORES],
    core_tlb_if.slave dtlb_core_if[NUM_CORES * NUM_DTLBS_PER_CORE],
    ptw_mem_if.master ptw_mem_if,

    input mmu_pkg::csr_ptw_comm_t csr_ptw_comm_i
);

    localparam int unsigned NUM_PTWS = 1;

    inter_tlb_if #(.TAG_T(logic)) l1_l2_links[2 * NUM_CORES] ();
    inter_tlb_if #(.TAG_T(mmu_pkg::ptw_tag_t)) l2_ptw_links[NUM_PTWS] ();

    for (genvar i = 0; i < NUM_CORES; ++i) begin : g_l1_tlbs
        // L1 TLBs: Fully-associative, small size, multiport CAM could be feasible
        l1_tlb #(
            .NUM_TLB_PORTS(1),
            .TLB_ENTRIES  (L1_TLB_ENTRIES)
        ) l1_itlb_inst (
            .clk_i  (clk_i),
            .rst_i  (rst_i),
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
            .rst_i  (rst_i),
            .core_if(dtlb_core_if[i*NUM_DTLBS_PER_CORE+:NUM_DTLBS_PER_CORE]),
            .l2_if  (l1_l2_links[i*2+1])
        );
    end

    l2_tlb_frontend #(
        .NUM_REQS (2 * NUM_CORES),
        .NUM_BANKS(4),
        .NUM_PTWS (NUM_PTWS)
    ) l2_tlb_frontend_inst (
        .clk_i   (clk_i),
        .rst_i   (rst_i),
        .in_if (l1_l2_links),
        .out_if  (l2_ptw_links)
    );


    // TODO: Multiple PTWs per Socket.
    ptw #(
        .XLEN(XLEN)
    ) ptw_inst (
        .clk_i         (clk_i),
        .rst_i         (rst_i),
        .tlb_if        (l2_ptw_links[0]),
        .mem_if        (ptw_mem_if),
        .csr_ptw_comm_i(csr_ptw_comm_i)
    );

endmodule
