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
    parameter int unsigned NUM_DTLB_PORTS     = NUM_CORES * NUM_DTLBS_PER_CORE,
    parameter int unsigned NUM_ITLB_PORTS     = NUM_CORES
) (
    input logic clk_i,
    input logic rstn_i,

    // iTLB interface
    input  cache_tlb_comm_t icache_itlb_comm_i[NUM_ITLB_PORTS],
    output tlb_cache_comm_t itlb_icache_comm_o[NUM_ITLB_PORTS],

    // dTLB interface
    input  cache_tlb_comm_t core_dtlb_comm_i[NUM_DTLB_PORTS],
    output tlb_cache_comm_t dtlb_core_comm_o[NUM_DTLB_PORTS],

    // CSR interface
    input csr_ptw_comm_t csr_ptw_comm_i,

    // PTW - Memory Interface
    output ptw_dmem_comm_t ptw_dmem_comm_o,
    input  dmem_ptw_comm_t dmem_ptw_comm_i
);

    // Page Table Walker - iTLB/dTLB Connections
    // - Per-TLB ports connect to the serializers.
    // - The PTW itself exposes a single iTLB and a single dTLB port.
    tlb_ptw_comm_t itlb_ptw_comm, dtlb_ptw_comm;
    ptw_tlb_comm_t ptw_itlb_comm, ptw_dtlb_comm;

    tlb_ptw_comm_t itlb_ptw_comm_per_port[NUM_ITLB_PORTS];
    ptw_tlb_comm_t ptw_itlb_comm_per_port[NUM_ITLB_PORTS];

    tlb_ptw_comm_t dtlb_ptw_comm_per_port[NUM_DTLB_PORTS];
    ptw_tlb_comm_t ptw_dtlb_comm_per_port[NUM_DTLB_PORTS];

    // L1 iTLBs
    for (genvar i = 0; i < NUM_ITLB_PORTS; ++i) begin : g_itlb
        tlb l1_itlb_inst (
            .clk_i           (clk_i),
            .rstn_i          (rstn_i),
            .cache_tlb_comm_i(icache_itlb_comm_i[i]),
            .tlb_cache_comm_o(itlb_icache_comm_o[i]),
            .ptw_tlb_comm_i  (ptw_itlb_comm_per_port[i]),
            .tlb_ptw_comm_o  (itlb_ptw_comm_per_port[i]),
            .pmu_tlb_access_o(itlb_access_o),
            .pmu_tlb_miss_o  (itlb_miss_o)
        );
    end

    // L1 dTLBs
    tlb_cache_comm_t dtlb_core_comm_per_port[NUM_DTLB_PORTS];
    logic            dtlb_access_o_per_port [NUM_DTLB_PORTS];
    logic            dtlb_miss_o_per_port   [NUM_DTLB_PORTS];
    for (genvar i = 0; i < NUM_DTLB_PORTS; ++i) begin : g_dtlb
        tlb l1_dtlb_inst (
            .clk_i           (clk_i),
            .rstn_i          (rstn_i),
            .cache_tlb_comm_i(core_dtlb_comm_i[i]),
            .tlb_cache_comm_o(dtlb_core_comm_o[i]),
            .ptw_tlb_comm_i  (ptw_dtlb_comm_per_port[i]),
            .tlb_ptw_comm_o  (dtlb_ptw_comm_per_port[i]),
            .pmu_tlb_access_o(dtlb_access_o_per_port[i]),
            .pmu_tlb_miss_o  (dtlb_miss_o_per_port[i])
        );
    end

    // TODO: proof of concept, use a serialiser first
    l1_ltb_serialiser #(
        .NUM_TLB_PORTS(NUM_DTLB_PORTS)  // We only serialize dTLB requests since iTLBs are usually smaller and can be afforded their own PTW port
    ) dtlb_serialiser (
        .clk_i          (clk_i),
        .rstn_i         (rstn_i),
        .tlb_ptw_comms_i(dtlb_ptw_comm_per_port),
        .ptw_tlb_comms_o(ptw_dtlb_comm_per_port),
        .tlb_ptw_comm_o (dtlb_ptw_comm),
        .ptw_tlb_comm_i (ptw_dtlb_comm)
    );

    l1_ltb_serialiser #(
        .NUM_TLB_PORTS(NUM_ITLB_PORTS)
    ) itlb_serialiser (
        .clk_i          (clk_i),
        .rstn_i         (rstn_i),
        .tlb_ptw_comms_i(itlb_ptw_comm_per_port),  // wrap in array for uniformity
        .ptw_tlb_comms_o(ptw_itlb_comm_per_port),  // wrap in array for uniformity
        .tlb_ptw_comm_o (itlb_ptw_comm),
        .ptw_tlb_comm_i (ptw_itlb_comm)
    );

    ptw #(
        .XLEN(XLEN)
    ) ptw_inst (
        .clk_i (clk_i),
        .rstn_i(rstn_i),

        // iTLB request-response
        .itlb_ptw_comm_i(itlb_ptw_comm),
        .ptw_itlb_comm_o(ptw_itlb_comm),

        // dTLB request-response
        .dtlb_ptw_comm_i(dtlb_ptw_comm),
        .ptw_dtlb_comm_o(ptw_dtlb_comm),

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
