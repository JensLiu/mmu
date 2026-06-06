`IGNORE_WARNINGS_BEGIN

// -----------------------------------------------------------------------------
// PTW scheduler: matches bank walk requests to free PTWs and routes responses
// back. Stateless - the response self-routes via a {bank_id, slot} tag.
//
//   bank_reqs[NUM_BANKS] (.ptw)  : the scheduler is the PTW toward each bank
//   ptw_reqs [NUM_PTWS]  (.tlb)  : the scheduler is the TLB toward each PTW
//
// Interface arrays cannot be indexed by a dynamic variable, so the arrays are
// first unpacked into flat vectors (genvar), the arbitration runs on the flat
// vectors, and the results are repacked.
//
// Request : one assignment per cycle - pick a bank with a pending request and a
//   free PTW, forward the request, and stamp the bank id into tag.bank.
// Response: one delivery per cycle - pick a PTW with a response and route it to
//   the bank named in tag.bank.  Bank fills are always ready, so this never
//   back-pressures; surplus PTW responses hold (their S_DONE waits on rsp_ready).
//
// The tag's named bank/slot fields (ptw_tag_t) keep the two ids from overlapping;
// the only width assumption is BANK_ID_W <= PTW_TAG_BANK_W.
// -----------------------------------------------------------------------------

module ptw_scheduler
    import mmu_pkg::*;
#(
    parameter int unsigned NUM_BANKS = 1,
    parameter int unsigned NUM_PTWS  = 1
) (
    input logic clk_i,
    input logic rstn_i,

    ptw_if.slave  bank_reqs[NUM_BANKS],
    ptw_if.master ptw_reqs [ NUM_PTWS]
);
    localparam int unsigned BANK_ID_W = (NUM_BANKS > 1) ? $clog2(NUM_BANKS) : 1;
    localparam int unsigned PTW_ID_W = (NUM_PTWS > 1) ? $clog2(NUM_PTWS) : 1;

    // -------------------------------------------------------------------------
    // Unpack the interface arrays into flat vectors (dynamic indexing needs this)
    // -------------------------------------------------------------------------
    logic [NUM_BANKS-1:0] bank_req_valid, bank_req_ready;
    ptw_req_data_t [NUM_BANKS-1:0] bank_req_data;
    logic [NUM_BANKS-1:0] bank_rsp_valid, bank_rsp_ready;
    ptw_rsp_data_t [NUM_BANKS-1:0] bank_rsp_data;

    logic [NUM_PTWS-1:0] ptw_req_valid, ptw_req_ready;
    ptw_req_data_t [NUM_PTWS-1:0] ptw_req_data;
    logic [NUM_PTWS-1:0] ptw_rsp_valid, ptw_rsp_ready;
    ptw_rsp_data_t [NUM_PTWS-1:0] ptw_rsp_data;
    logic          [NUM_PTWS-1:0] ptw_invalidate;

    for (genvar b = 0; b < NUM_BANKS; b++) begin : g_bank
        assign bank_req_valid[b]           = bank_reqs[b].req_valid;
        assign bank_req_data[b]            = bank_reqs[b].req_data;
        assign bank_reqs[b].req_ready      = bank_req_ready[b];
        assign bank_reqs[b].rsp_valid      = bank_rsp_valid[b];
        assign bank_reqs[b].rsp_data       = bank_rsp_data[b];
        assign bank_rsp_ready[b]           = bank_reqs[b].rsp_ready;
        assign bank_reqs[b].invalidate_tlb = |ptw_invalidate;  // broadcast CSR flush
    end

    for (genvar p = 0; p < NUM_PTWS; p++) begin : g_ptw
        assign ptw_req_ready[p]      = ptw_reqs[p].req_ready;
        assign ptw_reqs[p].req_valid = ptw_req_valid[p];
        assign ptw_reqs[p].req_data  = ptw_req_data[p];
        assign ptw_rsp_valid[p]      = ptw_reqs[p].rsp_valid;
        assign ptw_rsp_data[p]       = ptw_reqs[p].rsp_data;
        assign ptw_reqs[p].rsp_ready = ptw_rsp_ready[p];
        assign ptw_invalidate[p]     = ptw_reqs[p].invalidate_tlb;
    end

    // -------------------------------------------------------------------------
    // Request: match one pending bank to one free PTW (one assignment / cycle)
    // -------------------------------------------------------------------------
    logic sel_bank_valid, sel_ptw_valid;
    logic [BANK_ID_W-1:0] sel_bank;
    logic [ PTW_ID_W-1:0] sel_ptw;
    wire                  assign_fire = sel_bank_valid && sel_ptw_valid;
    always_comb begin
        sel_bank_valid = 1'b0;
        sel_bank       = '0;
        sel_ptw_valid  = 1'b0;
        sel_ptw        = '0;
        for (int i = 0; i < NUM_BANKS; i++)
        if (!sel_bank_valid && bank_req_valid[i]) begin
            sel_bank_valid = 1'b1;
            sel_bank       = BANK_ID_W'(i);
        end
        for (int j = 0; j < NUM_PTWS; j++)
        if (!sel_ptw_valid && ptw_req_ready[j]) begin
            sel_ptw_valid = 1'b1;
            sel_ptw       = PTW_ID_W'(j);
        end
    end

    // selected bank's request with the bank id stamped into tag.bank
    ptw_req_data_t sel_req;
    always_comb begin
        sel_req          = bank_req_data[sel_bank];
        sel_req.tag.bank = PTW_TAG_BANK_W'(sel_bank);
    end

    always_comb begin
        ptw_req_valid  = '0;
        ptw_req_data   = '0;
        bank_req_ready = '0;
        if (assign_fire) begin
            ptw_req_valid[sel_ptw]   = 1'b1;
            ptw_req_data[sel_ptw]    = sel_req;
            bank_req_ready[sel_bank] = 1'b1;  // selected PTW is ready -> bank issue fires
        end
    end

    // -------------------------------------------------------------------------
    // Response: pick one PTW with a result, route to the bank named in its tag
    // -------------------------------------------------------------------------
    logic                rsp_valid;
    logic [PTW_ID_W-1:0] rsp_ptw;
    always_comb begin
        rsp_valid   = 1'b0;
        rsp_ptw = '0;
        for (int j = 0; j < NUM_PTWS; j++)
        if (!rsp_valid && ptw_rsp_valid[j]) begin
            rsp_valid   = 1'b1;
            rsp_ptw = PTW_ID_W'(j);
        end
    end

    ptw_rsp_data_t                 sel_rsp;
    logic          [BANK_ID_W-1:0] rsp_bank;
    assign sel_rsp  = ptw_rsp_data[rsp_ptw];
    assign rsp_bank = BANK_ID_W'(sel_rsp.tag.bank);  // self-routes by the stamped field

    always_comb begin
        bank_rsp_valid = '0;
        bank_rsp_data  = '0;
        ptw_rsp_ready  = '0;
        if (rsp_valid) begin
            bank_rsp_valid[rsp_bank] = 1'b1;
            bank_rsp_data[rsp_bank]  = sel_rsp;  // bank reads only tag.slot
            ptw_rsp_ready[rsp_ptw]   = bank_rsp_ready[rsp_bank];
        end
    end

`ifdef SIMULATION
    always_ff @(posedge clk_i)
        if (rstn_i) begin
            if (rsp_valid)
                assert (int'(rsp_bank) < NUM_BANKS)
                else
                    $fatal(
                        1,
                        "ptw_scheduler: response tag names bank %0d (>= %0d)",
                        rsp_bank,
                        NUM_BANKS
                    );
        end
`endif

endmodule

`IGNORE_WARNINGS_END
