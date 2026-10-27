// mbist_tdr.v
//
// 16-bit MBIST test data register, active when IR = MBIST_CTRL.
//
//   [0]     start      W   level, MBIST starts on 0->1 (sys side)
//   [2:1]   algo_sel   W   00 solid, 01 checkerboard, 1x reserved
//   [3]     done       R
//   [4]     fail       R
//   [14:5]  fail_addr  R   first failing address, 0 while done=0
//   [15]    reserved       reads 0
//
// Capture-DR loads the status plus the control bits currently in effect.
// Shift-DR shifts TDI in at the MSB, LSB goes out to TDO. Update-DR
// (falling TCK) only touches the control bits [2:0].
//
// Ports
//   tck, trst_n, tdi      : JTAG
//   sel                   : IR == MBIST_CTRL
//   test_logic_reset, capture_dr, shift_dr, update_dr : TAP state flags
//   done_tck, fail_tck    : status already synchronized to TCK
//   fail_addr_sys         : raw sys-domain fail_addr, only looked at while
//                           done_tck=1 (quasi-static then, see top level)
//   so                    : serial out to the TDO mux
//   start_tck, algo_sel_tck : control outputs, go to sys domain via sync
//
// Clock domain: TCK.

module mbist_tdr #(
    parameter FA_W = 10
) (
    input  wire            tck,
    input  wire            trst_n,
    input  wire            tdi,
    input  wire            sel,
    input  wire            test_logic_reset,
    input  wire            capture_dr,
    input  wire            shift_dr,
    input  wire            update_dr,

    input  wire            done_tck,
    input  wire            fail_tck,
    input  wire [FA_W-1:0] fail_addr_sys,

    output wire            so,
    output reg             start_tck,
    output reg  [1:0]      algo_sel_tck
);

    reg [15:0] sr;

    wire [FA_W-1:0] fa_cap = done_tck ? fail_addr_sys : {FA_W{1'b0}};

    always @(posedge tck or negedge trst_n) begin
        if (!trst_n)
            sr <= 16'd0;
        else if (sel && capture_dr)
            sr <= {1'b0, fa_cap, fail_tck, done_tck, algo_sel_tck, start_tck};
        else if (sel && shift_dr)
            sr <= {tdi, sr[15:1]};
    end

    always @(negedge tck or negedge trst_n) begin
        if (!trst_n) begin
            start_tck    <= 1'b0;
            algo_sel_tck <= 2'b00;
        end else if (test_logic_reset) begin
            start_tck    <= 1'b0;
            algo_sel_tck <= 2'b00;
        end else if (sel && update_dr) begin
            start_tck    <= sr[0];
            algo_sel_tck <= sr[2:1];
        end
    end

    assign so = sr[0];

endmodule
