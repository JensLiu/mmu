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

    typedef enum logic {
        S_IDLE,
        S_WAIT_FOR_RSP
    } state_t;
    state_t                      state;
    logic   [TLB_PORT_IDX_W-1:0] inflight_idx;

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
        .grant_ready(state == S_IDLE)  // consume a grant only when idle
    );

    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            state        <= S_IDLE;
            inflight_idx <= '0;
        end else
            unique case (state)
                S_IDLE:
                if (grant_valid) begin
                    state        <= S_WAIT_FOR_RSP;
                    inflight_idx <= grant_idx;  // freeze winner
                end
                S_WAIT_FOR_RSP: if (ptw_tlb_comm_i.resp.valid) state <= S_IDLE;
                default:        state <= S_IDLE;
            endcase
    end

    // -------------------------------------------------------------------------
    // Datapath mux
    // -------------------------------------------------------------------------

    // Use frozen inflight_idx once in-flight so the mux is immune to
    // the arbiter re-selecting as the granted port drops its request.
    logic [TLB_PORT_IDX_W-1:0] active_idx;
    assign active_idx = (state == S_WAIT_FOR_RSP) ? inflight_idx : grant_idx;

    // Route ptw_tlb_comm_i back in BOTH states:
    //   S_IDLE:         port = grant_idx, so the TLB sees ptw_ready=1 on the
    //                   same cycle the PTW arb (IDLE) asserts it — otherwise
    //                   the TLB misses the one-cycle ptw_ready pulse entirely.
    //   S_WAIT_FOR_RSP: port = inflight_idx (frozen), to deliver resp.valid/ppn.
    //                   grant_valid may drop to 0 here after the TLB deasserts
    //                   req.valid, so we don't gate on it in this state.
    logic route_active;
    assign route_active = (state == S_WAIT_FOR_RSP) || grant_valid;

    always_comb begin
        tlb_ptw_comm_o = grant_valid ? tlb_ptw_comms_i[active_idx] : '0;
        for (int i = 0; i < NUM_TLB_PORTS; ++i)
            ptw_tlb_comms_o[i] = (route_active && active_idx == TLB_PORT_IDX_W'(i))
                                  ? ptw_tlb_comm_i : '0;
    end

endmodule
