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

package mmu_pkg;

  `IGNORE_WARNINGS_BEGIN

  // MMU parameters - conditional on XLEN
  // SV32 (XLEN=32): 2-level, 10-bit VPN fields, 22-bit PPN, 4-byte PTEs
  // SV39 (XLEN=64): 3-level, 9-bit VPN fields, 44-bit PPN, 8-byte PTEs

`ifdef XLEN_64
  // SV39 (64-bit)
  parameter VPN_WIDTH = 27;  // total VPN bits (3 levels x 9 bits)
  parameter PPN_WIDTH = 44;  // physical page number bits
  parameter VADDR_WIDTH = 39;  // virtual address bits
  parameter ASID_WIDTH = 16;  // address space ID bits
  parameter LEVELS = 3;  // page table levels
  parameter PAGE_LVL_BITS = 9;  // VPN bits per level
  parameter PTE_SIZE = 8;  // PTE size in bytes
  parameter XLEN = 64;
`else
  // SV32 (32-bit)
  parameter VPN_WIDTH = 20;  // total VPN bits (2 levels x 10 bits)
  parameter PPN_WIDTH = 22;  // physical page number bits (34-bit PA - 12-bit offset)
  parameter VADDR_WIDTH = 32;  // virtual address bits
  parameter ASID_WIDTH = 9;  // address space ID bits
  parameter LEVELS = 2;  // page table levels
  parameter PAGE_LVL_BITS = 10;  // VPN bits per level
  parameter PTE_SIZE = 4;  // PTE size in bytes
  parameter XLEN = 32;
`endif

  // Physical address width for PTE accesses: the full SVxx PA is
  // PPN_WIDTH+12 bits, clamped to XLEN for this platform. SV39's 56-bit PA
  // fits XLEN=64 untouched; SV32's 34-bit PA is clamped to 32 bits
  // (ppn[21:20] unused). Remove the clamp to support the full SV32 PA.
  parameter PADDR_WIDTH = ((PPN_WIDTH + 12) < XLEN) ? (PPN_WIDTH + 12) : XLEN;

  parameter PTW_CACHE_SIZE = $clog2(LEVELS * 2);

`ifdef XLEN_64
  // SV39 page sizes
  parameter [1:0] GIGA_PAGE = 2'b00;  // 1 GiB page (level 0)
  parameter [1:0] MEGA_PAGE = 2'b01;  // 2 MiB page (level 1)
  parameter [1:0] KILO_PAGE = 2'b10;  // 4 KiB page (level 2)
`else
  // SV32 page sizes
  parameter [1:0] MEGA_PAGE = 2'b00;  // 4 MiB page (level 0)
  parameter [1:0] KILO_PAGE = 2'b01;  // 4 KiB page (level 1)
  parameter [1:0] GIGA_PAGE = 2'b11;  // unused in SV32 (placeholder)
`endif

  localparam LEVEL_BITS = $clog2(LEVELS);  // bits to encode a page level

  // ---------------------------------------------------------
  // PTE structure - format differs between SV32 and SV39
  // ---------------------------------------------------------
  // SV32: [31:20]=PPN[1], [19:10]=PPN[0], [9:8]=RSW, [7:0]=flags
  // SV39: [53:10]=PPN, [9:8]=RSW, [7:0]=flags
  typedef struct packed {
    logic [PPN_WIDTH-1:0] ppn;
    logic [1:0]           rfs;
    logic                 d;
    logic                 a;
    logic                 g;
    logic                 u;
    logic                 x;
    logic                 w;
    logic                 r;
    logic                 v;
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
  // TLB entry
  // ---------------------------------------------------------
  typedef struct packed {
    logic ur;
    logic uw;
    logic ux;
    logic sr;
    logic sw;
    logic sx;
  } tlb_entry_permissions_t;  // page entry permissions

  typedef struct packed {
    logic [VPN_WIDTH-1:0]   vpn;
    logic [ASID_WIDTH-1:0]  asid;
    logic [PPN_WIDTH-1:0]   ppn;
    logic [LEVEL_BITS-1:0]  level;
    logic                   dirty;
    logic access;
    tlb_entry_permissions_t perms;
    logic                   valid;
  } tlb_entry_t;

  // ---------------------------------------------------------
  // Core <-> TLB
  // ---------------------------------------------------------
  typedef struct packed {
    logic                  valid;
    logic [ASID_WIDTH-1:0] asid;
    logic [VPN_WIDTH-1:0]  vpn;
    logic                  passthrough;
    logic                  instruction;
    logic                  store;
  } core_tlb_req_t;

  typedef struct packed {
    core_tlb_req_t req;
    logic [1:0]    priv_lvl;
    logic          vm_enable;
    logic          rsp_ready;  // requester ready to accept the response (backpressure)
  } core_tlb_comm_t;

  typedef struct packed {
    logic load;
    logic store;
    logic fetch;
  } tlb_ex_t;  // exception origin

  typedef struct packed {
    logic                 valid;    // a definitive answer is available (hit or fault)
    logic                 miss;
    logic [PPN_WIDTH-1:0] ppn;
    tlb_ex_t              xcpt;
    logic [7:0]           hit_idx;
  } tlb_core_rsp_t;

  typedef struct packed {tlb_core_rsp_t rsp;} tlb_core_comm_t;

  // Handshake payloads for core_tlb_if (valid/ready lives on the interface, so
  // these carry no valid bit). priv_lvl/vm_enable are per-request context.
  typedef struct packed {
    logic [ASID_WIDTH-1:0] asid;
    logic [VPN_WIDTH-1:0]  vpn;
    logic                  instruction;
    logic                  store;
    logic [1:0]            priv_lvl;
    logic                  vm_enable;    // per-request; clear it to bypass translation
  } core_tlb_req_data_t;

  typedef struct packed {
    logic [PPN_WIDTH-1:0] ppn;
    tlb_ex_t              xcpt;
  } core_tlb_rsp_data_t;

  // ---------------------------------------------------------
  // L1 <-> L2 TLB
  // ---------------------------------------------------------
  typedef struct packed {
    logic [VPN_WIDTH-1:0]  vpn;
    logic [ASID_WIDTH-1:0] asid;
    logic [1:0]            prv;
    logic                  set_dirty;
  } inter_tlb_req_data_t;

  typedef struct packed {
    logic       error;
    tlb_entry_t tlb_entry;
  } inter_tlb_rsp_data_t;

  // ---------------------------------------------------------
  // L2 TLB <-> PTW
  // ---------------------------------------------------------
  // The PTW echoes this tag opaquely. It has two owners with disjoint fields:
  //   .mshr_slot - the requesting bank's MSHR slot id (bank-private; routes the fill)
  //   .bank      - the bank id, stamped by the PTW scheduler (routes the response)
  // Each layer touches only its own field, so neither hard-codes bit positions.
  // Widths are design maxima (>= any bank's MSHR_TAG_W / clog2(NUM_BANKS)).
  parameter PTW_TAG_SLOT_WIDTH = 4;  // up to 16 MSHR slots per bank
  parameter PTW_TAG_BANK_WIDTH = 4;  // up to 16 banks
  parameter PTW_TAG_TLB_SET_WIDTH = 8;  // up to 256 TLB sets
  parameter PTW_TAG_WIDTH = PTW_TAG_BANK_WIDTH + PTW_TAG_SLOT_WIDTH + PTW_TAG_TLB_SET_WIDTH;

  typedef struct packed {
    logic [PTW_TAG_BANK_WIDTH-1:0]    bank;       // owned by the scheduler
    logic [PTW_TAG_SLOT_WIDTH-1:0]    mshr_slot;  // owned by the bank's MSHR
    logic [PTW_TAG_TLB_SET_WIDTH-1:0] tlb_set;    // owned by the TLB
  } ptw_tag_t;

  typedef struct packed {
    logic [VPN_WIDTH-1:0]  vpn;
    logic [ASID_WIDTH-1:0] asid;
    logic                  set_dirty;
    ptw_tag_t              tag;
  } ptw_req_data_t;

  typedef struct packed {
    pte_t                  pte;
    logic [LEVEL_BITS-1:0] level;
    logic                  error;
    ptw_tag_t              tag;
  } ptw_rsp_data_t;

  // ---------------------------------------------------------
  // PTW internal
  // ---------------------------------------------------------
  typedef struct packed {
    logic                   valid;
    logic [PADDR_WIDTH-1:0] tags;   // PTE physical address
    logic [PPN_WIDTH-1:0]   data;
  } ptw_ptecache_entry_t;

  // ---------------------------------------------------------
  // PTW <-> DRAM
  // ---------------------------------------------------------
  typedef enum logic [1:0] {
    PTW_MEM_READ   = 2'd0,
    PTW_MEM_WRITE  = 2'd1,
    PTW_MEM_AMO_OR = 2'd2
  } ptw_mem_cmd_t;

  // ---------------------------------------------------------
  // CSR interface
  // ---------------------------------------------------------
  typedef struct packed {
    logic [63:0]  satp;
    logic         flush;
    csr_mstatus_t mstatus;
  } csr_ptw_comm_t;

  `IGNORE_WARNINGS_END

endpackage
