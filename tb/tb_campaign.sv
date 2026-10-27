// tb_campaign.sv -- fault simulation campaign (driven by scripts/fault_campaign.py)
//
// Reads a fault list, runs one March C- per fault on mbist_ctrl + sram_model
// (no JTAG, to keep it fast) and writes one result line per fault.
//
//   +FAULTS=<file>   input, one fault per line:
//                    id type algo aggr abit victim vbit rise inv val
//                    type 1=SA 2=TF-up 3=TF-down 4=CF
//   +RESULTS=<file>  output: id detected fail_addr
`timescale 1ns/1ps

module tb_campaign;

`ifdef ADDR_W_OVR
    localparam int ADDR_W = `ADDR_W_OVR;
`else
    localparam int ADDR_W = 8;
`endif
    localparam int DATA_W = 8;
    localparam int N      = 1 << ADDR_W;

    logic sys_clk = 1'b0, sys_rst_n = 1'b0;
    logic start_sync = 1'b0;
    logic [1:0] algo_sel_sync = 2'b00;

    always #5 sys_clk = ~sys_clk;

    wire [ADDR_W-1:0] mem_addr, fail_addr;
    wire [DATA_W-1:0] mem_wdata, mem_rdata;
    wire mem_we, mem_re, done, fail;

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

    initial begin
        string fin, fout, line;
        int fd_in, fd_out, n;
        int id, typ, algo, aggr, abit, victim, vbit, rise, inv, val;
        int cnt = 0, cyc;

        if (!$value$plusargs("FAULTS=%s", fin))   fin  = "out/faults.txt";
        if (!$value$plusargs("RESULTS=%s", fout)) fout = "out/results.txt";
        fd_in  = $fopen(fin, "r");
        fd_out = $fopen(fout, "w");
        if (fd_in == 0)  $fatal(1, "cannot open %s", fin);
        if (fd_out == 0) $fatal(1, "cannot open %s", fout);
        $fdisplay(fd_out, "# words %0d", N);

        repeat (3) @(posedge sys_clk);
        @(negedge sys_clk) sys_rst_n = 1'b1;

        while ($fgets(line, fd_in)) begin
            if (line.len() == 0 || line[0] == "#") continue;
            n = $sscanf(line, "%d %d %d %d %d %d %d %d %d %d",
                        id, typ, algo, aggr, abit, victim, vbit, rise, inv, val);
            if (n != 10) continue;

            u_sram.clear_faults();
            case (typ)
                1: u_sram.inject_stuck_at(victim, vbit, val);
                2: u_sram.inject_transition(victim, vbit);
                3: u_sram.inject_transition_dn(victim, vbit);
                4: u_sram.inject_cf(aggr, abit, victim, vbit, rise, inv, val);
                default: $fatal(1, "fault %0d: bad type %0d", id, typ);
            endcase

            @(negedge sys_clk);
            algo_sel_sync = algo;
            start_sync    = 1'b1;
            cyc = 0;
            do begin
                @(posedge sys_clk);
                #1;
                if (++cyc > 12*N) $fatal(1, "fault %0d: BIST hung", id);
            end while (!done);
            $fdisplay(fd_out, "%0d %0d %0d", id, fail, fail_addr);
            @(negedge sys_clk) start_sync = 1'b0;
            @(negedge sys_clk);
            cnt++;
        end

        u_sram.clear_faults();
        $fclose(fd_in);
        $fclose(fd_out);
        $display("campaign: %0d faults simulated, results in %s", cnt, fout);
        $finish;
    end

endmodule
