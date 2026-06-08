/*
 * Copyright 2023 BSC*
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

`IGNORE_WARNINGS_BEGIN

module pseudoLRU #(
    parameter int unsigned ENTRIES = 8
) (
    input  logic clk_i,
    input  logic rst_i,

    input  logic                       access_hit_i,  // only update the PLRU on a hit
    input  logic [$clog2(ENTRIES)-1:0] access_idx_i,
    output logic [$clog2(ENTRIES)-1:0] replacement_idx_o
);

    // Decode access_idx
    logic [ENTRIES-1:0] access_array;
    logic               found;
    logic               found2;

    logic [ENTRIES-1:0] replace_en;

    function logic [$clog2(ENTRIES)-1:0] cast_integer(input [31:0] iter);
        cast_integer = iter[$clog2(ENTRIES)-1:0];
    endfunction

    always_comb begin
        access_array = '0;  // don't care if no 'in' bits set
        found        = 0;
        for (int unsigned i = 0; (i < ENTRIES) && (!found); i++) begin
            if (i == access_idx_i) begin
                access_array[i] = 1'b1;
                found           = 1;
            end
        end
    end

    // ---------------------------------------------------------
    // PLRU - pseudo least recently used replacement
    // ---------------------------------------------------------
    // PLRU-tree indexing (8-entry example):
    //   lvl0        0
    //              / \
    //   lvl1      1   2
    //            /\   /\
    //   lvl2    3 4  5 6
    // On a hit the path nodes are set; the victim is decoded by traversing the
    // tree, complementing each node bit. See the lowRISC PLRU for the full form.
    logic [2*(ENTRIES-1)-1:0] plru_tree_r, plru_tree_n;
    always_comb begin : plru_replacement
        plru_tree_n = plru_tree_r;
        for (int unsigned i = 0; i < ENTRIES; i++) begin
            automatic int unsigned        idx_base = 0;
            automatic int unsigned        shift = 0;
            automatic logic        [31:0] new_index = '0;
            // We got a hit, so update the pointer (least recently used).
            if (access_array[i] & access_hit_i) begin
                for (int unsigned lvl = 0; lvl < $unsigned($clog2(ENTRIES)); lvl++) begin
                    idx_base                         = $unsigned((2 ** lvl) - 1);
                    // lvl0 <=> MSB, lvl1 <=> MSB-1, ...
                    shift                            = $unsigned($clog2(ENTRIES)) - lvl;
                    new_index                        = ~((i >> (shift - 1)) & 32'b1);
                    plru_tree_n[idx_base+(i>>shift)] = new_index[0];
                end
            end
        end
        // Decode the tree into write-enable signals: for each entry, traverse
        // the tree; if every node matches the entry's index bit, it is the
        // next victim.
        for (int unsigned i = 0; i < ENTRIES; i += 1) begin
            automatic logic        en = 1'b1;
            automatic logic [31:0] new_index2 = '0;
            automatic int unsigned idx_base, shift;
            for (int unsigned lvl = 0; lvl < $unsigned($clog2(ENTRIES)); lvl++) begin
                idx_base   = $unsigned((2 ** lvl) - 1);
                shift      = $unsigned($clog2(ENTRIES)) - lvl;
                new_index2 = (i >> (shift - 1)) & 32'b1;
                if (new_index2[0]) begin
                    en &= plru_tree_r[idx_base+(i>>shift)];
                end else begin
                    en &= ~plru_tree_r[idx_base+(i>>shift)];
                end
            end
            replace_en[i] = en;
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            plru_tree_r <= '0;
        end else begin
            plru_tree_r <= plru_tree_n;
        end
    end

    // Encode replace_en
    always_comb begin
        replacement_idx_o = '0;  // don't care if no 'in' bits set
        found2            = 1'b0;
        for (int unsigned iter = 0; (iter < $unsigned(ENTRIES)) && (!found2); iter++) begin
            if (replace_en[iter] == 1'b1) begin
                replacement_idx_o = cast_integer(iter);
                found2            = 1'b1;
            end
        end
    end

endmodule

`IGNORE_WARNINGS_END
