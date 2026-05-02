`timescale 1ns / 1ps
`include "VX_platform.vh"

`ifndef TB_NUM_TLB_PORTS
`define TB_NUM_TLB_PORTS 4
`endif

// Directed L1 TLB testbench — scenarios T0–T8 per rtl/tb/tlb/test_spec.md
module top;
    import mmu_pkg::*;

    localparam int unsigned NUM_TLB_PORTS = `TB_NUM_TLB_PORTS;
    localparam logic [LEVEL_BITS-1:0] LEAF_LVL = LEVEL_BITS'(LEVELS - 1);

    typedef logic [VPN_SIZE + ASID_SIZE - 1:0] tb_xref_k_t;

    typedef struct packed {
        logic [VPN_SIZE-1:0]  vpn;
        logic [ASID_SIZE-1:0] asid;
        logic [PPN_SIZE-1:0]  ppn;
        logic                 error;
        int unsigned          delay_cy;
    } golden_pte_t;

    golden_pte_t golden_rom[$];

    function automatic tb_xref_k_t tb_pack(input logic [VPN_SIZE-1:0] vpn,
                                           input logic [ASID_SIZE-1:0] asid);
        tb_pack = {asid, vpn};
    endfunction

    function automatic golden_pte_t golden_lookup(input logic [VPN_SIZE-1:0] v,
                                                  input logic [ASID_SIZE-1:0] a);
        foreach (golden_rom[i]) begin
            if (golden_rom[i].vpn == v && golden_rom[i].asid == a) return golden_rom[i];
        end
        $fatal(1, "golden_lookup: no entry for vpn=%h asid=%h", v, a);
    endfunction

    task automatic golden_clear;
        golden_rom.delete();
    endtask

    task automatic golden_add(input golden_pte_t g);
        golden_rom.push_back(g);
    endtask

    logic clk_i;
    logic rstn_i;

    // Waveform trace (requires Verilator --trace-fst or --trace when building)
    initial begin
        string wave_path;
        if (!$value$plusargs("TRACE_OUT=%s", wave_path)) wave_path = "tlb_tb.fst";
        $dumpfile(wave_path);
        $dumpvars(0, top);
    end

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

    // -------------------------------------------------------------------------
    // PTW/L2 mock — serialised accepts, programmable delay, golden PTE payload
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        MW_IDLE,
        MW_WAIT
    } mw_state_e;
    mw_state_e                   mw_st;
    int unsigned                 mw_ctr;
    golden_pte_t                 mw_saved;

    logic        [ VPN_SIZE-1:0] mw_accept_vpn;
    logic        [ASID_SIZE-1:0] mw_accept_asid;
    logic        [ PPN_SIZE-1:0] mw_accept_ppn;

    int unsigned                 ptw_accept_cnt;
    logic                        tb_clr_ptw_cnt;

    function automatic void fill_ptw_resp(input golden_pte_t g);
        l2_l1_comm_i.resp.error   = g.error;
        l2_l1_comm_i.resp.level   = LEAF_LVL;
        l2_l1_comm_i.resp.pte.ppn = g.ppn;
        l2_l1_comm_i.resp.pte.r   = 1'b1;
        l2_l1_comm_i.resp.pte.w   = 1'b1;
        l2_l1_comm_i.resp.pte.x   = 1'b1;
        l2_l1_comm_i.resp.pte.v   = 1'b1;
        l2_l1_comm_i.resp.pte.u   = 1'b0;
        l2_l1_comm_i.resp.pte.a   = 1'b1;
        l2_l1_comm_i.resp.pte.d   = 1'b1;
        l2_l1_comm_i.resp.pte.rfs = '0;
        l2_l1_comm_i.resp.pte.g   = 1'b0;
    endfunction

    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            mw_st                   <= MW_IDLE;
            mw_ctr                  <= '0;
            l2_l1_comm_i.resp.valid <= 1'b0;
            ptw_accept_cnt          <= '0;
        end else begin
            l2_l1_comm_i.resp.valid <= 1'b0;

            if (tb_clr_ptw_cnt) ptw_accept_cnt <= '0;
            else if ((mw_st == MW_IDLE) && l1_l2_comm_o.req.valid && l2_l1_comm_i.ptw_ready)
                ptw_accept_cnt <= ptw_accept_cnt + 1;

            case (mw_st)
                MW_IDLE: begin
                    if (l1_l2_comm_o.req.valid && l2_l1_comm_i.ptw_ready) begin
                        automatic
                        golden_pte_t
                        g = golden_lookup(
                            l1_l2_comm_o.req.vpn, l1_l2_comm_o.req.asid
                        );
                        mw_saved       <= g;
                        mw_accept_vpn  <= l1_l2_comm_o.req.vpn;
                        mw_accept_asid <= l1_l2_comm_o.req.asid;
                        mw_accept_ppn  <= g.ppn;
                        mw_ctr         <= g.delay_cy;
                        if (g.delay_cy == 0) begin
                            fill_ptw_resp(g);
                            l2_l1_comm_i.resp.valid <= 1'b1;
                            mw_st                   <= MW_IDLE;
                        end else mw_st <= MW_WAIT;
                    end
                end
                MW_WAIT: begin
                    if (mw_ctr > 1) mw_ctr <= mw_ctr - 1;
                    else begin
                        fill_ptw_resp(mw_saved);
                        l2_l1_comm_i.resp.valid <= 1'b1;
                        mw_st                   <= MW_IDLE;
                    end
                end
                default: mw_st <= MW_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Reference fills (shadow what becomes resident after the PTW write completes)
    // -------------------------------------------------------------------------
    logic [PPN_SIZE-1:0] ref_ppn[tb_xref_k_t];

    function automatic void ref_clear;
        ref_ppn.delete();
    endfunction

    // -------------------------------------------------------------------------
    // Scoreboard — expect miss iff key not yet installed (same timing as storage)
    // -------------------------------------------------------------------------
    int unsigned sb_err;
    logic        sb_enable;

    function automatic void sb_check_port(input int p);
        tb_xref_k_t                k;
        logic                      exp_miss;
        logic       [PPN_SIZE-1:0] exp_ppn;
        logic                      resident;
        logic       [VPN_SIZE-1:0] vpn_lo;

        if (!sb_enable) return;
        if (!core_tlb_comms_i[p].req.valid || !core_tlb_comms_i[p].vm_enable) return;

        vpn_lo   = core_tlb_comms_i[p].req.vpn[VPN_SIZE-1:0];
        k        = tb_pack(vpn_lo, core_tlb_comms_i[p].req.asid);
        resident = ref_ppn.exists(k);

        exp_miss = !resident;
        if (tlb_core_comms_o[p].resp.miss !== exp_miss) begin
            $error("SB port %0d: miss mismatch key=%h exp=%b got=%b", p, k, exp_miss,
                   tlb_core_comms_o[p].resp.miss);
            sb_err++;
        end
        if (!exp_miss) begin
            exp_ppn = ref_ppn[k];
            if (tlb_core_comms_o[p].resp.ppn !== exp_ppn) begin
                $error("SB port %0d: PPN mismatch key=%h exp=%h got=%h", p, k, exp_ppn,
                       tlb_core_comms_o[p].resp.ppn);
                sb_err++;
            end
            if (tlb_core_comms_o[p].resp.xcpt.load || tlb_core_comms_o[p].resp.xcpt.store ||
                tlb_core_comms_o[p].resp.xcpt.fetch) begin
                $error("SB port %0d: unexpected xcpt on hit key=%h", p, k);
                sb_err++;
            end
        end
    endfunction

    // Single sequential block: scoreboard sees ref state *before* this cycle's PTW fill applies.
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            ref_clear();
        end else begin
            if (sb_enable) begin
                for (int p = 0; p < int'(NUM_TLB_PORTS); p++) sb_check_port(p);
            end
            if (l2_l1_comm_i.invalidate_tlb) begin
                ref_clear();
            end else if (l2_l1_comm_i.resp.valid && !l2_l1_comm_i.resp.error) begin
                ref_ppn[tb_pack(mw_accept_vpn, mw_accept_asid)] = mw_accept_ppn;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Monitors / assertions — idle PTW traffic
    // -------------------------------------------------------------------------
    int unsigned idle_ptw_v_seen;

    always_ff @(posedge clk_i) begin
        if (rstn_i && sb_enable && scenario_idle_chk) begin
            if (l1_l2_comm_o.req.valid) idle_ptw_v_seen++;
        end
    end

    logic scenario_idle_chk;

    // -------------------------------------------------------------------------
    // Driver helpers
    // -------------------------------------------------------------------------
    task automatic ports_idle;
        for (int p = 0; p < int'(NUM_TLB_PORTS); p++) begin
            core_tlb_comms_i[p] = '0;
        end
    endtask

    task automatic drive_port(input int p, input logic v, input logic [VPN_SIZE-1:0] vpn,
                              input logic [ASID_SIZE-1:0] asid, input logic is_fetch,
                              input logic is_store);
        core_tlb_comms_i[p].req.valid       = v;
        core_tlb_comms_i[p].req.vpn         = {(VPN_SIZE + 1)'(vpn)};
        core_tlb_comms_i[p].req.asid        = asid;
        core_tlb_comms_i[p].req.instruction = is_fetch;
        core_tlb_comms_i[p].req.store       = is_store;
        core_tlb_comms_i[p].req.passthrough = 1'b0;
        core_tlb_comms_i[p].priv_lvl        = 2'b01;
        core_tlb_comms_i[p].vm_enable       = 1'b1;
    endtask

    task automatic wait_cycles(input int n);
        repeat (n) @(posedge clk_i);
    endtask

    task automatic tb_invalidate;
        @(posedge clk_i);
        l2_l1_comm_i.invalidate_tlb <= 1'b1;
        @(posedge clk_i);
        l2_l1_comm_i.invalidate_tlb <= 1'b0;
        wait_cycles(4);
    endtask

    task automatic clr_ptw_cnt;
        @(posedge clk_i);
        tb_clr_ptw_cnt <= 1'b1;
        @(posedge clk_i);
        tb_clr_ptw_cnt <= 1'b0;
    endtask

    function automatic bit ports_all_hit;
        ports_all_hit = 1'b1;
        for (int p = 0; p < int'(NUM_TLB_PORTS); p++) begin
            if (core_tlb_comms_i[p].req.valid && tlb_core_comms_o[p].resp.miss)
                ports_all_hit = 1'b0;
        end
    endfunction

    task automatic wait_all_requested_hit(input int timeout);
        int t;
        t = 0;
        while (t < timeout) begin
            @(posedge clk_i);
            if (ports_all_hit()) return;
            t++;
        end
        $fatal(1, "timeout waiting for hits");
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        clk_i                  = 1'b0;
        rstn_i                 = 1'b0;
        core_tlb_comms_i       = '{default: '0};
        l2_l1_comm_i           = '0;
        l2_l1_comm_i.ptw_ready = 1'b1;
        sb_enable              = 1'b0;
        scenario_idle_chk      = 1'b0;
        sb_err                 = 0;
        tb_clr_ptw_cnt         = 1'b0;

        wait_cycles(4);
        rstn_i = 1'b1;
        wait_cycles(2);

        // T0 — idle sanity (scenario tag)
        $display("T0: reset / idle PTW");
        scenario_idle_chk = 1'b1;
        sb_enable         = 1'b1;
        ports_idle();
        wait_cycles(12);
        scenario_idle_chk = 1'b0;
        if (idle_ptw_v_seen != 0) $fatal(1, "T0: unexpected PTW req");

        // T1 — single-port miss → walk → hit
        $display("T1: single-port miss→hit");
        golden_clear();
        golden_add('{vpn: 20'h0_1234, asid: 9'h01, ppn: 22'h03_A5500, error: 1'b0, delay_cy: 2
                   });
        tb_invalidate();
        ref_clear();
        clr_ptw_cnt();
        drive_port(0, 1'b1, 20'h00_1234, 9'h01, 1'b0, 1'b0);
        wait_all_requested_hit(200);
        if (ptw_accept_cnt != 1) $fatal(1, "T1: PTW accept count");
        ports_idle();
        wait_cycles(2);

        // Prime distinct translations for multi-port hit tests
        $display("prime A–D via walks");
        golden_clear();
        golden_add('{vpn: 20'hA001, asid: 9'h02, ppn: 22'h01_1000, error: 1'b0, delay_cy: 1});
        golden_add('{vpn: 20'hA002, asid: 9'h02, ppn: 22'h02_2000, error: 1'b0, delay_cy: 1});
        golden_add('{vpn: 20'hA003, asid: 9'h02, ppn: 22'h03_3000, error: 1'b0, delay_cy: 1});
        golden_add('{vpn: 20'hA004, asid: 9'h02, ppn: 22'h04_4000, error: 1'b0, delay_cy: 1});
        tb_invalidate();
        ref_clear();

        // fills (same golden_rom covers all)
        for (int k = 1; k <= 4; k++) begin
            drive_port(0, 1'b1, 20'(32'hA000 + k), 9'h02, 1'b0, 1'b0);
            wait_all_requested_hit(200);
            ports_idle();
            wait_cycles(2);
        end

        // T2 — simultaneous hits, different keys (use available ports)
        $display("T2: multi-port hits different keys");
        if (NUM_TLB_PORTS < 4) $display("T2: skip (NUM_TLB_PORTS<4)");
        else begin
            drive_port(0, 1'b1, 20'hA001, 9'h02, 1'b0, 1'b0);
            drive_port(1, 1'b1, 20'hA002, 9'h02, 1'b0, 1'b0);
            drive_port(2, 1'b1, 20'hA003, 9'h02, 1'b0, 1'b0);
            drive_port(3, 1'b1, 20'hA004, 9'h02, 1'b0, 1'b0);
            @(posedge clk_i);
            ports_idle();
            wait_cycles(2);
        end

        // T3 — simultaneous hits, same key
        $display("T3: multi-port hits same key");
        if (NUM_TLB_PORTS < 2) $display("T3: skip");
        else begin
            for (int p = 0; p < int'(NUM_TLB_PORTS); p++)
            drive_port(p, 1'b1, 20'hA001, 9'h02, 1'b0, 1'b0);
            @(posedge clk_i);
            ports_idle();
            wait_cycles(2);
        end

        // T4 — simultaneous misses, same key → single PTW
        $display("T4: simultaneous misses same key");
        tb_invalidate();
        ref_clear();
        golden_clear();
        golden_add('{vpn: 20'hB001, asid: 9'h03, ppn: 22'h10ABC0, error: 1'b0, delay_cy: 2});
        clr_ptw_cnt();
        for (int p = 0; p < int'(NUM_TLB_PORTS); p++)
        drive_port(p, 1'b1, 20'hB001, 9'h03, 1'b0, 1'b0);
        wait_all_requested_hit(400);
        if (ptw_accept_cnt != 1) $fatal(1, "T4: expected single PTW accept");
        ports_idle();
        wait_cycles(3);

        // T5 — simultaneous misses, different keys → serialized PTW
        $display("T5: simultaneous misses different keys");
        tb_invalidate();
        ref_clear();
        golden_clear();
        golden_add('{vpn: 20'hC001, asid: 9'h04, ppn: 22'h200010, error: 1'b0, delay_cy: 1});
        golden_add('{vpn: 20'hC002, asid: 9'h04, ppn: 22'h200020, error: 1'b0, delay_cy: 1});
        golden_add('{vpn: 20'hC003, asid: 9'h04, ppn: 22'h200030, error: 1'b0, delay_cy: 1});
        golden_add('{vpn: 20'hC004, asid: 9'h04, ppn: 22'h200040, error: 1'b0, delay_cy: 1});
        clr_ptw_cnt();
        if (NUM_TLB_PORTS >= 4) begin
            drive_port(0, 1'b1, 20'hC001, 9'h04, 1'b0, 1'b0);
            drive_port(1, 1'b1, 20'hC002, 9'h04, 1'b0, 1'b0);
            drive_port(2, 1'b1, 20'hC003, 9'h04, 1'b0, 1'b0);
            drive_port(3, 1'b1, 20'hC004, 9'h04, 1'b0, 1'b0);
        end else begin
            for (int p = 0; p < int'(NUM_TLB_PORTS); p++)
            drive_port(p, 1'b1, 20'(32'hC000 + p + 1), 9'h04, 1'b0, 1'b0);
        end
        wait_all_requested_hit(800);
        if (ptw_accept_cnt != NUM_TLB_PORTS) $fatal(1, "T5: PTW accept count");
        ports_idle();
        wait_cycles(3);

        // T6 — mixed hit + miss
        $display("T6: mixed hit and miss");
        golden_add('{vpn: 20'hD001, asid: 9'h05, ppn: 22'h305010, error: 1'b0, delay_cy: 1});
        golden_add('{vpn: 20'hD002, asid: 9'h05, ppn: 22'h305020, error: 1'b0, delay_cy: 1});
        drive_port(0, 1'b1, 20'hD001, 9'h05, 1'b0, 1'b0);
        wait_all_requested_hit(200);
        ports_idle();
        wait_cycles(2);
        clr_ptw_cnt();
        drive_port(0, 1'b1, 20'hD001, 9'h05, 1'b0, 1'b0);
        if (NUM_TLB_PORTS > 1) drive_port(1, 1'b1, 20'hD002, 9'h05, 1'b0, 1'b0);
        wait_all_requested_hit(400);
        if (NUM_TLB_PORTS > 1 && ptw_accept_cnt != 1) $fatal(1, "T6: PTW count");
        ports_idle();
        wait_cycles(3);

        // T7 — PTW backpressure
        $display("T7: PTW stall / backpressure");
        tb_invalidate();
        ref_clear();
        golden_clear();
        golden_add('{vpn: 20'hE001, asid: 9'h06, ppn: 22'h35E010, error: 1'b0, delay_cy: 2});
        clr_ptw_cnt();
        drive_port(0, 1'b1, 20'hE001, 9'h06, 1'b0, 1'b0);
        fork
            begin
                wait_cycles(1);
                while (!l1_l2_comm_o.req.valid) @(posedge clk_i);
                repeat (7) begin
                    @(posedge clk_i);
                    l2_l1_comm_i.ptw_ready <= 1'b0;
                end
                @(posedge clk_i);
                l2_l1_comm_i.ptw_ready <= 1'b1;
            end
        join_none
        wait_all_requested_hit(600);
        if (ptw_accept_cnt != 1) $fatal(1, "T7: PTW accepts");
        ports_idle();
        wait_cycles(4);

        // T8 — burst queue drain (distinct keys, bounded by port count)
        $display("T8: burst drain");
        tb_invalidate();
        ref_clear();
        golden_clear();
        for (int j = 0; j < int'(NUM_TLB_PORTS); j++)
        golden_add('{vpn: 20'(32'hF010 + j), asid: 9'h07, ppn: 22'(32'h50_000 + j), error: 1'b0,
                   delay_cy: 3});
        clr_ptw_cnt();
        for (int p = 0; p < int'(NUM_TLB_PORTS); p++)
        drive_port(p, 1'b1, 20'(32'hF010 + p), 9'h07, 1'b0, 1'b0);
        wait_all_requested_hit(2000);
        if (ptw_accept_cnt != NUM_TLB_PORTS) $fatal(1, "T8: PTW accepts");
        ports_idle();
        wait_cycles(4);

        sb_enable = 1'b0;
        if (sb_err != 0) $fatal(1, "scoreboard reported %0d errors", sb_err);
        $display("PASS: L1 TLB directed TB (NUM_TLB_PORTS=%0d)", NUM_TLB_PORTS);
        $finish(0);
    end

    always #5 clk_i = ~clk_i;

endmodule
