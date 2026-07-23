/*
 * Copyright 2026 BSC*
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

interface ptw_if;

    logic                   req_valid, req_ready;
    mmu_pkg::ptw_req_data_t  req_data;

    logic                   rsp_valid, rsp_ready;
    mmu_pkg::ptw_rsp_data_t  rsp_data;

    logic                   invalidate_tlb;

    // TLB side: drives requests, consumes responses.
    modport master (
        output req_valid,
        output req_data,
        input  req_ready,

        input  rsp_valid,
        input  rsp_data,
        output rsp_ready,

        input  invalidate_tlb
    );

    // PTW side: consumes requests, drives responses + the flush broadcast.
    modport slave (
        input  req_valid,
        input  req_data,
        output req_ready,

        output rsp_valid,
        output rsp_data,
        input  rsp_ready,

        output invalidate_tlb
    );

endinterface
