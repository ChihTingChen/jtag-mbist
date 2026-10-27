// jtag_tasks.svh
//
// Tester-side JTAG driver. `include inside a TB module that has
// tck, tms, tdi (driven by TB) and tdo, tdo_en (from DUT).
//
// Timing: TMS/TDI change on falling TCK, TDO is strobed on rising TCK.
// The DUT updates TDO on falling TCK, so it is settled by then.
//
// Every scan task starts and ends in Run-Test/Idle.

localparam [3:0] IR_IDCODE = 4'b0001;
localparam [3:0] IR_MBIST  = 4'b1000;
localparam [3:0] IR_BYPASS = 4'b1111;

// idle cycles after an MBIST TDR write, see mbist_write
localparam int   WR_IDLE   = 4;

// TB copy of what we last wrote into TDR[2:0]. Needed because every DR
// scan ends with Update-DR, so a plain "read" also writes the control bits.
logic [2:0] mbist_ctl_shadow = 3'b000;

// last instruction we loaded, so back-to-back TDR accesses can skip the
// IR scan like a real test program would
logic [3:0] cur_ir = IR_IDCODE;

// one TCK: drive tms/tdi, strobe tdo
task automatic jtag_clk(input logic tms_v, input logic tdi_v, output logic tdo_v);
    @(negedge tck);
    tms = tms_v;
    tdi = tdi_v;
    @(posedge tck);
    tdo_v = tdo;
    #1;     // let the posedge NBAs settle so callers can peek at DUT state
endtask

task automatic jtag_tms(input logic tms_v);
    logic dummy;
    jtag_clk(tms_v, 1'b0, dummy);
endtask

task automatic jtag_idle(input int n);
    repeat (n) jtag_tms(1'b0);
endtask

task automatic jtag_reset();
    repeat (5) jtag_tms(1'b1);
    jtag_tms(1'b0);
    cur_ir = IR_IDCODE;
    mbist_ctl_shadow = 3'b000;
endtask

// shift_ir that also returns what came out of the IR (the capture value)
task automatic shift_ir_cap(input logic [3:0] instr, output logic [3:0] cap);
    logic b;
    jtag_tms(1'b1);                 // Select-DR
    jtag_tms(1'b1);                 // Select-IR
    jtag_tms(1'b0);                 // Capture-IR
    jtag_tms(1'b0);                 // Shift-IR
    for (int i = 0; i < 4; i++) begin
        jtag_clk(i == 3, instr[i], b);
        if (tdo_en !== 1'b1)
            $fatal(1, "shift_ir: tdo_en low during Shift-IR");
        cap[i] = b;
    end
    jtag_tms(1'b1);                 // Update-IR
    jtag_tms(1'b0);                 // Run-Test/Idle
    cur_ir = instr;
endtask

task automatic shift_ir(input logic [3:0] instr);
    logic [3:0] cap;
    shift_ir_cap(instr, cap);
endtask

task automatic shift_dr(input logic [63:0] din, input int len, output logic [63:0] dout);
    logic b;
    dout = '0;
    jtag_tms(1'b1);                 // Select-DR
    jtag_tms(1'b0);                 // Capture-DR
    jtag_tms(1'b0);                 // Shift-DR
    for (int i = 0; i < len; i++) begin
        jtag_clk(i == len - 1, din[i], b);
        if (tdo_en !== 1'b1)
            $fatal(1, "shift_dr: tdo_en low during Shift-DR");
        dout[i] = b;
    end
    jtag_tms(1'b1);                 // Update-DR
    jtag_tms(1'b0);                 // Run-Test/Idle
endtask

// ---- MBIST TDR helpers ----------------------------------------------

task automatic mbist_write(input logic start, input logic [1:0] algo_sel);
    logic [63:0] dout;
    mbist_ctl_shadow = {algo_sel, start};
    if (cur_ir != IR_MBIST) shift_ir(IR_MBIST);
    shift_dr({61'd0, algo_sel, start}, 16, dout);
    // done/fail come back through 2 TCK flops. Give the sys side time to
    // clear the old done before anyone captures the status again,
    // otherwise a poll right after this (no IR scan in between) sees
    // done=1 left over from the previous run.
    jtag_idle(WR_IDLE);
endtask

task automatic mbist_read_raw(output logic [15:0] tdr);
    logic [63:0] dout;
    if (cur_ir != IR_MBIST) shift_ir(IR_MBIST);
    shift_dr({61'd0, mbist_ctl_shadow}, 16, dout);
    tdr = dout[15:0];
endtask

task automatic mbist_read(output logic done, output logic fail, output logic [9:0] fail_addr);
    logic [15:0] tdr;
    mbist_read_raw(tdr);
    done      = tdr[3];
    fail      = tdr[4];
    fail_addr = tdr[14:5];
endtask
