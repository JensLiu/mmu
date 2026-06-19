
interface VX_csr_mmu_if #(
    parameter int unsigned SATP_WIDTH = 32,
    parameter int unsigned MSTATUS_WIDTH = 32
);

    logic [SATP_WIDTH-1:0] satp;
    logic flush_tlb;
    logic [MSTATUS_WIDTH-1:0] mstatus;

    modport master (
        output satp,
        output flush_tlb,
        output mstatus
    );

    modport slave (
        input satp,
        input flush_tlb,
        input mstatus
    );

endinterface
