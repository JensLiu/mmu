`include "VX_config.vh"

interface VX_addr_trans_if #(
    parameter int unsigned ADDR_WIDTH = 32
) ();
    // TODO: lower bits of coaleased cacheline aligned addresses are zeros
    logic                  valid;
    logic [ADDR_WIDTH-1:0] va;
    logic [ADDR_WIDTH-1:0] pa;
    logic                  store;
    logic                  ready;
    logic                  fault;

    modport master(output valid, output va, input pa, output store, input ready, input fault);

    modport slave(input valid, input va, output pa, input store, output ready, output fault);

endinterface
