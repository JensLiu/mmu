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

module l2_tlb
    import mmu_pkg::*;
#(
    parameter int unsigned NUM_TLB_PORTS = 1
) (
    input logic clk_i,  // System clock signal.
    input logic rstn_i, // System reset signal (active low).

    // TLB request-response
    input  l1_l2_comm_t l1_l2_comms_i[NUM_TLB_PORTS],
    output l2_l1_comm_t l2_l1_comms_o[NUM_TLB_PORTS],

    // PTW request-response
    input  ptw_l2_comm_t ptw_l2_comm_i,
    output l2_ptw_comm_t l2_ptw_comm_o
);



endmodule

`IGNORE_WARNINGS_END
