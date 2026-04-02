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
    parameter int unsigned NUM_DTLB_PORTS = 1,
    parameter int unsigned XLEN = 32
) (
    input logic clk_i,
    input logic rstn_i,

    // iTLB Interface
    input  cache_tlb_comm_t icache_itlb_comm_i,
    output tlb_cache_comm_t itlb_icache_comm_o,

    // dTLB Interface
    input  cache_tlb_comm_t core_dtlb_comm_i[NUM_DTLB_PORTS],
    output tlb_cache_comm_t dtlb_core_comm_o[NUM_DTLB_PORTS],

    // CSR Interface
    input csr_ptw_comm_t csr_ptw_comm_i,

    // PTW - Memory Interface
    output ptw_dmem_comm_t ptw_dmem_comm_o,
    input  dmem_ptw_comm_t dmem_ptw_comm_i,

    // PMU Events
    output logic itlb_access_o,
    output logic itlb_miss_o,
    output logic dtlb_access_o,
    output logic dtlb_miss_o,
    output logic pmu_ptw_hit_o,
    output logic pmu_ptw_miss_o
);

  // Page Table Walker - iTLB/dTLB Connections
  tlb_ptw_comm_t itlb_ptw_comm, dtlb_ptw_comm, dtlb_ptw_comm_per_port[NUM_DTLB_PORTS];
  ptw_tlb_comm_t ptw_itlb_comm, ptw_dtlb_comm, ptw_dtlb_comm_per_port[NUM_DTLB_PORTS];

  tlb itlb (
      .clk_i(clk_i),
      .rstn_i(rstn_i),
      .cache_tlb_comm_i(icache_itlb_comm_i),
      .tlb_cache_comm_o(itlb_icache_comm_o),
      .ptw_tlb_comm_i(ptw_itlb_comm),
      .tlb_ptw_comm_o(itlb_ptw_comm),
      .pmu_tlb_access_o(itlb_access_o),
      .pmu_tlb_miss_o(itlb_miss_o)
  );

  // dTLB instances
  tlb_cache_comm_t dtlb_core_comm_per_port[NUM_DTLB_PORTS];
  logic dtlb_access_o_per_port[NUM_DTLB_PORTS];
  logic dtlb_miss_o_per_port[NUM_DTLB_PORTS];
  for (genvar i = 0; i < NUM_DTLB_PORTS; ++i) begin : g_dtlb
    tlb dtlb_inst (
        .clk_i(clk_i),
        .rstn_i(rstn_i),
        .cache_tlb_comm_i(core_dtlb_comm_i[i]),
        .tlb_cache_comm_o(dtlb_core_comm_o[i]),
        .ptw_tlb_comm_i(ptw_dtlb_comm_per_port[i]),
        .tlb_ptw_comm_o(dtlb_ptw_comm_per_port[i]),
        .pmu_tlb_access_o(dtlb_access_o_per_port[i]),
        .pmu_tlb_miss_o(dtlb_miss_o_per_port[i])
    );
  end

  localparam int unsigned DTLB_PORT_IDX_W = (NUM_DTLB_PORTS > 1) ? $clog2(NUM_DTLB_PORTS) : 1;
  logic dtlb_sel_valid;
  logic [DTLB_PORT_IDX_W-1:0] dtlb_sel_idx;
  logic dtlb_inflight_valid_d, dtlb_inflight_valid_q;
  logic [DTLB_PORT_IDX_W-1:0] dtlb_inflight_idx_d, dtlb_inflight_idx_q;

  // TLB-PTW request arbitration
  always_comb begin : arb_dtlb_ptw
    dtlb_ptw_comm  = '0;
    dtlb_sel_valid = 1'b0;
    dtlb_sel_idx   = '0;
    for (integer i = 0; i < NUM_DTLB_PORTS; ++i) begin
      if (!dtlb_sel_valid && dtlb_ptw_comm_per_port[i].req.valid) begin
        dtlb_sel_valid = 1'b1;
        dtlb_sel_idx   = DTLB_PORT_IDX_W'(i);
        dtlb_ptw_comm  = dtlb_ptw_comm_per_port[i];
      end
    end
  end

  // Track which dTLB port has the in-flight PTW transaction.
  always_comb begin : dtlb_inflight_next
    dtlb_inflight_valid_d = dtlb_inflight_valid_q;
    dtlb_inflight_idx_d   = dtlb_inflight_idx_q;

    // PTW accepts a new dTLB request only when it is ready.
    if (ptw_dtlb_comm.ptw_ready && dtlb_sel_valid) begin
      dtlb_inflight_valid_d = 1'b1;
      dtlb_inflight_idx_d   = dtlb_sel_idx;
    end

    // Clear in-flight owner once PTW returns a response.
    if (ptw_dtlb_comm.resp.valid) begin
      dtlb_inflight_valid_d = 1'b0;
    end

  end

  always_ff @(posedge clk_i or negedge rstn_i) begin : dtlb_inflight_ff
    if (!rstn_i) begin
      dtlb_inflight_valid_q <= 1'b0;
      dtlb_inflight_idx_q   <= '0;
    end else begin
      dtlb_inflight_valid_q <= dtlb_inflight_valid_d;
      dtlb_inflight_idx_q   <= dtlb_inflight_idx_d;
    end
  end

  // Route PTW status to all dTLBs, but gate ready/response to the selected owner.
  for (genvar i = 0; i < NUM_DTLB_PORTS; ++i) begin : g_dtlb_ptw_rsp
    always_comb begin
      ptw_dtlb_comm_per_port[i] = '0;
      ptw_dtlb_comm_per_port[i].ptw_status = ptw_dtlb_comm.ptw_status;
      ptw_dtlb_comm_per_port[i].invalidate_tlb = ptw_dtlb_comm.invalidate_tlb;

      if (!dtlb_inflight_valid_q) begin
        ptw_dtlb_comm_per_port[i].ptw_ready = ptw_dtlb_comm.ptw_ready && dtlb_sel_valid
            && (dtlb_sel_idx == DTLB_PORT_IDX_W'(i));
      end else begin
        ptw_dtlb_comm_per_port[i].ptw_ready = 1'b0;
      end

      ptw_dtlb_comm_per_port[i].resp.valid = ptw_dtlb_comm.resp.valid && dtlb_inflight_valid_q
          && (dtlb_inflight_idx_q == DTLB_PORT_IDX_W'(i));
      ptw_dtlb_comm_per_port[i].resp.error = ptw_dtlb_comm.resp.error;
      ptw_dtlb_comm_per_port[i].resp.level = ptw_dtlb_comm.resp.level;
      ptw_dtlb_comm_per_port[i].resp.pte = ptw_dtlb_comm.resp.pte;
    end
  end

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
