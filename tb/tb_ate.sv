// tb_ate.sv -- poor man's ATE: replays a cycle-based .vec file on the pins
//
// Each vector line is one TCK: <tms><tdi><exp>. TMS/TDI are driven on the
// falling edge, TDO is strobed on the rising edge when exp is 0/1.
// Mismatches go to a fail log (one line per failing cycle), like an ATE
// datalog. A defect can be put into the SRAM to play a bad die.
//
//   +VEC=<file>  +FAILLOG=<file>  +SYS_PERIOD=<ns>  +DIE=<name>
//   +FTYPE=0 none, 1 SA, 2 TF-up, 3 TF-down, 4 CFid<up;1>
//   +FADDR (victim) +FBIT +FVAL (SA value) +FAGGR (CF aggressor)
`timescale 1ns/1ps

module tb_ate;

    localparam int  ADDR_W = 10;
    localparam int  DATA_W = 8;
    localparam real TCK_PERIOD = 100.0;

    logic tck = 1'b0, tms = 1'b1, tdi = 1'b0, trst_n = 1'b0;
    logic sys_clk = 1'b0, sys_rst_n = 1'b0;
    wire  tdo, tdo_en;

    real sys_period;
    initial begin
        if (!$value$plusargs("SYS_PERIOD=%f", sys_period))
            sys_period = 10.0;
        #3.1;
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

    initial begin
        string vec_file, log_file, die, line;
        int fd, fl;
        int ftype, faddr, fbit, fval, faggr;
        int cyc = 0, strobes = 0, fails = 0;
        logic got;

        if (!$value$plusargs("VEC=%s", vec_file))     vec_file = "out/mbist_prod.vec";
        if (!$value$plusargs("FAILLOG=%s", log_file)) log_file = "out/fail.log";
        if (!$value$plusargs("DIE=%s", die))          die = "die0";
        if (!$value$plusargs("FTYPE=%d", ftype)) ftype = 0;
        if (!$value$plusargs("FADDR=%d", faddr)) faddr = 0;
        if (!$value$plusargs("FBIT=%d", fbit))   fbit  = 0;
        if (!$value$plusargs("FVAL=%d", fval))   fval  = 0;
        if (!$value$plusargs("FAGGR=%d", faggr)) faggr = 0;

        case (ftype)
            0: ;
            1: u_sram.inject_stuck_at(faddr, fbit, fval);
            2: u_sram.inject_transition(faddr, fbit);
            3: u_sram.inject_transition_dn(faddr, fbit);
            4: u_sram.inject_coupling(faggr, faddr, fbit);
            default: $fatal(1, "bad FTYPE %0d", ftype);
        endcase

        fd = $fopen(vec_file, "r");
        if (fd == 0) $fatal(1, "cannot open %s", vec_file);
        fl = $fopen(log_file, "w");
        $fdisplay(fl, "# datalog die=%s vec=%s sys_clk=%0.1fns", die, vec_file, sys_period);
        $fdisplay(fl, "# cycle exp got");

        #333;
        trst_n    = 1'b1;
        sys_rst_n = 1'b1;

        while ($fgets(line, fd)) begin
            if (line.len() < 3 || line[0] == "#") continue;
            @(negedge tck);
            tms = (line[0] == "1");
            tdi = (line[1] == "1");
            @(posedge tck);
            if (line[2] == "0" || line[2] == "1") begin
                strobes++;
                got = tdo;
                if (tdo_en !== 1'b1 || got !== (line[2] == "1")) begin
                    fails++;
                    $fdisplay(fl, "%0d %s %b", cyc, line.substr(2, 2), got);
                end
            end
            cyc++;
        end
        $fclose(fd);
        $fdisplay(fl, "# end cycles=%0d strobes=%0d fails=%0d", cyc, strobes, fails);
        $fclose(fl);
        $display("ATE %s: %0d cycles, %0d strobes, %0d failing -> %s",
                 die, cyc, strobes, fails, fails ? "FAIL" : "PASS");
        $finish;
    end

endmodule
