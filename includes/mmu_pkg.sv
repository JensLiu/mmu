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

package mmu_pkg;

    `IGNORE_WARNINGS_BEGIN

    // MMU Parameters - conditional on XLEN
    // SV32 (XLEN=32): 2-level, 10-bit VPN fields, 22-bit PPN, 4-byte PTEs
    // SV39 (XLEN=64): 3-level, 9-bit VPN fields, 44-bit PPN, 8-byte PTEs

`ifdef XLEN_64
    // SV39 Parameters (64-bit)
    parameter VPN_SIZE = 27;  // Total VPN bits (3 levels × 9 bits)
    parameter PPN_SIZE = 44;  // Physical page number bits
    parameter SIZE_VADDR = 39;  // Virtual address bits
    parameter ASID_SIZE = 16;  // Address space ID bits
    parameter LEVELS = 3;  // Page table levels
    parameter PAGE_LVL_BITS = 9;  // VPN bits per level
    parameter PTESIZE = 8;  // PTE size in bytes
`else
    // SV32 Parameters (32-bit)
    parameter VPN_SIZE = 20;  // Total VPN bits (2 levels × 10 bits)
    parameter PPN_SIZE = 22;  // Physical page number bits (34-bit PA - 12-bit offset)
    parameter SIZE_VADDR = 32;  // Virtual address bits
    parameter ASID_SIZE = 9;  // Address space ID bits
    parameter LEVELS = 2;  // Page table levels
    parameter PAGE_LVL_BITS = 10;  // VPN bits per level
    parameter PTESIZE = 4;  // PTE size in bytes
`endif

    parameter PTW_CACHE_SIZE = $clog2(LEVELS * 2);

`ifdef XLEN_64
    // SV39 page sizes
    parameter [1:0] GIGA_PAGE = 2'b00;  // 1 GiB Page (level 0)
    parameter [1:0] MEGA_PAGE = 2'b01;  // 2 MiB Page (level 1)
    parameter [1:0] KILO_PAGE = 2'b10;  // 4 KiB Page (level 2)
`else
    // SV32 page sizes
    parameter [1:0] MEGA_PAGE = 2'b00;  // 4 MiB Page (level 0)
    parameter [1:0] KILO_PAGE = 2'b01;  // 4 KiB Page (level 1)
    parameter [1:0] GIGA_PAGE = 2'b11;  // Not used in SV32 (placeholder)
`endif

    localparam LEVEL_BITS = $clog2(LEVELS);  // Bits needed to encode page levels

    // ---------------------------------------------------------
    // PTE structure - format differs between SV32 and SV39
    // ---------------------------------------------------------
    // SV32: [31:20]=PPN[1], [19:10]=PPN[0], [9:8]=RSW, [7:0]=flags
    // SV39: [53:10]=PPN, [9:8]=RSW, [7:0]=flags
    typedef struct packed {
        logic [PPN_SIZE-1:0] ppn;
        logic [1:0]          rfs;
        logic                d;
        logic                a;
        logic                g;
        logic                u;
        logic                x;
        logic                w;
        logic                r;
        logic                v;
    } pte_t;

    typedef struct packed {
        logic        sd;
        logic [26:0] zero5;
        logic [1:0]  sxl;
        logic [1:0]  uxl;
        logic [8:0]  zero4;
        logic        tsr;
        logic        tw;
        logic        tvm;
        logic        mxr;
        logic        sum;
        logic        mprv;
        logic [1:0]  xs;
        logic [1:0]  fs;
        logic [1:0]  mpp;
        logic [1:0]  zero3;
        logic        spp;
        logic        mpie;
        logic        zero2;
        logic        spie;
        logic        upie;
        logic        mie;
        logic        zero1;
        logic        sie;
        logic        uie;
    } csr_mstatus_t;

    // ---------------------------------------------------------
    //  TLB Entry Structure
    // ---------------------------------------------------------

    typedef struct packed {
        logic ur;
        logic uw;
        logic ux;
        logic sr;
        logic sw;
        logic sx;
    } tlb_entry_permissions_t;  // TLB page entry permissions.

    typedef struct packed {
        logic [VPN_SIZE-1:0]    vpn;
        logic [ASID_SIZE-1:0]   asid;
        logic [PPN_SIZE-1:0]    ppn;
        logic [1:0]             level;
        logic                   dirty;
        logic access;
        tlb_entry_permissions_t perms;
        logic                   valid;
    } tlb_entry_t;

    // ---------------------------------------------------------
    //  Core-TLB communication
    // ---------------------------------------------------------
    typedef struct packed {
        logic                 valid;
        logic [ASID_SIZE-1:0] asid;
        logic [VPN_SIZE-1:0]  vpn;
        logic                 passthrough;
        logic                 instruction;
        logic                 store;
    } core_tlb_req_t;

    typedef struct packed {
        core_tlb_req_t req;
        logic [1:0]    priv_lvl;
        logic          vm_enable;
        logic          resp_ready;  // requester ready to accept the response (backpressure)
    } core_tlb_comm_t;

    typedef struct packed {
        logic load;
        logic store;
        logic fetch;
    } tlb_ex_t;  // Exception origin.

    typedef struct packed {
        logic                valid;  // a definitive answer is available (hit translation or fault)
        logic                miss;
        logic [PPN_SIZE-1:0] ppn;
        tlb_ex_t             xcpt;
        logic [7:0]          hit_idx;
    } tlb_core_resp_t;

    typedef struct packed {tlb_core_resp_t resp;} tlb_core_comm_t;

    // Handshake payloads for core_tlb_if (valid/ready lives on the interface, so
    // these carry no valid bit). priv_lvl/vm_enable are per-request context.
    typedef struct packed {
        logic [ASID_SIZE-1:0] asid;
        logic [ VPN_SIZE-1:0] vpn;
        logic                 instruction;
        logic                 store;
        logic [1:0]           priv_lvl;
        logic                 vm_enable;  // per-request; clear it to bypass translation
    } core_tlb_req_data_t;

    typedef struct packed {
        logic [PPN_SIZE-1:0] ppn;
        tlb_ex_t             xcpt;
        logic [7:0]          hit_idx;
    } core_tlb_rsp_data_t;


    // ---------------------------------------------------------
    //  L1-L2 TLB communication
    // ---------------------------------------------------------
    typedef struct packed {
        logic [VPN_SIZE-1:0]  vpn;
        logic [ASID_SIZE-1:0] asid;
        logic [1:0]           prv;
        logic                 set_dirty_bit;
    } inter_tlb_req_data_t;

    typedef struct packed {
        logic       error;
        tlb_entry_t tlb_entry;
    } inter_tlb_rsp_data_t;

    // ---------------------------------------------------------
    // L2 TLB - PTW communication
    // ---------------------------------------------------------
    // The PTW echoes this tag opaquely. It has two owners with disjoint fields:
    //   .slot - the requesting bank's MSHR slot id (bank-private; routes the fill)
    //   .bank - the bank id, stamped by the PTW scheduler (routes the response)
    // Each layer touches only its own field, so neither hard-codes bit positions.
    // Widths are design maxima (>= any bank's MSHR_TAG_W / clog2(NUM_BANKS)).
    parameter PTW_TAG_SLOT_W = 4;  // up to 16 MSHR slots per bank
    parameter PTW_TAG_BANK_W = 4;  // up to 16 banks
    parameter PTW_TAG_TLB_SET_W = 8;  // up to 256 TLB sets
    parameter PTW_TAG_W = PTW_TAG_BANK_W + PTW_TAG_SLOT_W + PTW_TAG_TLB_SET_W;

    typedef struct packed {
        logic [PTW_TAG_BANK_W-1:0]    bank;       // owned by the scheduler
        logic [PTW_TAG_SLOT_W-1:0]    mshr_slot;  // owned by the bank's MSHR
        logic [PTW_TAG_TLB_SET_W-1:0] tlb_set;    // owned by the TLB
    } ptw_tag_t;

    typedef struct packed {
        logic [VPN_SIZE-1:0]  vpn;
        logic [ASID_SIZE-1:0] asid;
        logic [1:0]           prv;
        logic                 store;
        logic                 fetch;
        ptw_tag_t             tag;
    } ptw_req_data_t;

    typedef struct packed {
        pte_t                  pte;
        logic [LEVEL_BITS-1:0] level;
        logic                  error;
        ptw_tag_t              tag;
    } ptw_rsp_data_t;

    // ---------------------------------------------------------
    // PTW Internal
    // ---------------------------------------------------------
    typedef struct packed {
        logic                valid;
        logic [SIZE_VADDR:0] tags;
        logic [PPN_SIZE-1:0] data;
    } ptw_ptecache_entry_t;

    // ---------------------------------------------------------
    // PTW-DRAM
    // ---------------------------------------------------------
    // Page-table-walker memory command (ptw_mem_if). A plain WRITE is sufficient
    // while page tables are static (Vortex); AMO_OR is the spec-compliant atomic
    // A/D update for systems that mutate page tables concurrently.
    typedef enum logic [1:0] {
        PTW_MEM_READ   = 2'd0,
        PTW_MEM_WRITE  = 2'd1,
        PTW_MEM_AMO_OR = 2'd2
    } ptw_mem_cmd_e;

    // ---------------------------------------------------------
    // CSR interface
    // ---------------------------------------------------------
    typedef struct packed {
        logic [63:0]  satp;
        logic         flush;
        csr_mstatus_t mstatus;
    } csr_ptw_comm_t;

endpackage

`IGNORE_WARNINGS_END
