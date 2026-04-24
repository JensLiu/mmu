/*
 * Simple TLB->PTW request serializer.
 *
 * - Arbitrates multiple TLB request ports onto a single PTW port.
 * - Assumes at most one outstanding PTW transaction at a time (serialized).
 * - Routes the PTW response back to the selected TLB port.
 */
`IGNORE_WARNINGS_BEGIN
module tlb_ptw_serialiser
  import mmu_pkg::*;
#(
    parameter int unsigned NUM_TLB_PORTS = 1
) (
    input  logic clk_i,
    input  logic rstn_i,

    // Per-port TLB requests to PTW
    input  tlb_ptw_comm_t tlb_ptw_comms_i[NUM_TLB_PORTS],
    // Per-port PTW responses back to TLBs
    output ptw_tlb_comm_t ptw_tlb_comms_o[NUM_TLB_PORTS],

    // Serialized PTW request/response
    output tlb_ptw_comm_t tlb_ptw_comm_o,
    input  ptw_tlb_comm_t ptw_tlb_comm_i
);

    localparam int unsigned SELW = (NUM_TLB_PORTS <= 1) ? 1 : $clog2(NUM_TLB_PORTS);

    logic [SELW-1:0] grant_q;
    logic            busy_q;

    // round-robin pointer for next grant (best-effort fairness)
    logic [SELW-1:0] rr_q;

    // default outputs
    always_comb begin
        /* verilator lint_off IMPLICITSTATIC */
        tlb_ptw_comm_o = '0;

        for (int unsigned i = 0; i < NUM_TLB_PORTS; ++i) begin
            ptw_tlb_comms_o[i] = '0;
            // Broadcast non-transactional PTW sideband state.
            ptw_tlb_comms_o[i].ptw_ready       = ptw_tlb_comm_i.ptw_ready && !busy_q;
            ptw_tlb_comms_o[i].ptw_status      = ptw_tlb_comm_i.ptw_status;
            ptw_tlb_comms_o[i].invalidate_tlb  = ptw_tlb_comm_i.invalidate_tlb;
        end

        // Drive serialized request from current grant (when busy) or from
        // the next eligible requester (when idle).
        if (NUM_TLB_PORTS == 1) begin
            if (!busy_q) begin
                tlb_ptw_comm_o = tlb_ptw_comms_i[0];
            end else begin
                tlb_ptw_comm_o = tlb_ptw_comms_i[0];
            end
        end else begin
            if (busy_q) begin
                tlb_ptw_comm_o = tlb_ptw_comms_i[grant_q];
            end else begin
                // Find first valid starting at rr_q (wrap-around).
                int sel = -1;
                for (int k = 0; k < NUM_TLB_PORTS; ++k) begin
                    int idx = (rr_q + k);
                    if (idx >= NUM_TLB_PORTS) idx -= NUM_TLB_PORTS;
                    if (tlb_ptw_comms_i[idx].req.valid && sel == -1) sel = idx;
                end
                if (sel != -1) begin
                    tlb_ptw_comm_o = tlb_ptw_comms_i[sel];
                end
            end
        end

        // Route PTW response only to the granted port.
        if (ptw_tlb_comm_i.resp.valid) begin
            ptw_tlb_comms_o[grant_q].resp = ptw_tlb_comm_i.resp;
        end
    end
        /* verilator lint_on IMPLICITSTATIC */

    // Track outstanding transaction and selected grant.
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            grant_q <= '0;
            busy_q  <= 1'b0;
            rr_q    <= '0;
        end else begin
            // Latch a new grant when idle and PTW is ready and a request is present.
            if (!busy_q && ptw_tlb_comm_i.ptw_ready) begin
                if (NUM_TLB_PORTS == 1) begin
                    if (tlb_ptw_comms_i[0].req.valid) begin
                        grant_q <= '0;
                        busy_q  <= 1'b1;
                    end
                end else begin
                    /* verilator lint_off IMPLICITSTATIC */
                    int sel = -1;
                    for (int k = 0; k < NUM_TLB_PORTS; ++k) begin
                        int idx = (rr_q + k);
                        if (idx >= NUM_TLB_PORTS) idx -= NUM_TLB_PORTS;
                        if (tlb_ptw_comms_i[idx].req.valid && sel == -1) sel = idx;
                    end
                    if (sel != -1) begin
                        grant_q <= SELW'(sel);
                        busy_q  <= 1'b1;
                        // next time start after this port
                        rr_q <= (SELW'(sel) + SELW'(1));
                    end
                    /* verilator lint_on IMPLICITSTATIC */
                end
            end

            // Clear busy when PTW returns a response.
            if (busy_q && ptw_tlb_comm_i.resp.valid) begin
                busy_q <= 1'b0;
            end
        end
    end

endmodule
`IGNORE_WARNINGS_END

