module l1_ltb_serialiser
    import mmu_pkg::*;
#(
    parameter int unsigned NUM_TLB_PORTS = 1
) (
    input logic clk_i,
    input logic rstn_i,

    // TLB-PTW interface (slave)
    input  tlb_ptw_comm_t tlb_ptw_comms_i[NUM_TLB_PORTS],
    output ptw_tlb_comm_t ptw_tlb_comms_o[NUM_TLB_PORTS],

    // TLB-PTW interface (master)
    output tlb_ptw_comm_t tlb_ptw_comm_o,
    input  ptw_tlb_comm_t ptw_tlb_comm_i
);

    localparam int unsigned TLB_PORT_IDX_W = (NUM_TLB_PORTS > 1) ? $clog2(NUM_TLB_PORTS) : 1;
    logic                      tlb_sel_valid;
    logic [TLB_PORT_IDX_W-1:0] tlb_sel_idx;
    logic tlb_inflight_valid_d, tlb_inflight_valid_q;
    logic [TLB_PORT_IDX_W-1:0] tlb_inflight_idx_d, tlb_inflight_idx_q;

    // TLB-PTW request arbitration (iterate high-to-low so index 0 wins)
    always_comb begin : arb_tlb_ptw
        tlb_ptw_comm_o = '0;
        tlb_sel_valid  = 1'b0;
        tlb_sel_idx    = '0;
        // Last sel_valid assignment wins
        for (integer i = NUM_TLB_PORTS - 1; i >= 0; --i) begin
            if (tlb_ptw_comms_i[i].req.valid) begin
                tlb_sel_valid  = 1'b1;
                tlb_sel_idx    = TLB_PORT_IDX_W'(i);
                tlb_ptw_comm_o = tlb_ptw_comms_i[i];
            end
        end
    end

    // Track which tlb port has the in-flight PTW transaction.
    always_comb begin : tlb_inflight_next
        tlb_inflight_valid_d = tlb_inflight_valid_q;
        tlb_inflight_idx_d   = tlb_inflight_idx_q;

        // PTW accepts a new tlb request only when it is ready.
        if (ptw_tlb_comm_i.ptw_ready && tlb_sel_valid) begin
            tlb_inflight_valid_d = 1'b1;
            tlb_inflight_idx_d   = tlb_sel_idx;
        end

        // Clear in-flight owner once PTW returns a response.
        if (ptw_tlb_comm_i.resp.valid) begin
            tlb_inflight_valid_d = 1'b0;
        end
    end

    always_ff @(posedge clk_i or negedge rstn_i) begin : tlb_inflight_ff
        if (!rstn_i) begin
            tlb_inflight_valid_q <= 1'b0;
            tlb_inflight_idx_q   <= '0;
        end else begin
            tlb_inflight_valid_q <= tlb_inflight_valid_d;
            tlb_inflight_idx_q   <= tlb_inflight_idx_d;
        end
    end

    // Route PTW status to all TLBs, but gate ready/response to the selected owner.
    for (genvar i = 0; i < NUM_TLB_PORTS; ++i) begin : g_tlb_ptw_rsp
        always_comb begin
            ptw_tlb_comms_o[i]                = '0;
            ptw_tlb_comms_o[i].ptw_status     = ptw_tlb_comm_i.ptw_status;
            ptw_tlb_comms_o[i].invalidate_tlb = ptw_tlb_comm_i.invalidate_tlb;

            if (!tlb_inflight_valid_q) begin
                ptw_tlb_comms_o[i].ptw_ready = ptw_tlb_comm_i.ptw_ready && tlb_sel_valid && (tlb_sel_idx == TLB_PORT_IDX_W'(i));
            end else begin
                ptw_tlb_comms_o[i].ptw_ready = 1'b0;
            end

            ptw_tlb_comms_o[i].resp.valid = ptw_tlb_comm_i.resp.valid && tlb_inflight_valid_q && (tlb_inflight_idx_q == TLB_PORT_IDX_W'(i));
            ptw_tlb_comms_o[i].resp.error = ptw_tlb_comm_i.resp.error;
            ptw_tlb_comms_o[i].resp.level = ptw_tlb_comm_i.resp.level;
            ptw_tlb_comms_o[i].resp.pte = ptw_tlb_comm_i.resp.pte;
        end
    end

endmodule
