// jtag_mbist_top.v
//
// JTAG-controlled memory BIST. The tester only touches the 4(+1) JTAG
// pins: write start/algo_sel through the MBIST TDR, the March C- runs
// at speed on sys_clk, then status is read back over JTAG.
//
// The SRAM sits outside this module (TB model for now, macro or flop
// array later for PnR).
//
// Ports
//   tck, tms, tdi, tdo, tdo_en, trst_n : JTAG
//   sys_clk, sys_rst_n                 : system clock, raw async reset
//   mem_*                              : SRAM interface, sys_clk domain
//
// Clock domains: TCK (TAP, IR, TDRs) and sys_clk (MBIST). No phase or
// frequency relationship between them is assumed.
//
// ---------------------------------------------------------------------
// CDC
//
//   start_tck     TCK->sys  2FF, rising edge detected on the sys side
//   algo_sel_tck  TCK->sys  2FF, sampled one sys cycle after the start
//                           edge. Written together with start, so in
//                           silicon the bits could land a cycle apart --
//                           the extra cycle covers that. Safest is to
//                           write algo_sel first and start in a 2nd scan.
//   done, fail    sys->TCK  2FF each. mbist_ctrl raises done one cycle
//                           after fail is final, so a TCK edge that sees
//                           done=1 can't see a stale fail.
//   fail_addr     sys->TCK  no synchronizer.
//
// Why fail_addr can skip the synchronizer: it is a 10-bit bus, and
// putting a 2FF on each bit doesn't help -- bits can resolve on
// different TCK edges and we'd capture a mix of old and new address.
// Instead we only use it when it is guaranteed not to move. fail_addr
// can only change while the BIST is running (and gets cleared on start).
// Once done=1 it is frozen until the next start. done itself goes through
// a 2FF, so by the time done_tck=1 fail_addr has been stable for at least
// two TCK edges -- no setup/hold problem when the TDR captures it. While
// done_tck=0 the TDR captures 0 instead of the raw bus. done_tck acts as
// the qualifier (same idea as a req/ack handshake where the data is held
// until ack).
//
// Corner case: right after a new start, done is cleared on the sys side
// but done_tck still shows 1 for up to two TCKs while fail_addr is being
// cleared. Software must not poll in that window -- the JTAG tasks idle a
// few TCKs after writing start (same as RUNTEST in an SVF).
//
// For STA this means: set_max_delay / false path on fail_addr_sys ->
// TDR capture flops, and the usual async constraints on the 2FFs.
// ---------------------------------------------------------------------

module jtag_mbist_top #(
    parameter        ADDR_W     = 10,     // TDR has room for 10 bits max
    parameter        DATA_W     = 8,
    parameter [31:0] IDCODE_VAL = 32'h1BEE_F001
) (
    input  wire              tck,
    input  wire              tms,
    input  wire              tdi,
    input  wire              trst_n,
    output wire              tdo,
    output wire              tdo_en,

    input  wire              sys_clk,
    input  wire              sys_rst_n,

    output wire [ADDR_W-1:0] mem_addr,
    output wire [DATA_W-1:0] mem_wdata,
    output wire              mem_we,
    output wire              mem_re,
    input  wire [DATA_W-1:0] mem_rdata
);

    // ---------------- TCK domain ----------------
    wire [3:0] tap_state;
    wire tlr, rti, cap_dr, sh_dr, upd_dr, cap_ir, sh_ir, upd_ir;
    wire [3:0] ir_latched;
    wire sel_mbist;
    wire mbist_so;

    wire       start_tck;
    wire [1:0] algo_sel_tck;
    wire       done_tck, fail_tck;

    // sys side results
    wire              done_sys, fail_sys;
    wire [ADDR_W-1:0] fail_addr_sys;

    tap_ctrl u_tap (
        .tck              (tck),
        .tms              (tms),
        .trst_n           (trst_n),
        .state            (tap_state),
        .test_logic_reset (tlr),
        .run_test_idle    (rti),
        .capture_dr       (cap_dr),
        .shift_dr         (sh_dr),
        .update_dr        (upd_dr),
        .capture_ir       (cap_ir),
        .shift_ir         (sh_ir),
        .update_ir        (upd_ir)
    );

    jtag_regs #(.IDCODE_VAL(IDCODE_VAL)) u_regs (
        .tck              (tck),
        .trst_n           (trst_n),
        .tdi              (tdi),
        .test_logic_reset (tlr),
        .capture_dr       (cap_dr),
        .shift_dr         (sh_dr),
        .capture_ir       (cap_ir),
        .shift_ir         (sh_ir),
        .update_ir        (upd_ir),
        .mbist_tdo        (mbist_so),
        .sel_mbist        (sel_mbist),
        .ir_latched       (ir_latched),
        .tdo              (tdo),
        .tdo_en           (tdo_en)
    );

    wire [9:0] fail_addr_10 = fail_addr_sys;   // zero-extend if ADDR_W < 10

    mbist_tdr #(.FA_W(10)) u_tdr (
        .tck              (tck),
        .trst_n           (trst_n),
        .tdi              (tdi),
        .sel              (sel_mbist),
        .test_logic_reset (tlr),
        .capture_dr       (cap_dr),
        .shift_dr         (sh_dr),
        .update_dr        (upd_dr),
        .done_tck         (done_tck),
        .fail_tck         (fail_tck),
        .fail_addr_sys    (fail_addr_10),
        .so               (mbist_so),
        .start_tck        (start_tck),
        .algo_sel_tck     (algo_sel_tck)
    );

    sync_2ff #(.WIDTH(1)) u_sync_done (
        .clk (tck), .rst_n (trst_n), .d (done_sys), .q (done_tck)
    );

    sync_2ff #(.WIDTH(1)) u_sync_fail (
        .clk (tck), .rst_n (trst_n), .d (fail_sys), .q (fail_tck)
    );

    // ---------------- sys_clk domain ----------------
    wire       rst_n_sys;
    wire       start_sync;
    wire [1:0] algo_sel_sync;

    rst_sync u_rst_sync (
        .clk       (sys_clk),
        .rst_n_in  (sys_rst_n),
        .rst_n_out (rst_n_sys)
    );

    sync_2ff #(.WIDTH(1)) u_sync_start (
        .clk (sys_clk), .rst_n (rst_n_sys), .d (start_tck), .q (start_sync)
    );

    // multi-bit, but only sampled when start rises (stable by then)
    sync_2ff #(.WIDTH(2)) u_sync_algo (
        .clk (sys_clk), .rst_n (rst_n_sys), .d (algo_sel_tck), .q (algo_sel_sync)
    );

    mbist_ctrl #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) u_mbist (
        .sys_clk       (sys_clk),
        .sys_rst_n     (rst_n_sys),
        .start_sync    (start_sync),
        .algo_sel_sync (algo_sel_sync),
        .mem_addr      (mem_addr),
        .mem_wdata     (mem_wdata),
        .mem_we        (mem_we),
        .mem_re        (mem_re),
        .mem_rdata     (mem_rdata),
        .done          (done_sys),
        .fail          (fail_sys),
        .fail_addr     (fail_addr_sys)
    );

endmodule
