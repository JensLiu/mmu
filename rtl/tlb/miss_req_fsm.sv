module miss_req_fsm
    import mmu_pkg::*;
#(
) (
    input logic clk_i,
    input logic rstn_i,

    // Input Flags
    input logic req_valid_i,
    input logic tlb_miss_i,
    input logic ptw_ready_i,
    input logic invalidate_tlb_i,
    input logic rsp_valid_i,

    // Output Flags
    output logic fsm_finished_o,
    output logic store_tlb_req_o,
    output logic send_tlb_req_o,
    output logic write_tlb_o,
    output logic clear_tlb_o
);
    typedef enum logic [1:0] {
        PS_IDLE,
        PS_SEND_REQUEST,
        PS_WAIT_RESPONSE,
        PS_INVALIDATED_WAIT_RESPONSE
    } ptw_state_t;

    ptw_state_t current_state, next_state;
    logic store_tlb_req, send_tlb_req, write_tlb, clean_tlb;
    assign store_tlb_req_o = store_tlb_req;
    assign send_tlb_req_o  = send_tlb_req;
    // FSM is finished when we transition back to IDLE from any other state
    assign fsm_finished_o  = (current_state != PS_IDLE && next_state == PS_IDLE);
    assign write_tlb_o     = write_tlb;
    assign clear_tlb_o     = clean_tlb;

    always_comb begin
        store_tlb_req = 1'b0;
        send_tlb_req  = 1'b0;
        write_tlb     = 1'b0;
        clean_tlb     = 1'b0;
        next_state    = current_state;  // By default, we remain in the same state
        case (current_state)
            PS_IDLE: begin
                if (req_valid_i) begin  // if we have a valid request always try to clean the tlb
                    clean_tlb = 1'b1;  // flush invalid pages, and not dirty page case
                    if (tlb_miss_i) begin
                        store_tlb_req = 1'b1;  // store req to send it in the next state
                        next_state    = PS_SEND_REQUEST;
                    end
                end
            end
            PS_SEND_REQUEST: begin
                send_tlb_req = 1'b1;  // send stored request to PTW
                if (!ptw_ready_i && invalidate_tlb_i) begin
                    next_state = PS_IDLE;  // TLB request cancelled
                end else if (ptw_ready_i) begin
                    if (invalidate_tlb_i) begin
                        next_state = PS_INVALIDATED_WAIT_RESPONSE;
                    end else begin
                        next_state = PS_WAIT_RESPONSE;  // go to waiting for response state
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
                    next_state = PS_IDLE;  // we catched the request in progress
                end
            end
            default: begin
                $fatal("Invalid state in PTW Request FSM");
                next_state = PS_IDLE;
            end
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            current_state <= PS_IDLE;
        end else begin
            current_state <= next_state;
        end
    end
endmodule
