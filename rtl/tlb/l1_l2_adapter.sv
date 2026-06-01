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

// -----------------------------------------------------------------------------
// L1 <-> L2 adapter: bridges the L1 TLB's held-valid struct interface
// (l1_l2_comm_t / l2_l1_comm_t) to the fire-once l1_l2_if handshake, so the
// existing l1_tlb need not change while the decoupled L2 frontend is brought up.
//
// Fire-once gating: the L1 holds req.valid for the whole miss latency. We must
// present it to the L2 only ONCE - otherwise the request xbar would capture
// duplicates. sent_q is set on the request fire and cleared only when the L1
// finally drops req.valid (its miss resolved). The L1 is one-outstanding, so
// req.valid corresponds to a single stable miss until it is served.
// -----------------------------------------------------------------------------

module l1_l2_adapter
    import mmu_pkg::*;
(
    input logic clk_i,
    input logic rstn_i,

    // L1 side (held-valid structs, as l1_tlb drives/consumes them)
    input  l1_l2_comm_t l1_l2_comm_i,  // request from the L1 (req.valid held)
    output l2_l1_comm_t l2_l1_comm_o,  // response to the L1

    // L2 side (fire-once handshake)
    l1_l2_if.master ifc
);

    logic sent_q;
    wire  l1_req_valid = l1_l2_comm_i.valid;

    // ---- Request: present once, gated by sent_q ----
    assign ifc.req_valid = l1_req_valid && !sent_q;
    assign ifc.req_data  = l1_l2_comm_i.req;   // l1_l2_req_t aliases l1_l2_req_data_t

    wire req_fire = ifc.req_valid && ifc.req_ready;

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            sent_q <= 1'b0;
        end else if (!l1_req_valid) begin
            sent_q <= 1'b0;   // L1 miss resolved -> ready for the next request
        end else if (req_fire) begin
            sent_q <= 1'b1;   // captured by the L2 -> do not re-present
        end
    end

    // ---- Response: the L1 registers it internally, so it always accepts ----
    assign ifc.rsp_ready = 1'b1;

    always_comb begin
        l2_l1_comm_o                = '0;
        l2_l1_comm_o.resp_valid     = ifc.rsp_valid;   // handshake carries validity
        l2_l1_comm_o.resp.error     = ifc.rsp_data.error;
        l2_l1_comm_o.resp.tlb_entry = ifc.rsp_data.tlb_entry;
        l2_l1_comm_o.invalidate_tlb = ifc.invalidate_tlb;
    end

endmodule

`IGNORE_WARNINGS_END
