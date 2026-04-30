`timescale 1ns / 1ps
`include "VX_platform.vh"

module tlb_storage
    import mmu_pkg::*;
#(
    parameter int unsigned NUM_READ_PORTS = 1
) (
    input  logic                                      clk_i,
    input  logic                                      rstn_i,
    input  tlb_storage_read_comm_t                    tlb_storage_read_comms_i    [NUM_READ_PORTS],
    output storage_tlb_read_comm_t                    storage_tlb_read_comms_o    [NUM_READ_PORTS],
    input  tlb_storage_write_comm_t                   tlb_storage_write_comm_i,
    output logic                                      tlb_has_invalid_entry_o,
    output logic                    [TLB_ENTRIES-1:0] some_tlb_invalid_entry_idx_o
);
    assign tlb_has_invalid_entry_o      = 1'b1;
    assign some_tlb_invalid_entry_idx_o = '0;

    for (genvar i = 0; i < NUM_READ_PORTS; ++i) begin : g_stub_rsp
        assign storage_tlb_read_comms_o[i].read_resp = '0;
    end

    `UNUSED_VAR(clk_i)
    `UNUSED_VAR(rstn_i)
    `UNUSED_VAR(tlb_storage_write_comm_i)
endmodule

module top;
    import mmu_pkg::*;

    localparam int unsigned NUM_TLB_PORTS = 2;

    logic           clk_i;
    logic           rstn_i;

    core_tlb_comm_t core_tlb_comms_i[NUM_TLB_PORTS];
    tlb_core_comm_t tlb_core_comms_o[NUM_TLB_PORTS];
    l2_l1_comm_t    l2_l1_comm_i;
    l1_l2_comm_t    l1_l2_comm_o;

    l1_tlb #(
        .NUM_TLB_PORTS(NUM_TLB_PORTS)
    ) dut (
        .clk_i           (clk_i),
        .rstn_i          (rstn_i),
        .core_tlb_comms_i(core_tlb_comms_i),
        .tlb_core_comms_o(tlb_core_comms_o),
        .l2_l1_comm_i    (l2_l1_comm_i),
        .l1_l2_comm_o    (l1_l2_comm_o)
    );

    initial begin
        clk_i            = 1'b0;
        rstn_i           = 1'b0;
        core_tlb_comms_i = '{default: '0};
        l2_l1_comm_i     = '0;

        #20 rstn_i = 1'b1;
        #100 $finish;
    end

    always #5 clk_i = ~clk_i;

endmodule
