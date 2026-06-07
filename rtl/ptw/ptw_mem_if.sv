// -----------------------------------------------------------------------------
// PTW <-> memory interface (unified ready/valid).
//   req : PTW -> memory  (read a PTE, or write back / atomically OR the A/D bits)
//   rsp : memory -> PTW  (PTE data; retry on a transient nack; error on a fault)
//
// Replaces the inherited Rocket HellaCache port: a page-table walker only needs
// {addr, cmd, wdata} out and {data, retry, error} back, plus the handshake.
// The PTW is single-outstanding and consumes the response immediately.
// -----------------------------------------------------------------------------
interface ptw_mem_if;

    // Not every field is consumed on both sides (e.g. read-only walks leave
    // req_wdata unused; the PTW is single-outstanding so rsp_ready is tied high
    // and ignored), so partial UNUSEDSIGNAL on the interface nets is expected.
    /* verilator lint_off UNUSEDSIGNAL */

    // Request: PTW (master) -> memory
    logic                         req_valid, req_ready;
    logic [mmu_pkg::SIZE_VADDR:0] req_addr;
    mmu_pkg::ptw_mem_cmd_e        req_cmd;
    logic [                 63:0] req_wdata;  // PTE write-back value / AMO-OR mask

    // Response: memory -> PTW
    logic        rsp_valid, rsp_ready;
    logic [63:0] rsp_data;
    logic        rsp_error;  // access/bus fault on the PTE access

    /* verilator lint_on UNUSEDSIGNAL */

    // PTW side: drives requests, consumes responses.
    modport ptw (
        output req_valid,
        output req_addr,
        output req_cmd,
        output req_wdata,
        input  req_ready,

        input  rsp_valid,
        input  rsp_data,
        input  rsp_error,
        output rsp_ready
    );

    // Memory side: consumes requests, drives responses.
    modport mem (
        input  req_valid,
        input  req_addr,
        input  req_cmd,
        input  req_wdata,
        output req_ready,

        output rsp_valid,
        output rsp_data,
        output rsp_error,
        input  rsp_ready
    );

endinterface
