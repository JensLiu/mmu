module l1_tlb_serialiser
  import mmu_pkg::*;
#(
    parameter int unsigned NUM_TLB_PORTS = 1
) (
    input logic clk_i,
    input logic rstn_i,

    // L1-L2 interface (slave)
    input  l1_l2_comm_t l1_l2_comms_i[NUM_TLB_PORTS],
    output l2_l1_comm_t l2_l1_comms_o[NUM_TLB_PORTS],

    // PTW interface (master)
    output l2_ptw_comm_t l2_ptw_comm_o,
    input  ptw_l2_comm_t ptw_l2_comm_i
);

  localparam int unsigned TLB_PORT_IDX_W = (NUM_TLB_PORTS > 1) ? $clog2(NUM_TLB_PORTS) : 1;

  // ---------------------------------------------------------------------------
  // Miss arbitration
  // ---------------------------------------------------------------------------

  logic [NUM_TLB_PORTS-1:0] miss_reqs;
  for (genvar i = 0; i < NUM_TLB_PORTS; ++i) begin : g_req_valid
    assign miss_reqs[i] = l1_l2_comms_i[i].req.valid;
  end

  logic                      miss_active;
  logic [TLB_PORT_IDX_W-1:0] miss_port;

  request_serialiser #(
      .NUM_PORTS(NUM_TLB_PORTS)
  ) tlb_req_serialiser (
      .clk_i       (clk_i),
      .rstn_i      (rstn_i),
      .tlb_misses_i(miss_reqs),
      .grant_next_i(fsm_finished),
      .active_o    (miss_active),
      .active_idx_o(miss_port)
  );

  // ---------------------------------------------------------------------------
  // Dispatch FSM
  // ---------------------------------------------------------------------------

  typedef enum logic [1:0] {
    S_IDLE,
    S_WAIT_RSP
  } state_t;
  state_t state, state_n;

  logic fsm_finished;
  assign fsm_finished = (state != S_IDLE) && (state_n == S_IDLE);

  always_comb begin
    state_n = state;
    if (!rstn_i) begin
      state_n = S_IDLE;
    end else begin
      unique case (state)
        S_IDLE: begin
          if (miss_active) state_n = S_WAIT_RSP;
        end
        S_WAIT_RSP: begin
          if (ptw_l2_comm_i.resp.valid) state_n = S_IDLE;
        end
        default: state_n = S_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rstn_i) state <= S_IDLE;
    else         state <= state_n;
  end

  // ---------------------------------------------------------------------------
  // Output muxes
  // ---------------------------------------------------------------------------

  logic fsm_serving;
  assign fsm_serving = (state == S_WAIT_RSP);

  // Forward the active miss to the PTW. store_hit is a local l1_tlb result and
  // is not part of l2_ptw_req_t — drop it here.
  always_comb begin
    l2_ptw_comm_o = '0;
    if (fsm_serving) begin
      l2_ptw_comm_o.req.valid = l1_l2_comms_i[miss_port].req.valid;
      l2_ptw_comm_o.req.vpn   = l1_l2_comms_i[miss_port].req.vpn;
      l2_ptw_comm_o.req.asid  = l1_l2_comms_i[miss_port].req.asid;
      l2_ptw_comm_o.req.prv   = l1_l2_comms_i[miss_port].req.prv;
      l2_ptw_comm_o.req.store = l1_l2_comms_i[miss_port].req.store;
      l2_ptw_comm_o.req.fetch = l1_l2_comms_i[miss_port].req.fetch;
    end
  end

  // Convert PTW response (raw pte_t + level) to tlb_entry_t for the L1 TLBs.
  // VPN and ASID are written separately by l1_tlb from the original core request,
  // so they are intentionally left zero here.
  tlb_entry_t ptw_as_tlb_entry;
  always_comb begin
    ptw_as_tlb_entry          = '0;
    ptw_as_tlb_entry.ppn      = ptw_l2_comm_i.resp.pte.ppn;
    ptw_as_tlb_entry.level    = 2'(ptw_l2_comm_i.resp.level);
    ptw_as_tlb_entry.dirty    = ptw_l2_comm_i.resp.pte.d;
    ptw_as_tlb_entry.access   = ptw_l2_comm_i.resp.pte.a;
    ptw_as_tlb_entry.perms.ur = ptw_l2_comm_i.resp.pte.r &  ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
    ptw_as_tlb_entry.perms.uw = ptw_l2_comm_i.resp.pte.w &  ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
    ptw_as_tlb_entry.perms.ux = ptw_l2_comm_i.resp.pte.x &  ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
    ptw_as_tlb_entry.perms.sr = ptw_l2_comm_i.resp.pte.r & ~ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
    ptw_as_tlb_entry.perms.sw = ptw_l2_comm_i.resp.pte.w & ~ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
    ptw_as_tlb_entry.perms.sx = ptw_l2_comm_i.resp.pte.x & ~ptw_l2_comm_i.resp.pte.u & ptw_l2_comm_i.resp.pte.v;
    ptw_as_tlb_entry.valid    = ptw_l2_comm_i.resp.valid & ~ptw_l2_comm_i.resp.error;
    ptw_as_tlb_entry.nempty   = ptw_l2_comm_i.resp.valid;
  end

  for (genvar i = 0; i < NUM_TLB_PORTS; ++i) begin : g_resp_mux
    logic port_hit;
    assign port_hit = fsm_serving && (miss_port == TLB_PORT_IDX_W'(i));

    assign l2_l1_comms_o[i].resp.valid     = port_hit & ptw_l2_comm_i.resp.valid;
    assign l2_l1_comms_o[i].resp.error     = port_hit ? ptw_l2_comm_i.resp.error : 1'b0;
    assign l2_l1_comms_o[i].resp.tlb_entry = port_hit ? ptw_as_tlb_entry : '0;
    assign l2_l1_comms_o[i].invalidate_tlb = ptw_l2_comm_i.invalidate_tlb;
  end

endmodule
