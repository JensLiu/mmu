module l2_req_fsm
    import mmu_pkg::*;
#(
) (
    input logic clk_i,
    input logic rstn_i,

    // Input Flags
    input logic req_valid_i,
    input logic tlb_miss_i,
    input logic invalidate_tlb_i,
    input logic rsp_valid_i,

    // Output Flags
    output logic req_inflight_o,
    output logic req_finished_o,
    output logic write_tlb_o,
    output logic clear_tlb_o
);
    // synchronous interface, request should always be helt until the response if valid
    typedef enum logic [1:0] {
        PS_IDLE,
        PS_WAIT_RESPONSE,
        PS_INVALIDATED_WAIT_RESPONSE
    } ptw_state_t;

    ptw_state_t current_state, next_state;
    logic write_tlb, clean_tlb;
    // FSM is finished when we transition back to IDLE from any other state
    assign req_finished_o = (current_state != PS_IDLE && next_state == PS_IDLE);
    // Use `next_state != PS_IDLE` to avoid missed miss status update when using a serialiser
    // as the conceptual L2 TLB. (bug: arbiter's next grant is asserted before a miss is cleared)
    assign req_inflight_o = (next_state != PS_IDLE);
    assign write_tlb_o    = write_tlb;
    assign clear_tlb_o    = clean_tlb;

    always_comb begin
        write_tlb  = 1'b0;
        clean_tlb  = 1'b0;
        next_state = current_state;
        if (!rstn_i) begin
            next_state = PS_IDLE;
        end else begin
            case (current_state)
                PS_IDLE: begin
                    if (req_valid_i) begin
                        clean_tlb = 1'b1;
                        if (tlb_miss_i) begin
                            next_state = PS_WAIT_RESPONSE;
                        end
                    end
                end
                PS_WAIT_RESPONSE: begin
                    if (rsp_valid_i) begin
                        write_tlb  = 1'b1;
                        next_state = PS_IDLE;
                    end else if (invalidate_tlb_i) begin
                        next_state = PS_INVALIDATED_WAIT_RESPONSE;
                    end
                end
                PS_INVALIDATED_WAIT_RESPONSE: begin
                    if (rsp_valid_i) begin
                        next_state = PS_IDLE;
                    end
                end
                default: next_state = PS_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            current_state <= PS_IDLE;
        end else begin
            current_state <= next_state;
        end
    end
endmodule
