
module l2_tlb_bank_response_engine
    import mmu_pkg::*;
#(
    parameter  int unsigned NUM_CORES = 32,
    localparam int unsigned CORE_ID_W = (NUM_CORES > 1) ? $clog2(NUM_CORES) : 1
) (
    input logic clk_i,
    input logic rst_i,

    // MSHR deliver (slave)
    input  logic                                         mshr_deliver_valid_i,
    output logic                                         mshr_deliver_ready_o,
    input  logic                         [NUM_CORES-1:0] mshr_deliver_cores_i,
    input  mmu_pkg::inter_tlb_rsp_data_t                 mshr_deliver_rsp_i,

    // TLB hit (slave)
    input  logic                                         tlb_hit_valid_i,
    output logic                                         tlb_hit_ready_o,
    input  logic                         [CORE_ID_W-1:0] tlb_hit_core_i,
    input  mmu_pkg::inter_tlb_rsp_data_t                 tlb_hit_rsp_i,

    // Bank response (master)
    output logic                                         rsp_valid_o,
    input  logic                                         rsp_ready_i,
    output mmu_pkg::inter_tlb_rsp_data_t                 rsp_data_o,
    output logic                         [CORE_ID_W-1:0] rsp_src_o
);

    logic                         [NUM_CORES-1:0] mask_r;
    mmu_pkg::inter_tlb_rsp_data_t                 data_r;

    // -------------------------------------------------------------------------
    // Pick the lowest pending core
    // -------------------------------------------------------------------------
    logic                         [CORE_ID_W-1:0] pick_idx;
    logic                         [NUM_CORES-1:0] pick_oh;
    always_comb begin
        pick_idx = '0;
        pick_oh  = '0;
        for (int i = 0; i < NUM_CORES; i++) begin
            if (mask_r[i] && (pick_oh == '0)) begin
                pick_idx   = CORE_ID_W'(i);
                pick_oh[i] = 1'b1;
            end
        end
    end

    assign rsp_valid_o = (mask_r != '0);
    assign rsp_data_o  = data_r;
    assign rsp_src_o   = pick_idx;

    wire                 rsp_fire = rsp_valid_o && rsp_ready_i;
    wire [NUM_CORES-1:0] mask_after = mask_r & ~(rsp_fire ? pick_oh : '0);
    wire                 free_next = (mask_after == '0);

    // -------------------------------------------------------------------------
    // Load arbitration (deliver > hit)
    // -------------------------------------------------------------------------
    // MSHR deliver has higher priority (perhaps entries inside the TLB is stale)
    assign mshr_deliver_ready_o = free_next;
    assign tlb_hit_ready_o      = free_next && !mshr_deliver_valid_i;

    wire                 load_deliver = mshr_deliver_ready_o && mshr_deliver_valid_i;
    wire                 load_hit = tlb_hit_ready_o && tlb_hit_valid_i;

    wire [NUM_CORES-1:0] hit_oh = (NUM_CORES'(1) << tlb_hit_core_i);

    // -------------------------------------------------------------------------
    // Load / drain
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            mask_r <= '0;
        end else if (free_next) begin
            if (load_deliver) begin  // Accept a new MSHR deliver request
                mask_r <= mshr_deliver_cores_i;
                data_r <= mshr_deliver_rsp_i;
            end else if (load_hit) begin  // Accept a TLB hit
                mask_r <= hit_oh;
                data_r <= tlb_hit_rsp_i;
            end else begin
                mask_r <= '0;
            end
        end else begin
            mask_r <= mask_after;
        end
    end

endmodule
