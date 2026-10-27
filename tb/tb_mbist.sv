// tb_mbist.sv -- M2: mbist_ctrl + sram_model, driven directly (no JTAG)
`timescale 1ns/1ps

module tb_mbist;

`ifdef ADDR_W_OVR
    localparam int ADDR_W = `ADDR_W_OVR;
`else
    localparam int ADDR_W = 10;
`endif
    localparam int DATA_W = 8;
    localparam int N      = 1 << ADDR_W;

    // edge detect + ARM + read latency of the final r0 + one cycle so
    // done comes after fail is final
    localparam int EXP_CYCLES = 10*N + 4;

    logic sys_clk = 1'b0;
    logic sys_rst_n = 1'b0;
    logic start_sync = 1'b0;
    logic [1:0] algo_sel_sync = 2'b00;

    always #5 sys_clk = ~sys_clk;

    wire [ADDR_W-1:0] mem_addr;
    wire [DATA_W-1:0] mem_wdata, mem_rdata;
    wire mem_we, mem_re;
    wire done, fail;
    wire [ADDR_W-1:0] fail_addr;

    mbist_ctrl #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) dut (
        .sys_clk(sys_clk), .sys_rst_n(sys_rst_n),
        .start_sync(start_sync), .algo_sel_sync(algo_sel_sync),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata),
        .done(done), .fail(fail), .fail_addr(fail_addr)
    );

    sram_model #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) u_sram (
        .clk(sys_clk), .addr(mem_addr), .wdata(mem_wdata),
        .we(mem_we), .re(mem_re), .rdata(mem_rdata)
    );

    `include "tb_common.svh"

    int n_rd, n_wr;
    always @(posedge sys_clk) begin
        if (mem_re) n_rd++;
        if (mem_we) n_wr++;
        if (mem_re && mem_we) $fatal(1, "re and we both high");
    end

    task automatic run_bist(input logic [1:0] algo, output logic d, output logic f,
                            output int fa, output int cycles);
        n_rd = 0;
        n_wr = 0;
        @(negedge sys_clk);
        algo_sel_sync = algo;
        start_sync    = 1'b1;
        cycles = 0;
        do begin
            @(posedge sys_clk);
            #1;
            cycles++;
            if (cycles > 12*N) test_fail("timeout waiting for done");
        end while (!done);
        d  = done;
        f  = fail;
        fa = fail_addr;
        @(negedge sys_clk);
        start_sync = 1'b0;
        repeat (3) @(posedge sys_clk);
        if (!done) test_fail("done did not hold after start dropped");
    endtask

    task automatic expect_pass(input logic [1:0] algo);
        logic d, f;
        int fa, cyc;
        run_bist(algo, d, f, fa, cyc);
        if (f) test_fail($sformatf("algo %b: unexpected fail at addr %0d", algo, fa));
    endtask

    task automatic expect_fail(input logic [1:0] algo, input int addr, input string what);
        logic d, f;
        int fa, cyc;
        run_bist(algo, d, f, fa, cyc);
        u_sram.clear_faults();
        if (!f)
            test_fail($sformatf("%s algo %b: fault not detected", what, algo));
        if (fa != addr)
            test_fail($sformatf("%s algo %b: fail_addr %0d, expected %0d", what, algo, fa, addr));
    endtask

    initial begin
        logic d, f;
        int fa, cyc, a, a2, b;

        repeat (3) @(posedge sys_clk);
        @(negedge sys_clk) sys_rst_n = 1'b1;
        repeat (2) @(posedge sys_clk);

        // ------------------------------------------------------------
        test_begin("no fault, solid background (00), cycle count");
        run_bist(2'b00, d, f, fa, cyc);
        if (f) test_fail($sformatf("fail at %0d", fa));
        if (cyc != EXP_CYCLES)
            test_fail($sformatf("took %0d cycles, expected %0d", cyc, EXP_CYCLES));
        if (n_rd != 5*N || n_wr != 5*N)
            test_fail($sformatf("%0d reads %0d writes, expected %0d each", n_rd, n_wr, 5*N));
        $display("       %0d words, %0d cycles (10N = %0d)", N, cyc, 10*N);
        test_pass();

        // ------------------------------------------------------------
        test_begin("no fault, checkerboard background (01)");
        run_bist(2'b01, d, f, fa, cyc);
        if (f) test_fail($sformatf("fail at %0d", fa));
        if (cyc != EXP_CYCLES) test_fail($sformatf("took %0d cycles", cyc));
        test_pass();

        // ------------------------------------------------------------
        test_begin("stuck-at-0 / stuck-at-1");
        for (int algo = 0; algo < 2; algo++) begin
            for (int v = 0; v < 2; v++) begin
                a = $urandom_range(1, N-2);
                b = $urandom_range(0, DATA_W-1);
                u_sram.inject_stuck_at(a, b, v);
                expect_fail(algo, a, $sformatf("SA%0d @%0d.%0d", v, a, b));
            end
        end
        test_pass();

        // ------------------------------------------------------------
        test_begin("transition fault");
        for (int algo = 0; algo < 2; algo++) begin
            a = $urandom_range(1, N-2);
            b = $urandom_range(0, DATA_W-1);
            u_sram.inject_transition(a, b);
            expect_fail(algo, a, $sformatf("TF-up @%0d.%0d", a, b));
            a = $urandom_range(1, N-2);
            u_sram.inject_transition_dn(a, b);
            expect_fail(algo, a, $sformatf("TF-dn @%0d.%0d", a, b));
        end
        test_pass();

        // ------------------------------------------------------------
        test_begin("coupling fault CFid<up;1>, victim below and above aggressor");
        for (int algo = 0; algo < 2; algo++) begin
            b  = $urandom_range(0, DATA_W-1);
            a  = $urandom_range(N/2, N-2);      // aggressor
            a2 = $urandom_range(1, N/2 - 1);    // victim < aggressor
            u_sram.inject_coupling(a, a2, b);
            expect_fail(algo, a2, $sformatf("CF aggr %0d victim %0d", a, a2));
            a  = $urandom_range(1, N/2 - 1);    // aggressor
            a2 = $urandom_range(N/2, N-2);      // victim > aggressor
            u_sram.inject_coupling(a, a2, b);
            expect_fail(algo, a2, $sformatf("CF aggr %0d victim %0d", a, a2));
        end
        test_pass();

        // ------------------------------------------------------------
        test_begin("faults at address 0 and N-1");
        for (int algo = 0; algo < 2; algo++) begin
            for (int k = 0; k < 2; k++) begin
                a  = k ? N-1 : 0;
                a2 = k ? 0 : N-1;
                b  = $urandom_range(0, DATA_W-1);
                u_sram.inject_stuck_at(a, b, 0);
                expect_fail(algo, a, $sformatf("SA0 @%0d", a));
                u_sram.inject_stuck_at(a, b, 1);
                expect_fail(algo, a, $sformatf("SA1 @%0d", a));
                u_sram.inject_transition(a, b);
                expect_fail(algo, a, $sformatf("TF-up @%0d", a));
                u_sram.inject_coupling(a2, a, b);
                expect_fail(algo, a, $sformatf("CF aggr %0d victim %0d", a2, a));
            end
        end
        test_pass();

        // ------------------------------------------------------------
        test_begin("restart clears fail/fail_addr");
        u_sram.inject_stuck_at(N/3, 2, 1);
        expect_fail(2'b00, N/3, "SA1 before restart");
        run_bist(2'b00, d, f, fa, cyc);
        if (f || fa != 0)
            test_fail($sformatf("stale result after restart: fail=%b addr=%0d", f, fa));
        test_pass();

        test_summary("tb_mbist");
        $finish;
    end

endmodule
