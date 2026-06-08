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

// Permission check for a resident TLB entry against the request type.
module pte_perm_check (
    input  mmu_pkg::tlb_entry_t tlb_entry_i,
    input  logic                sv_priv_lvl_i,
    input  logic                is_store_i,
    output logic                store_hit_o,
    output logic                read_ok_o,
    output logic                write_ok_o,
    output logic                exec_ok_o
);

    `UNUSED_VAR (tlb_entry_i)

    logic core_sum, core_mxr;
    assign core_sum = 1;
    assign core_mxr = 1;

    // Store-hit: a store to a dirty page (or one we lack write perms on, so the
    // STORE fault is raised) hits; a store to a clean writable page misses so
    // the walk marks it dirty in the page table.
    always_comb begin
        if (is_store_i) begin
            if (tlb_entry_i.dirty) begin
                store_hit_o = 1'b1;
            end else if (!write_ok_o) begin
                store_hit_o = 1'b1;
            end else begin
                store_hit_o = 1'b0;
            end
        end else begin
            store_hit_o = 1'b1;
        end
    end

    // Read permission. In supervisor mode SUM allows reading user pages and MXR
    // allows reading execute-only pages.
    always_comb begin
        if (sv_priv_lvl_i) begin
            if (core_sum) begin
                if (core_mxr) begin
                    read_ok_o = tlb_entry_i.perms.sr | tlb_entry_i.perms.ur | tlb_entry_i.perms.sx | tlb_entry_i.perms.ux;
                end else begin
                    read_ok_o = tlb_entry_i.perms.sr | tlb_entry_i.perms.ur;
                end
            end else begin
                if (core_mxr) begin
                    read_ok_o = tlb_entry_i.perms.sr | tlb_entry_i.perms.sx;
                end else begin
                    read_ok_o = tlb_entry_i.perms.sr;
                end
            end
        end else begin  // user mode
            if (core_mxr) begin
                read_ok_o = tlb_entry_i.perms.ur | tlb_entry_i.perms.ux;
            end else begin
                read_ok_o = tlb_entry_i.perms.ur;
            end
        end
    end

    // Write permission. SUM allows writing user pages in supervisor mode.
    always_comb begin
        if (sv_priv_lvl_i) begin
            if (core_sum) begin
                write_ok_o = tlb_entry_i.perms.sw | tlb_entry_i.perms.uw;
            end else begin
                write_ok_o = tlb_entry_i.perms.sw;
            end
        end else begin
            write_ok_o = tlb_entry_i.perms.uw;
        end
    end

    // Execute permission.
    assign exec_ok_o = sv_priv_lvl_i ? tlb_entry_i.perms.sx : tlb_entry_i.perms.ux;

endmodule
