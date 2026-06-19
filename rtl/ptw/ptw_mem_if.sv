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

interface ptw_mem_if #(
    parameter  int unsigned XLEN        = mmu_pkg::XLEN,
    localparam int unsigned PADDR_WIDTH = mmu_pkg::PADDR_WIDTH,
    localparam int unsigned BEN_WIDTH   = XLEN / 8
);

    /* verilator lint_off UNUSEDSIGNAL */
    logic req_valid, req_ready;
    logic                  [PADDR_WIDTH-1:0] req_addr;
    mmu_pkg::ptw_mem_cmd_t                   req_cmd;
    logic                  [       XLEN-1:0] req_wdata;  // PTE write-back value / AMO-OR mask
    logic                  [  BEN_WIDTH-1:0] req_wbe;  // byte enables, PTE-relative
    logic rsp_valid, rsp_ready;
    logic [63:0] rsp_data;
    logic        rsp_error;  // access/bus fault on the PTE access (reads only)

    /* verilator lint_on UNUSEDSIGNAL */

    modport master(
        output req_valid,
        output req_addr,
        output req_cmd,
        output req_wdata,
        output req_wbe,
        input req_ready,

        input rsp_valid,
        input rsp_data,
        input rsp_error,
        output rsp_ready
    );

    modport slave(
        input req_valid,
        input req_addr,
        input req_cmd,
        input req_wdata,
        input req_wbe,
        output req_ready,

        output rsp_valid,
        output rsp_data,
        output rsp_error,
        input rsp_ready
    );

endinterface
