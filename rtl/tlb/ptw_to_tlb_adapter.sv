module ptw_to_tlb_adapter
    import mmu_pkg::*;
#(
) (
    input logic clk_i,
    input logic rstn_i,

    // From L1 TLB, miss interface
    input  tlb_ptw_comm_t tlb_ptw_comm_i,
    output ptw_tlb_comm_t ptw_tlb_comm_o,

    // To L2 TLB query interface
    output cache_tlb_comm_t cache_tlb_comm_o,
    input  tlb_cache_comm_t tlb_cache_comm_i
);

    // This adapter converts L1 TLB's PTW interface (in case of L1 TLB miss)
    // into the query interface to the L2 TLB. The L2 TLB is responsible for
    // talking to the PTW.
    // However, this takes extra 2 cycle is there's a miss in the L1 TLB and a hit in the L2 TLB
    // IDLE -> SEND_REQUEST -> WAIT_RESPONSE -> IDLE

    assign cache_tlb_comm_o.req.valid       = tlb_ptw_comm_i.req.valid;
    assign cache_tlb_comm_o.req.vpn         = tlb_ptw_comm_i.req.vpn;
    assign cache_tlb_comm_o.req.asid        = tlb_ptw_comm_i.req.asid;
    assign cache_tlb_comm_o.req.instruction = tlb_ptw_comm_i.req.fetch;
    assign cache_tlb_comm_o.req.store       = tlb_ptw_comm_i.req.store;
    assign cache_tlb_comm_o.vm_enable       = 1;  // If L1 TLB is asking PTW, then we are using VM
    assign cache_tlb_comm_o.priv_lvl        = tlb_ptw_comm_i.req.prv;

    // L2 TLB response to L1 TLB only when the L2 miss is resolved
    assign ptw_tlb_comm_o.ptw_ready         = tlb_cache_comm_i.tlb_ready;
    assign ptw_tlb_comm_o.resp.valid        = !tlb_cache_comm_i.miss;
    assign ptw_tlb_comm_o.resp.error        = '0;  // TODO: propagate error from L2 TLB
    assign ptw_tlb_comm_o.resp.ppn          = tlb_cache_comm_i.resp.ppn;
    assign ptw_tlb_comm_o.resp.level        = '0;  // TODO: propagate level from L2 TLB
endmodule
