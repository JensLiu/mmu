module ptw_req_fsm
    import mmu_pkg::*;
#(
) (
    input logic clk_i,
    input logic rstn_i,

    // Input Flags
    input logic lookup_valid_i,    // We actually has a lookup request
    input logic lookup_miss_i,     // TLB miss
    input logic req_ready_i,       // The downstream can receive a request
    input logic rsp_valid_i,       // The downstream responses to the upstream
    input logic rsp_ready_i,       // The upstream is able to receive the downstream response
    // Output Flags
    output logic req_valid_o,  // The upstream need to fire a PTW request
    output logic write_tlb_o
);
    // synchronous interface, request should always be helt until the response if valid
    typedef enum logic [1:0] {
        S_IDLE,
        S_WAIT_ACK,
        S_WAIT_RESPONSE
    } ptw_state_t;
    ptw_state_t current_state, next_state;

    always_comb begin
        req_valid_o = 1'b0;
        write_tlb_o = 1'b0;
        next_state  = current_state;
        if (!rstn_i) begin
            next_state = S_IDLE;
        end else begin
            case (current_state)
                S_IDLE: begin
                    if (lookup_valid_i && lookup_miss_i) begin
                        next_state = S_WAIT_ACK;
                    end
                end
                S_WAIT_ACK: begin
                    req_valid_o = 1'b1;
                    if (req_ready_i) begin
                        next_state = S_WAIT_RESPONSE;
                    end
                end
                S_WAIT_RESPONSE: begin
                    if (rsp_valid_i && rsp_ready_i) begin
                        write_tlb_o  = 1'b1;
                        next_state = S_IDLE;
                    end
                end
                default: next_state = S_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            current_state <= S_IDLE;
        end else begin
            current_state <= next_state;
        end
    end
endmodule
