module request_serialiser
    import mmu_pkg::*;
#(
    parameter int unsigned NUM_PORTS = 1
) (
    input  logic                                               clk_i,
    input  logic                                               rstn_i,
    input  logic [                              NUM_PORTS-1:0] tlb_misses_i,
    input  logic                                               grant_next_i,
    output logic                                               active_o,
    output logic [(NUM_PORTS > 1 ? $clog2(NUM_PORTS) : 1)-1:0] active_idx_o
);

    // NOTE: `grant_next_i` is used to release the grant for the current miss
    //       and allow the next pending miss (if any) to be granted.
    //       IT ALLOWS THE STATE TO TRANSITION FROM `S_WAIT` TO `S_IDLE`.
    // NOTE: NO `grant_next_i` is needed to grant the first miss,
    //       since the state is S_IDLE and `grant_ready` is always high.
    localparam int unsigned PORT_IDX_W = (NUM_PORTS > 1) ? $clog2(NUM_PORTS) : 1;

    logic                  grant_valid;
    logic                  grant_ready;
    logic [PORT_IDX_W-1:0] grant_idx;
    logic [PORT_IDX_W-1:0] inflight_idx;

    assign grant_ready  = state == S_IDLE;  // consume a grant only when idle
    assign active_o     = (state == S_WAIT) || grant_valid;
    assign active_idx_o = (state == S_WAIT) ? inflight_idx : grant_idx;

    VX_generic_arbiter #(
        .NUM_REQS(NUM_PORTS),
        .TYPE    ("C"),
        .STICKY  (1)
    ) tlb_miss_arbiter (
        .clk        (clk_i),
        .reset      (~rstn_i),
        .requests   (tlb_misses_i),
        `UNUSED_PIN(grant_onehot),
        .grant_index(grant_idx),
        .grant_valid(grant_valid),
        .grant_ready(grant_ready)
    );

    typedef enum logic [1:0] {
        S_IDLE,
        S_WAIT
    } tlb_miss_state_t;
    tlb_miss_state_t state;
    always_ff @(posedge clk_i) begin : g_tlb_miss_fsm
        if (!rstn_i) begin
            state        <= S_IDLE;
            inflight_idx <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (grant_valid) begin
                        inflight_idx <= grant_idx;
                        state        <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    if (grant_next_i) begin
                        inflight_idx <= '0;
                        // NOTE: the response must be consumed in the same cycle
                        //       it is received.
                        state        <= S_IDLE;
                    end
                end
                default: begin
                    inflight_idx <= '0;
                    state        <= S_IDLE;
                end
            endcase
        end
    end

endmodule
