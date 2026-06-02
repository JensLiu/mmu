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
    parameter int unsigned NUM_DTLBS_PER_CORE = 1,
    parameter int unsigned L1_TLB_ENTRIES     = 16,
    parameter int unsigned L2_TLB_ENTRIES     = 32
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

    l1_l2_comm_t i_l1_l2_comm_per_core[NUM_CORES];
    l2_l1_comm_t i_l2_l1_comm_per_core[NUM_CORES];
    l1_l2_comm_t d_l1_l2_comm_per_core[NUM_CORES];
    l2_l1_comm_t d_l2_l1_comm_per_core[NUM_CORES];

    // L1 TLBs
    // Fully-associative, small size, multiport CAM could be feasible
    for (genvar i = 0; i < NUM_CORES; ++i) begin : g_itlb
        l1_tlb #(
            .NUM_TLB_PORTS(1),
            .TLB_ENTRIES  (L1_TLB_ENTRIES)
        ) l1_itlb_inst (
            .clk_i           (clk_i),
            .rstn_i          (rstn_i),
            .core_tlb_comms_i(core_itlb_comm_i[i+:1]),
            .tlb_core_comms_o(itlb_core_comm_o[i+:1]),
            .l2_l1_comm_i    (i_l2_l1_comm_per_core[i]),
            .l1_l2_comm_o    (i_l1_l2_comm_per_core[i])
        );

        // TODO: coalesce core requests:
        //       expensive to fit `NUM_DTLBS_PER_CORE` CAM in real GPU configuration.
        //       NVIDIA has 32 threads per warp.
        l1_tlb #(
            .NUM_TLB_PORTS(NUM_DTLBS_PER_CORE),
            .TLB_ENTRIES  (L1_TLB_ENTRIES)
        ) l1_dtlb_inst (
            .clk_i           (clk_i),
            .rstn_i          (rstn_i),
            .core_tlb_comms_i(core_dtlb_comm_i[i*NUM_DTLBS_PER_CORE+:NUM_DTLBS_PER_CORE]),
            .tlb_core_comms_o(dtlb_core_comm_o[i*NUM_DTLBS_PER_CORE+:NUM_DTLBS_PER_CORE]),
            .l2_l1_comm_i    (d_l2_l1_comm_per_core[i]),
            .l1_l2_comm_o    (d_l1_l2_comm_per_core[i])
        );
    end

    // Unified ready/valid PTW link, shared between the L2 frontend (tlb side)
    // and the PTW (ptw side).
    l2_ptw_if ptw_link ();

    // L1 <-> L2 fire-once links (interleaved: [i*2] = iTLB, [i*2+1] = dTLB).
    // Each L1 keeps its held-valid struct interface; an adapter bridges it to
    // the fire-once handshake the decoupled L2 frontend expects.
    l1_l2_if l1_l2_links[2 * NUM_CORES] ();

    for (genvar i = 0; i < NUM_CORES; ++i) begin : g_l1_l2_adapters
        l1_l2_adapter itlb_adapter (
            .clk_i       (clk_i),
            .rstn_i      (rstn_i),
            .l1_l2_comm_i(i_l1_l2_comm_per_core[i]),
            .l2_l1_comm_o(i_l2_l1_comm_per_core[i]),
            .ifc         (l1_l2_links[i*2])
        );
        l1_l2_adapter dtlb_adapter (
            .clk_i       (clk_i),
            .rstn_i      (rstn_i),
            .l1_l2_comm_i(d_l1_l2_comm_per_core[i]),
            .l2_l1_comm_o(d_l2_l1_comm_per_core[i]),
            .ifc         (l1_l2_links[i*2+1])
        );
    end

    // Decoupled shared L2 TLB: request scatter -> single bank (PTE cache) ->
    // response gather. NUM_BANKS = 1 today; bump it to bank by VPN.
    // The bank's CAM is single-ported - no NUM_CORES-wide parallel lookup.
    l2_tlb_frontend #(
        .NUM_REQS   (2 * NUM_CORES),
        .NUM_BANKS  (1),
        .TLB_ENTRIES(L2_TLB_ENTRIES)
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

        .ptw_if(ptw_link),

        // dmem request-response
        .dmem_ptw_comm_i(dmem_ptw_comm_i),
        .ptw_dmem_comm_o(ptw_dmem_comm_o),

        // csr interface
        .csr_ptw_comm_i(csr_ptw_comm_i),

        // pmu interface
        `UNUSED_PIN(pmu_ptw_hit_o),
        `UNUSED_PIN(pmu_ptw_miss_o)
    );

endmodule

`IGNORE_WARNINGS_END
