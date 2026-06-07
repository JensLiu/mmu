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
 */

`IGNORE_WARNINGS_BEGIN

// Page Walk Cache (PWC).
//
// Caches non-leaf PTEs (page-table pointers) so a later walk can skip the
// upper-level dmem reads.  Fully associative, keyed by the PTE's physical
// address (tag); the data is the next-level page-table base PPN.
//
// Same read/write/clear handshake as the TLB storages:
//  - Read : combinational lookup by tag.
//  - Write: install a pointer.  De-dup invariant: a matching tag is overwritten
//           in place, else an invalid slot is filled, else the PLRU victim.
//  - Clear: flush all (TLB invalidate / SATP write).
// Ready/valid exclusivity: clear > write > read.  The write is fire-and-forget
// (always accepted); a write coincident with clear is dropped, not deferred.
module ptw_cache
    import mmu_pkg::*;
#(
    parameter int unsigned NUM_ENTRIES = PTW_CACHE_SIZE,
    parameter int unsigned TAG_W       = SIZE_VADDR + 1,
    parameter int unsigned DATA_W      = PPN_SIZE
) (
    input logic clk_i,
    input logic rstn_i,

    // Read (combinational lookup by PTE physical address)
    input  logic              read_valid_i,
    output logic              read_ready_o,
    output logic              read_is_hit_o,
    input  logic [ TAG_W-1:0] read_tag_i,
    output logic [DATA_W-1:0] read_data_o,

    // Write (install a page-table pointer)
    input  logic              write_valid_i,
    output logic              write_ready_o,
    input  logic [ TAG_W-1:0] write_tag_i,
    input  logic [DATA_W-1:0] write_data_i,

    // Clear (flush all valid entries)
    input  logic clear_valid_i,
    output logic clear_ready_o
);
    localparam int unsigned IDX_W = (NUM_ENTRIES > 1) ? $clog2(NUM_ENTRIES) : 1;

    logic              valid_q[NUM_ENTRIES];
    logic [ TAG_W-1:0] tag_q  [NUM_ENTRIES];
    logic [DATA_W-1:0] data_q [NUM_ENTRIES];

    logic [NUM_ENTRIES-1:0] valid_vec, hit_vec, write_match_vec;
    always_comb begin
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            valid_vec[i]       = valid_q[i];
            hit_vec[i]         = valid_q[i] && (tag_q[i] == read_tag_i);
            write_match_vec[i] = valid_q[i] && (tag_q[i] == write_tag_i);
        end
    end

    // Handshake: clear > write > read (read is a combinational lookup).
    assign read_ready_o  = !write_valid_i && !clear_valid_i;
    assign write_ready_o = 1'b1;  // fire-and-forget; dropped on a coincident clear
    assign clear_ready_o = 1'b1;

    // Read hit + data (lowest matching index; de-dup keeps tags unique).
    logic [IDX_W-1:0] hit_idx;
    always_comb begin
        hit_idx = '0;
        for (int i = NUM_ENTRIES - 1; i >= 0; i--) if (hit_vec[i]) hit_idx = IDX_W'(i);
    end
    assign read_is_hit_o = |hit_vec;
    assign read_data_o   = data_q[hit_idx];

    // PLRU: update only on a read-hit access (matches the original behaviour).
    logic [IDX_W-1:0] plru_victim;
    wire              read_fire_hit = read_valid_i && read_ready_o && read_is_hit_o;
    pseudoLRU #(
        .ENTRIES(NUM_ENTRIES)
    ) ptw_plru (
        .clk_i            (clk_i),
        .rstn_i           (rstn_i),
        .access_hit_i     (read_fire_hit),
        .access_idx_i     (hit_idx),
        .replacement_idx_o(plru_victim)
    );

    // Victim: overwrite a matching tag (de-dup) -> invalid slot -> PLRU victim.
    logic [IDX_W-1:0] match_idx, free_idx;
    logic             free_found;
    always_comb begin
        match_idx  = '0;
        free_idx   = '0;
        free_found = 1'b0;
        for (int i = NUM_ENTRIES - 1; i >= 0; i--) begin
            if (write_match_vec[i]) match_idx = IDX_W'(i);
            if (!valid_vec[i]) begin
                free_idx   = IDX_W'(i);
                free_found = 1'b1;
            end
        end
    end
    wire [IDX_W-1:0] victim_idx = (|write_match_vec) ? match_idx
                                : free_found         ? free_idx
                                                     : plru_victim;

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            for (int i = 0; i < NUM_ENTRIES; i++) valid_q[i] <= 1'b0;
        end else if (clear_valid_i) begin
            // Flush; clear wins over a coincident write (the write is dropped).
            for (int i = 0; i < NUM_ENTRIES; i++) valid_q[i] <= 1'b0;
        end else if (write_valid_i) begin
            valid_q[victim_idx] <= 1'b1;
            tag_q[victim_idx]   <= write_tag_i;
            data_q[victim_idx]  <= write_data_i;
        end
    end

endmodule

`IGNORE_WARNINGS_END
