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

    logic [NUM_TLB_PORTS-1:0] miss_reqs;
    for (genvar i = 0; i < NUM_TLB_PORTS; ++i) begin : g_req_valid
        assign miss_reqs[i] = tlb_ptw_comms_i[i].req.valid;
    end

    // -------------------------------------------------------------------------
    // Request Serialiser
    // -------------------------------------------------------------------------

    logic                      miss_active;
    logic [TLB_PORT_IDX_W-1:0] miss_port;

    request_serialiser #(
        .NUM_PORTS(NUM_TLB_PORTS)
    ) tlb_req_serialiser (
        .clk_i       (clk_i),
        .rstn_i      (rstn_i),
        .tlb_misses_i(miss_reqs),
        // allow the next miss to be granted when the FSM has finished processing the current miss
        .grant_next_i(fsm_finished),
        .active_o    (miss_active),
        .active_idx_o(miss_port)
    );

    // -------------------------------------------------------------------------
    // Dispatch FSM
    // -------------------------------------------------------------------------

    typedef enum logic [1:0] {
        S_IDLE,
        S_WAIT_ACCEPT,
        S_WAIT_RSP
    } state_t;
    state_t state, state_n;

    logic fsm_finished;
    assign fsm_finished = state != S_IDLE && state_n == S_IDLE;

    always_comb begin
        state_n = state;
        if (!rstn_i) begin
            state_n = S_IDLE;
        end else begin
            unique case (state)
                S_IDLE: begin
                    if (miss_active) begin
                        state_n = S_WAIT_ACCEPT;
                    end
                end
                S_WAIT_ACCEPT: begin
                    if (ptw_tlb_comm_i.ptw_ready) begin
                        state_n = S_WAIT_RSP;
                    end
                end
                S_WAIT_RSP: begin
                    if (ptw_tlb_comm_i.resp.valid) begin
                        state_n = S_IDLE;
                    end
                end
                default: begin
                    state_n = S_IDLE;
                end
            endcase
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            state <= S_IDLE;
        end else begin
            state <= state_n;
        end
    end

    // -------------------------------------------------------------------------
    // Output Muxes
    // -------------------------------------------------------------------------
    logic fsm_serving;
    assign fsm_serving    = (state == S_WAIT_ACCEPT) || (state == S_WAIT_RSP);
    assign tlb_ptw_comm_o = fsm_serving ? tlb_ptw_comms_i[miss_port] : '0;
    for (genvar i = 0; i < NUM_TLB_PORTS; ++i) begin : g_resp_mux
        assign ptw_tlb_comms_o[i].resp = fsm_serving && miss_port == i ? ptw_tlb_comm_i.resp : '0;
        assign ptw_tlb_comms_o[i].ptw_ready = fsm_serving && miss_port == i ? ptw_tlb_comm_i.ptw_ready : 1'b0;
        assign ptw_tlb_comms_o[i].ptw_status = ptw_tlb_comm_i.ptw_status;
        assign ptw_tlb_comms_o[i].invalidate_tlb = ptw_tlb_comm_i.invalidate_tlb;
    end


endmodule
