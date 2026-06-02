// -----------------------------------------------------------------------------
// L2 TLB <-> PTW interface (unified ready/valid, mirrors l1_l2_if).
//   req : TLB -> PTW   (issue a walk; carries a tag)
//   rsp : PTW -> TLB   (walk result; echoes the tag)
//   invalidate_tlb : broadcast flush PTW -> TLB (sideband, not request-matched)
// -----------------------------------------------------------------------------
interface l2_ptw_if;

    logic                    req_valid, req_ready;
    mmu_pkg::ptw_req_data_t  req_data;

    logic                    rsp_valid, rsp_ready;
    mmu_pkg::ptw_rsp_data_t  rsp_data;

    logic                    invalidate_tlb;

    // TLB side: drives requests, consumes responses.
    modport tlb (
        output req_valid,
        output req_data,
        input  req_ready,

        input  rsp_valid,
        input  rsp_data,
        output rsp_ready,

        input  invalidate_tlb
    );

    // PTW side: consumes requests, drives responses + the flush broadcast.
    modport ptw (
        input  req_valid,
        input  req_data,
        output req_ready,

        output rsp_valid,
        output rsp_data,
        input  rsp_ready,

        output invalidate_tlb
    );

endinterface
