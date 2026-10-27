// tap_ctrl.v
//
// IEEE 1149.1 TAP controller (16-state FSM).
// State moves on rising TCK according to TMS. trst_n forces
// Test-Logic-Reset asynchronously. Holding TMS=1 for 5 TCKs always
// ends in Test-Logic-Reset no matter where we start.
//
// Ports
//   tck, tms, trst_n   : JTAG pins
//   state              : current state (encoding follows the 1149.1 example)
//   test_logic_reset .. update_ir : decoded "currently in state X" flags.
//                        The registers act on the TCK edge that leaves
//                        the state (capture/shift on posedge, update on negedge).
//
// Clock domain: TCK only.

module tap_ctrl (
    input  wire       tck,
    input  wire       tms,
    input  wire       trst_n,
    output reg  [3:0] state,
    output wire       test_logic_reset,
    output wire       run_test_idle,
    output wire       capture_dr,
    output wire       shift_dr,
    output wire       update_dr,
    output wire       capture_ir,
    output wire       shift_ir,
    output wire       update_ir
);

    localparam [3:0] TLR     = 4'hF,
                     RTI     = 4'hC,
                     SEL_DR  = 4'h7,
                     CAP_DR  = 4'h6,
                     SH_DR   = 4'h2,
                     EX1_DR  = 4'h1,
                     PAU_DR  = 4'h3,
                     EX2_DR  = 4'h0,
                     UPD_DR  = 4'h5,
                     SEL_IR  = 4'h4,
                     CAP_IR  = 4'hE,
                     SH_IR   = 4'hA,
                     EX1_IR  = 4'h9,
                     PAU_IR  = 4'hB,
                     EX2_IR  = 4'h8,
                     UPD_IR  = 4'hD;

    reg [3:0] nxt;

    always @(*) begin
        case (state)
            TLR:    nxt = tms ? TLR    : RTI;
            RTI:    nxt = tms ? SEL_DR : RTI;
            SEL_DR: nxt = tms ? SEL_IR : CAP_DR;
            CAP_DR: nxt = tms ? EX1_DR : SH_DR;
            SH_DR:  nxt = tms ? EX1_DR : SH_DR;
            EX1_DR: nxt = tms ? UPD_DR : PAU_DR;
            PAU_DR: nxt = tms ? EX2_DR : PAU_DR;
            EX2_DR: nxt = tms ? UPD_DR : SH_DR;
            UPD_DR: nxt = tms ? SEL_DR : RTI;
            SEL_IR: nxt = tms ? TLR    : CAP_IR;
            CAP_IR: nxt = tms ? EX1_IR : SH_IR;
            SH_IR:  nxt = tms ? EX1_IR : SH_IR;
            EX1_IR: nxt = tms ? UPD_IR : PAU_IR;
            PAU_IR: nxt = tms ? EX2_IR : PAU_IR;
            EX2_IR: nxt = tms ? UPD_IR : SH_IR;
            UPD_IR: nxt = tms ? SEL_DR : RTI;
            default: nxt = TLR;
        endcase
    end

    always @(posedge tck or negedge trst_n) begin
        if (!trst_n)
            state <= TLR;
        else
            state <= nxt;
    end

    assign test_logic_reset = (state == TLR);
    assign run_test_idle    = (state == RTI);
    assign capture_dr       = (state == CAP_DR);
    assign shift_dr         = (state == SH_DR);
    assign update_dr        = (state == UPD_DR);
    assign capture_ir       = (state == CAP_IR);
    assign shift_ir         = (state == SH_IR);
    assign update_ir        = (state == UPD_IR);

endmodule
