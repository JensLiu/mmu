module l1_tlb_serialiser
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

    // -------------------------------------------------------------------------
    // Arbiter
    // -------------------------------------------------------------------------

    logic [ NUM_TLB_PORTS-1:0] grant_reqs;
    logic [TLB_PORT_IDX_W-1:0] grant_idx;
    logic                      grant_valid;

    for (genvar i = 0; i < NUM_TLB_PORTS; ++i) begin : g_req_valid
        assign grant_reqs[i] = tlb_ptw_comms_i[i].req.valid;
    end

    // -------------------------------------------------------------------------
    // FSM: one PTW request in-flight at a time
    // -------------------------------------------------------------------------

    typedef enum logic [1:0] {
        S_IDLE,
        S_WAIT_ACCEPT,
        S_WAIT_RSP
    } state_t;

    state_t state_q, state_d;
    logic [TLB_PORT_IDX_W-1:0] sel_idx_q, sel_idx_d;
    tlb_ptw_req_t sel_req_q, sel_req_d;
    logic sel_valid_q, sel_valid_d;

    VX_generic_arbiter #(
        .NUM_REQS(NUM_TLB_PORTS),
        .TYPE    ("P"),
        .STICKY  (1)
    ) tlb_req_arbiter (
        .clk        (clk_i),
        .reset      (~rstn_i),
        .requests   (grant_reqs),
        .grant_index(grant_idx),
        `UNUSED_PIN(grant_onehot),
        .grant_valid(grant_valid),
        .grant_ready(state_q == S_IDLE)  // pop only when idle
    );

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            state_q     <= S_IDLE;
            sel_idx_q   <= '0;
            sel_req_q   <= '0;
            sel_valid_q <= 1'b0;
        end else begin
            state_q     <= state_d;
            sel_idx_q   <= sel_idx_d;
            sel_req_q   <= sel_req_d;
            sel_valid_q <= sel_valid_d;
        end
    end

    // -------------------------------------------------------------------------
    // Datapath mux
    // -------------------------------------------------------------------------

    // One in-flight request at a time:
    // 1) pop/latch winner in IDLE,
    // 2) wait for ptw_ready accept,
    // 3) wait for response, then release.
    always_comb begin
        state_d     = state_q;
        sel_idx_d   = sel_idx_q;
        sel_req_d   = sel_req_q;
        sel_valid_d = sel_valid_q;

        unique case (state_q)
            S_IDLE: begin
                sel_valid_d = 1'b0;
                if (grant_valid) begin
                    sel_idx_d   = grant_idx;
                    sel_req_d   = tlb_ptw_comms_i[grant_idx].req;
                    sel_valid_d = 1'b1;
                    state_d     = S_WAIT_ACCEPT;
                end
            end
            S_WAIT_ACCEPT: begin
                if (ptw_tlb_comm_i.ptw_ready) begin
                    state_d = S_WAIT_RSP;
                end
            end
            S_WAIT_RSP: begin
                if (ptw_tlb_comm_i.resp.valid) begin
                    sel_valid_d = 1'b0;
                    state_d     = S_IDLE;
                end
            end
            default: begin
                sel_valid_d = 1'b0;
                state_d     = S_IDLE;
            end
        endcase
    end

    always_comb begin
        tlb_ptw_comm_o = '0;
        if (sel_valid_q && (state_q == S_WAIT_ACCEPT)) begin
            tlb_ptw_comm_o.req       = sel_req_q;
            tlb_ptw_comm_o.req.valid = 1'b1;
        end

        for (int i = 0; i < NUM_TLB_PORTS; ++i) begin
            ptw_tlb_comms_o[i] = (sel_valid_q && (sel_idx_q == TLB_PORT_IDX_W'(i)))
                                ? ptw_tlb_comm_i : '0;
        end
    end

endmodule
