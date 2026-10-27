// jtag_regs.v
//
// Instruction register, the two mandatory-ish DRs (BYPASS, IDCODE) and
// the TDO mux. User TDRs live outside; they get a select line from here
// and hand back their serial output.
//
//   IR = 0001  IDCODE      -> 32b IDCODE
//   IR = 1000  MBIST_CTRL  -> 16b MBIST TDR (external, mbist_tdo)
//   IR = 1111  BYPASS      -> 1b bypass
//   anything else          -> treated as BYPASS
//
// Ports
//   tck, trst_n, tdi       : JTAG pins
//   test_logic_reset ...   : state flags from tap_ctrl
//   mbist_tdo              : serial out (LSB) of the MBIST TDR
//   sel_mbist              : MBIST_CTRL is the active instruction
//   ir_latched             : active instruction
//   tdo, tdo_en            : TDO pin and its enable (only in Shift-IR/DR)
//
// Clock domain: TCK. Capture/shift on posedge, Update-IR and TDO on negedge.

module jtag_regs #(
    parameter [31:0] IDCODE_VAL = 32'h1BEE_F001
) (
    input  wire       tck,
    input  wire       trst_n,
    input  wire       tdi,

    input  wire       test_logic_reset,
    input  wire       capture_dr,
    input  wire       shift_dr,
    input  wire       capture_ir,
    input  wire       shift_ir,
    input  wire       update_ir,

    input  wire       mbist_tdo,
    output wire       sel_mbist,
    output reg  [3:0] ir_latched,

    output reg        tdo,
    output reg        tdo_en
);

    localparam [3:0] IR_IDCODE = 4'b0001,
                     IR_MBIST  = 4'b1000,
                     IR_BYPASS = 4'b1111;

    reg  [3:0]  ir_shift;
    reg         bypass_reg;
    reg  [31:0] idcode_reg;

    wire sel_idcode = (ir_latched == IR_IDCODE);
    assign sel_mbist = (ir_latched == IR_MBIST);
    wire sel_bypass = !sel_idcode && !sel_mbist;   // BYPASS + undefined codes

    // IR shift stage. Capture value 0001 -- spec requires the two LSBs = 01.
    always @(posedge tck or negedge trst_n) begin
        if (!trst_n)
            ir_shift <= IR_IDCODE;
        else if (capture_ir)
            ir_shift <= 4'b0001;
        else if (shift_ir)
            ir_shift <= {tdi, ir_shift[3:1]};
    end

    // IR update stage, falling edge in Update-IR as in 1149.1
    always @(negedge tck or negedge trst_n) begin
        if (!trst_n)
            ir_latched <= IR_IDCODE;
        else if (test_logic_reset)
            ir_latched <= IR_IDCODE;
        else if (update_ir)
            ir_latched <= ir_shift;
    end

    always @(posedge tck or negedge trst_n) begin
        if (!trst_n)
            bypass_reg <= 1'b0;
        else if (sel_bypass) begin
            if (capture_dr)
                bypass_reg <= 1'b0;
            else if (shift_dr)
                bypass_reg <= tdi;
        end
    end

    always @(posedge tck or negedge trst_n) begin
        if (!trst_n)
            idcode_reg <= IDCODE_VAL;
        else if (sel_idcode) begin
            if (capture_dr)
                idcode_reg <= IDCODE_VAL;
            else if (shift_dr)
                idcode_reg <= {tdi, idcode_reg[31:1]};
        end
    end

    reg dr_so;
    always @(*) begin
        if (sel_idcode)
            dr_so = idcode_reg[0];
        else if (sel_mbist)
            dr_so = mbist_tdo;
        else
            dr_so = bypass_reg;
    end

    // TDO changes on the falling edge so it is stable when the tester
    // strobes it on the next rising edge.
    always @(negedge tck or negedge trst_n) begin
        if (!trst_n) begin
            tdo    <= 1'b0;
            tdo_en <= 1'b0;
        end else begin
            tdo    <= shift_ir ? ir_shift[0] : (shift_dr ? dr_so : 1'b0);
            tdo_en <= shift_ir | shift_dr;
        end
    end

endmodule
