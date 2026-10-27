// tb_tap.sv -- M1: TAP controller + IR/BYPASS/IDCODE unit test
`timescale 1ns/1ps

module tb_tap;

    localparam real TCK_PERIOD = 100.0;   // 10 MHz

    logic tck = 1'b0;
    logic tms = 1'b1;
    logic tdi = 1'b0;
    logic trst_n = 1'b0;
    wire  tdo, tdo_en;

    always #(TCK_PERIOD/2) tck = ~tck;

    wire [3:0] state;
    wire tlr, rti, cap_dr, sh_dr, upd_dr, cap_ir, sh_ir, upd_ir;
    wire [3:0] ir_latched;
    wire sel_mbist;

    tap_ctrl u_tap (
        .tck(tck), .tms(tms), .trst_n(trst_n),
        .state(state),
        .test_logic_reset(tlr), .run_test_idle(rti),
        .capture_dr(cap_dr), .shift_dr(sh_dr), .update_dr(upd_dr),
        .capture_ir(cap_ir), .shift_ir(sh_ir), .update_ir(upd_ir)
    );

    // no MBIST TDR in this bench, its serial out is tied low
    jtag_regs u_regs (
        .tck(tck), .trst_n(trst_n), .tdi(tdi),
        .test_logic_reset(tlr), .capture_dr(cap_dr), .shift_dr(sh_dr),
        .capture_ir(cap_ir), .shift_ir(sh_ir), .update_ir(upd_ir),
        .mbist_tdo(1'b0), .sel_mbist(sel_mbist), .ir_latched(ir_latched),
        .tdo(tdo), .tdo_en(tdo_en)
    );

    `include "tb_common.svh"
    `include "jtag_tasks.svh"

    localparam [3:0] S_TLR = 4'hF;
    localparam [31:0] EXP_IDCODE = 32'h1BEE_F001;

    // check that the 1-bit bypass path returns din delayed by one,
    // with the captured 0 coming out first
    task automatic check_bypass(input string tag);
        logic [63:0] din, dout;
        din = {$urandom, $urandom};
        shift_dr(din, 40, dout);
        if (dout[0] !== 1'b0)
            test_fail($sformatf("%s: first bit out should be the captured 0", tag));
        for (int i = 1; i < 40; i++)
            if (dout[i] !== din[i-1])
                test_fail($sformatf("%s: bit %0d got %b expected %b", tag, i, dout[i], din[i-1]));
    endtask

    initial begin
        logic [63:0] dout;
        logic [3:0]  cap;
        bit   [15:0] seen;
        int          walk;

        repeat (3) @(posedge tck);
        trst_n = 1'b1;

        // ------------------------------------------------------------
        test_begin("tms=1 x5 returns to Test-Logic-Reset from any state");
        seen = '0;
        for (int iter = 0; iter < 400; iter++) begin
            walk = $urandom_range(1, 24);
            repeat (walk) jtag_tms($urandom_range(0, 1));
            seen[state] = 1'b1;
            repeat (5) jtag_tms(1'b1);
            if (state !== S_TLR)
                test_fail($sformatf("ended in state %h after 5 x TMS=1", state));
        end
        if (seen !== 16'hFFFF)
            test_fail($sformatf("random walk only reached states %b", seen));
        // async reset too
        jtag_reset();
        jtag_tms(1'b1);
        trst_n = 1'b0;
        #1;
        if (state !== S_TLR) test_fail("trst_n did not force TLR");
        @(negedge tck) trst_n = 1'b1;
        test_pass();

        // ------------------------------------------------------------
        test_begin("IDCODE selected after reset");
        jtag_reset();
        if (ir_latched !== IR_IDCODE) test_fail("ir_latched not IDCODE after reset");
        shift_dr(64'd0, 32, dout);
        if (dout[31:0] !== EXP_IDCODE)
            test_fail($sformatf("read %h expected %h", dout[31:0], EXP_IDCODE));
        // second read must give the same value (capture reloads it)
        shift_dr({32'd0, 32'hFFFF_FFFF}, 32, dout);
        if (dout[31:0] !== EXP_IDCODE)
            test_fail($sformatf("2nd read %h", dout[31:0]));
        test_pass();

        // ------------------------------------------------------------
        test_begin("BYPASS is a 1-bit delay");
        shift_ir(IR_BYPASS);
        if (ir_latched !== IR_BYPASS) test_fail("IR did not update");
        check_bypass("bypass");
        test_pass();

        // ------------------------------------------------------------
        test_begin("IR capture value ends in 01");
        shift_ir_cap(IR_IDCODE, cap);
        if (cap[1:0] !== 2'b01)
            test_fail($sformatf("captured IR %b", cap));
        if (cap !== 4'b0001)
            test_fail($sformatf("captured IR %b, design captures 0001", cap));
        test_pass();

        // ------------------------------------------------------------
        test_begin("undefined instructions behave as BYPASS");
        for (int code = 0; code < 16; code++) begin
            if (code == IR_IDCODE || code == IR_MBIST || code == IR_BYPASS)
                continue;
            shift_ir(code[3:0]);
            if (ir_latched !== code[3:0])
                test_fail($sformatf("IR did not take %b", code[3:0]));
            check_bypass($sformatf("ir=%b", code[3:0]));
        end
        test_pass();

        test_summary("tb_tap");
        $finish;
    end

    initial begin
        #5ms;
        $fatal(1, "tb_tap: timeout");
    end

endmodule
