// tb_top.sv -- M3/M4: full system, everything goes through the JTAG pins
//
//   +SYS_PERIOD=<ns>   sys_clk period, default 10 (run again with 13)
`timescale 1ns/1ps

module tb_top;

    localparam int  ADDR_W = 10;
    localparam int  DATA_W = 8;
    localparam int  N      = 1 << ADDR_W;
    localparam real TCK_PERIOD = 100.0;

    logic tck = 1'b0, tms = 1'b1, tdi = 1'b0, trst_n = 1'b0;
    logic sys_clk = 1'b0, sys_rst_n = 1'b0;
    wire  tdo, tdo_en;

    real sys_period;
    initial begin
        if (!$value$plusargs("SYS_PERIOD=%f", sys_period))
            sys_period = 10.0;
        // random phase so the two clocks don't start lined up
        #($urandom_range(0, 9) * 1.37);
        forever #(sys_period/2) sys_clk = ~sys_clk;
    end

    always #(TCK_PERIOD/2) tck = ~tck;

    wire [ADDR_W-1:0] mem_addr;
    wire [DATA_W-1:0] mem_wdata, mem_rdata;
    wire mem_we, mem_re;

    jtag_mbist_top #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) dut (
        .tck(tck), .tms(tms), .tdi(tdi), .trst_n(trst_n),
        .tdo(tdo), .tdo_en(tdo_en),
        .sys_clk(sys_clk), .sys_rst_n(sys_rst_n),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata)
    );

    sram_model #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) u_sram (
        .clk(sys_clk), .addr(mem_addr), .wdata(mem_wdata),
        .we(mem_we), .re(mem_re), .rdata(mem_rdata)
    );

    `include "tb_common.svh"
    `include "jtag_tasks.svh"

    localparam int MAX_POLLS = 400;

    // poll until done, return status and how many polls it took
    task automatic wait_done(output logic fail, output logic [9:0] fa, output int polls);
        logic done;
        polls = 0;
        do begin
            mbist_read(done, fail, fa);
            polls++;
            if (polls > MAX_POLLS) test_fail("MBIST never finished");
        end while (!done);
    endtask

    // full run as a tester would do it: clear start, set start, poll
    task automatic jtag_bist(input logic [1:0] algo, output logic fail,
                             output logic [9:0] fa, output int polls);
        mbist_write(1'b0, algo);
        mbist_write(1'b1, algo);
        wait_done(fail, fa, polls);
    endtask

    task automatic expect_jtag_pass(input logic [1:0] algo);
        logic f;
        logic [9:0] fa;
        int polls;
        jtag_bist(algo, f, fa, polls);
        if (f) test_fail($sformatf("algo %b: fail at %0d", algo, fa));
        if (fa !== 0) test_fail($sformatf("algo %b: fail_addr %0d on a pass", algo, fa));
    endtask

    task automatic expect_jtag_fail(input logic [1:0] algo, input int addr, input string what);
        logic f;
        logic [9:0] fa;
        int polls;
        jtag_bist(algo, f, fa, polls);
        u_sram.clear_faults();
        if (!f) test_fail($sformatf("%s algo %b: not detected", what, algo));
        if (fa !== addr[9:0])
            test_fail($sformatf("%s algo %b: fail_addr %0d expected %0d", what, algo, fa, addr));
    endtask

    initial begin
        logic [63:0] dout;
        logic [15:0] tdr;
        logic done, f;
        logic [9:0] fa;
        int polls, a, a2, b, mid_polls, masked_polls;

        #333;
        trst_n    = 1'b1;
        sys_rst_n = 1'b1;
        $display("sys_clk period %0.1f ns, TCK period %0.1f ns", sys_period, TCK_PERIOD);
        jtag_reset();

        // ------------------------------------------------------------
        test_begin("IDCODE through top level");
        shift_dr(64'd0, 32, dout);
        if (dout[31:0] !== 32'h1BEE_F001)
            test_fail($sformatf("IDCODE %h", dout[31:0]));
        shift_ir(IR_IDCODE);
        shift_dr(64'd0, 32, dout);
        if (dout[31:0] !== 32'h1BEE_F001)
            test_fail($sformatf("IDCODE after IR load %h", dout[31:0]));
        test_pass();

        // ------------------------------------------------------------
        test_begin("MBIST TDR idle readback");
        mbist_read_raw(tdr);
        if (tdr !== 16'h0000) test_fail($sformatf("TDR after reset = %h", tdr));
        mbist_write(1'b0, 2'b01);
        mbist_read_raw(tdr);
        if (tdr[2:0] !== 3'b010) test_fail($sformatf("control bits read back %b", tdr[2:0]));
        test_pass();

        // ------------------------------------------------------------
        test_begin("no fault, both backgrounds, via JTAG");
        jtag_bist(2'b00, f, fa, polls);
        if (f) test_fail($sformatf("fail at %0d", fa));
        $display("       done after %0d polls", polls);
        mbist_read_raw(tdr);
        if (tdr[15] !== 1'b0) test_fail("reserved bit not 0");
        if (tdr[2:0] !== 3'b001) test_fail($sformatf("control readback %b", tdr[2:0]));
        expect_jtag_pass(2'b01);
        test_pass();

        // ------------------------------------------------------------
        test_begin("every fault model, via JTAG");
        for (int algo = 0; algo < 2; algo++) begin
            a = $urandom_range(1, N-2); b = $urandom_range(0, DATA_W-1);
            u_sram.inject_stuck_at(a, b, 0);
            expect_jtag_fail(algo, a, "SA0");
            a = $urandom_range(1, N-2); b = $urandom_range(0, DATA_W-1);
            u_sram.inject_stuck_at(a, b, 1);
            expect_jtag_fail(algo, a, "SA1");
            a = $urandom_range(1, N-2); b = $urandom_range(0, DATA_W-1);
            u_sram.inject_transition(a, b);
            expect_jtag_fail(algo, a, "TF-up");
            a = $urandom_range(N/2, N-2); a2 = $urandom_range(1, N/2-1);
            u_sram.inject_coupling(a, a2, b);
            expect_jtag_fail(algo, a2, "CF victim<aggr");
            a = $urandom_range(1, N/2-1); a2 = $urandom_range(N/2, N-2);
            u_sram.inject_coupling(a, a2, b);
            expect_jtag_fail(algo, a2, "CF victim>aggr");
            // boundaries
            u_sram.inject_stuck_at(0, b, 1);
            expect_jtag_fail(algo, 0, "SA1 @0");
            u_sram.inject_stuck_at(N-1, b, 0);
            expect_jtag_fail(algo, N-1, "SA0 @N-1");
            u_sram.inject_coupling(0, N-1, b);
            expect_jtag_fail(algo, N-1, "CF aggr 0 victim N-1");
            u_sram.inject_coupling(N-1, 0, b);
            expect_jtag_fail(algo, 0, "CF aggr N-1 victim 0");
        end
        test_pass();

        // ------------------------------------------------------------
        test_begin("back-to-back runs, start is edge triggered");
        u_sram.inject_stuck_at(77, 3, 1);
        expect_jtag_fail(2'b00, 77, "run 1");
        // writing start=1 again without a 0 in between must not restart,
        // so the old result (fail @77) has to still be there
        mbist_write(1'b1, 2'b00);
        jtag_idle(50);
        mbist_read(done, f, fa);
        if (!done || !f || fa !== 10'd77)
            test_fail($sformatf("level start restarted the BIST? done=%b fail=%b addr=%0d", done, f, fa));
        // proper 0 -> 1, fault removed -> must pass now
        expect_jtag_pass(2'b00);
        // and one more with a different fault to make sure it clears again
        u_sram.inject_transition(901, 6);
        expect_jtag_fail(2'b01, 901, "run 3");
        test_pass();

        // ------------------------------------------------------------
        test_begin("polling mid-run: done=0, fail_addr field=0");
        u_sram.inject_stuck_at(5, 0, 1);      // fails very early in the run
        mbist_write(1'b0, 2'b00);
        mbist_write(1'b1, 2'b00);
        mid_polls = 0;
        masked_polls = 0;
        do begin
            mbist_read_raw(tdr);
            if (tdr[3] === 1'b0) begin
                mid_polls++;
                if (tdr[14:5] !== 10'd0)
                    test_fail($sformatf("fail_addr %0d visible while done=0", tdr[14:5]));
                // count the polls where the raw bus already holds 5,
                // those are the ones where the masking actually matters
                if (dut.fail_addr_sys == 5)
                    masked_polls++;
            end
        end while (tdr[3] !== 1'b1);
        if (masked_polls < 3)
            test_fail($sformatf("only %0d polls landed while fail_addr_sys was set", masked_polls));
        if (tdr[4] !== 1'b1 || tdr[14:5] !== 10'd5)
            test_fail($sformatf("final status fail=%b addr=%0d", tdr[4], tdr[14:5]));
        u_sram.clear_faults();
        $display("       %0d polls saw done=0, %0d of them with fail_addr_sys already set",
                 mid_polls, masked_polls);
        test_pass();

        test_summary($sformatf("tb_top (sys_clk %0.0f ns)", sys_period));
        $finish;
    end

    initial begin
        #200ms;
        $fatal(1, "tb_top: timeout");
    end

    // +DUMP for a VCD (iverilog/gtkwave), ModelSim uses wave.do instead
    initial begin
        if ($test$plusargs("DUMP")) begin
            $dumpfile("out/tb_top.vcd");
            $dumpvars(0, tb_top);
        end
    end

endmodule
