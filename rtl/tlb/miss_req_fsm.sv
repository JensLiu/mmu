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
    output logic tlb_ready_o,
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
    logic pmu_tlb_access, pmu_tlb_miss;
    tlb_req_tmp_storage_t tlb_req_tmp;

    logic store_tlb_req, send_tlb_req, tlb_ready, write_tlb, clean_tlb;
    assign store_tlb_req_o = store_tlb_req;
    assign send_tlb_req_o  = send_tlb_req;
    assign tlb_ready_o     = tlb_ready;
    assign write_tlb_o     = write_tlb;
    assign clear_tlb_o     = clean_tlb;

    always_comb begin
        store_tlb_req  = 1'b0;
        send_tlb_req   = 1'b0;
        write_tlb      = 1'b0;
        clean_tlb      = 1'b0;
        tlb_ready      = 1'b0;
        pmu_tlb_access = 1'b0;
        pmu_tlb_miss   = 1'b0;
        next_state     = current_state;  // By default, we remain in the same state
        case (current_state)
            PS_IDLE: begin
                tlb_ready = 1'b1;
                if (req_valid_i) begin  // if we have a valid request always try to clean the tlb
                    clean_tlb      = 1'b1;  // flush invalid pages, and not dirty page case
                    pmu_tlb_access = 1'b1;  // tlb access event for PMU
                    if (tlb_miss_i) begin
                        store_tlb_req = 1'b1;  // store req to send it in the next state
                        pmu_tlb_miss  = 1'b1;  // tlb miss event for PMU
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

    always_ff @(posedge clk_i, negedge rstn_i) begin
        if (!rstn_i) begin
            current_state <= PS_IDLE;
        end else begin
            current_state <= next_state;
        end
    end
endmodule
