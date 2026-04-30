module pte_perm_check
    import mmu_pkg::*;
#(
) (
    // input
    input  csr_mstatus_t ptw_status_i,
    input  tlb_entry_t   tlb_entry_i,
    input  logic         sv_priv_lvl_i,
    input  logic         is_store_i,
    // output
    output logic         store_hit_o,
    output logic         read_ok_o,
    output logic         write_ok_o,
    output logic         exec_ok_o
);

    // Store to an entry that is NOT dirty (Need to update the PT)
    always_comb begin
        if (is_store_i) begin
            if (tlb_entry_i.dirty) begin  // dirty page, no problem
                store_hit_o = 1'b1;
            end else if (!write_ok_o) begin // we dont have write perms, so hit in order to raise STORE xcpt
                store_hit_o = 1'b1;
            end else begin // we have the right permissions, but the page is not set as dirty, we have to mark it as so in the PT
                store_hit_o = 1'b0;
            end
        end else begin  // not a store, no problem
            store_hit_o = 1'b1;
        end
    end

    // Read Permission Check
    always_comb begin
        if (sv_priv_lvl_i) begin
            if (ptw_status_i.sum) begin
                // if SUM bit is set, in SV we can read in readable user pages
                if (ptw_status_i.mxr) begin
                    // if MXR bit is set, executable pages can be also readed
                    read_ok_o = tlb_entry_i.perms.sr | tlb_entry_i.perms.ur | tlb_entry_i.perms.sx | tlb_entry_i.perms.ux;
                end else begin
                    read_ok_o = tlb_entry_i.perms.sr | tlb_entry_i.perms.ur;
                end
            end else begin
                if (ptw_status_i.mxr) begin
                    // if MXR bit is set, executable pages can be also readed
                    read_ok_o = tlb_entry_i.perms.sr | tlb_entry_i.perms.sx;
                end else begin
                    read_ok_o = tlb_entry_i.perms.sr;
                end
            end
        end else begin  // User mode
            if (ptw_status_i.mxr) begin  // if MXR bit is set, executable pages can be also readed
                read_ok_o = tlb_entry_i.perms.ur | tlb_entry_i.perms.ux;
            end else begin
                read_ok_o = tlb_entry_i.perms.ur;
            end
        end
    end

    // Write Permission Check
    always_comb begin
        if (sv_priv_lvl_i) begin
            if (ptw_status_i.sum) begin // if SUM bit is set, in SV we can write in writable user pages
                write_ok_o = tlb_entry_i.perms.sw | tlb_entry_i.perms.uw;
            end else begin
                write_ok_o = tlb_entry_i.perms.sw;
            end
        end else begin
            write_ok_o = tlb_entry_i.perms.uw;
        end
    end

    // Execution Permission Check
    assign exec_ok_o = (sv_priv_lvl_i) ? tlb_entry_i.perms.sx : tlb_entry_i.perms.ux;

endmodule
