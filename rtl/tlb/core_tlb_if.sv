/*
 * Copyright 2025 BSC*
 * *Barcelona Supercomputing Center (BSC)
 *
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Licensed under the Solderpad Hardware License v 2.1 (the "License"); you
 * may not use this file except in compliance with the License, or, at your
 * option, the Apache License version 2.0. You may obtain a copy of the
 * License at
 *
 * https://solderpad.org/licenses/SHL-2.1/
 *
 * Unless required by applicable law or agreed to in writing, any work
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 */

// Core <-> L1 TLB interface (unified ready/valid).
//   req : core -> TLB
//   rsp : TLB -> core (asserted only on a definitive result; a miss holds rsp low
//         while the walk is in flight)
interface core_tlb_if;

    // A given master need not consume every field (e.g. the GPU adapter ignores
    // req_ready, rsp_data.hit_idx and the high PPN bits), so UNUSEDSIGNAL on the
    // interface nets is expected.
    /* verilator lint_off UNUSEDSIGNAL */
    logic                        req_valid, req_ready;
    mmu_pkg::core_tlb_req_data_t req_data;

    logic                        rsp_valid, rsp_ready;
    mmu_pkg::core_tlb_rsp_data_t rsp_data;
    /* verilator lint_on UNUSEDSIGNAL */

    modport master (  // translation requester (core)
        output req_valid,
        output req_data,
        input  req_ready,

        input  rsp_valid,
        input  rsp_data,
        output rsp_ready
    );

    modport slave (  // L1 TLB
        input  req_valid,
        input  req_data,
        output req_ready,

        output rsp_valid,
        output rsp_data,
        input  rsp_ready
    );

endinterface
