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

module bsc_mmu
    import mmu_pkg::*;
#(
    parameter int unsigned XLEN               = 32,
    parameter int unsigned NUM_CORES          = 1,
    parameter int unsigned NUM_DTLBS_PER_CORE = 1
) (
    input logic clk_i,
    input logic rstn_i,

    // iTLB interface
    input  core_tlb_comm_t core_itlb_comm_i[NUM_CORES],
    output tlb_core_comm_t itlb_core_comm_o[NUM_CORES],

    // dTLB interface
    input  core_tlb_comm_t core_dtlb_comm_i[NUM_CORES * NUM_DTLBS_PER_CORE],
    output tlb_core_comm_t dtlb_core_comm_o[NUM_CORES * NUM_DTLBS_PER_CORE],

    // CSR interface
    input csr_ptw_comm_t csr_ptw_comm_i,

    // PTW - Memory Interface
    output ptw_dmem_comm_t ptw_dmem_comm_o,
    input  dmem_ptw_comm_t dmem_ptw_comm_i
);

    tlb_ptw_comm_t i_l1_l2_comm_per_core[NUM_CORES];
    ptw_tlb_comm_t i_l2_l1_comm_per_core[NUM_CORES];
    tlb_ptw_comm_t d_l1_l2_comm_per_core[NUM_CORES];
    ptw_tlb_comm_t d_l2_l1_comm_per_core[NUM_CORES];

    // L1 TLBs
    for (genvar i = 0; i < NUM_CORES; ++i) begin : g_itlb
        l1_tlb #(
            .NUM_TLB_PORTS(1)
        ) l1_itlb_inst (
            .clk_i           (clk_i),
            .rstn_i          (rstn_i),
            .core_tlb_comms_i(core_itlb_comm_i[i+:1]),
            .tlb_core_comms_o(itlb_core_comm_o[i+:1]),
            .l2_l1_comm_i    (i_l2_l1_comm_per_core[i]),
            .l1_l2_comm_o    (i_l1_l2_comm_per_core[i])
        );

        l1_tlb #(
            .NUM_TLB_PORTS(NUM_DTLBS_PER_CORE)
        ) l1_dtlb_inst (
            .clk_i           (clk_i),
            .rstn_i          (rstn_i),
            .core_tlb_comms_i(core_dtlb_comm_i[i*NUM_DTLBS_PER_CORE+:NUM_DTLBS_PER_CORE]),
            .tlb_core_comms_o(dtlb_core_comm_o[i*NUM_DTLBS_PER_CORE+:NUM_DTLBS_PER_CORE]),
            .l2_l1_comm_i    (d_l2_l1_comm_per_core[i]),
            .l1_l2_comm_o    (d_l1_l2_comm_per_core[i])
        );
    end

    // TODO: Temporary solution
    l1_l2_comm_t i_l1_l2_comm, d_l1_l2_comm;
    l2_l1_comm_t i_l2_l1_comm, d_l2_l1_comm;
    l1_tlb_serialiser #(
        .NUM_TLB_PORTS(NUM_CORES)  // one port per l1 tlb
    ) itlb_ptw_serialiser (
        .clk_i          (clk_i),
        .rstn_i         (rstn_i),
        .tlb_ptw_comms_i(i_l1_l2_comm_per_core),
        .ptw_tlb_comms_o(i_l2_l1_comm_per_core),
        .tlb_ptw_comm_o (i_l1_l2_comm),
        .ptw_tlb_comm_i (i_l2_l1_comm)
    );

    l1_tlb_serialiser #(
        .NUM_TLB_PORTS(NUM_CORES)  // one port per l1 tlb
    ) dtlb_ptw_serialiser (
        .clk_i          (clk_i),
        .rstn_i         (rstn_i),
        .tlb_ptw_comms_i(d_l1_l2_comm_per_core),
        .ptw_tlb_comms_o(d_l2_l1_comm_per_core),
        .tlb_ptw_comm_o (d_l1_l2_comm),
        .ptw_tlb_comm_i (d_l2_l1_comm)
    );

    ptw #(
        .XLEN(XLEN)
    ) ptw_inst (
        .clk_i (clk_i),
        .rstn_i(rstn_i),

        // iTLB request-response
        .itlb_ptw_comm_i(i_l1_l2_comm),
        .ptw_itlb_comm_o(i_l2_l1_comm),

        // dTLB request-response
        .dtlb_ptw_comm_i(d_l1_l2_comm),
        .ptw_dtlb_comm_o(d_l2_l1_comm),

        // dmem request-response
        .dmem_ptw_comm_i(dmem_ptw_comm_i),
        .ptw_dmem_comm_o(ptw_dmem_comm_o),

        // csr interface
        .csr_ptw_comm_i(csr_ptw_comm_i),

        // pmu interface
        .pmu_ptw_hit_o (pmu_ptw_hit_o),
        .pmu_ptw_miss_o(pmu_ptw_miss_o)
    );

endmodule

`IGNORE_WARNINGS_END
