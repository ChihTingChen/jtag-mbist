// mbist_ctrl.v
//
// March C- memory BIST controller, 10N operations:
//
//   M0 up  (w0)
//   M1 up  (r0,w1)
//   M2 up  (r1,w0)
//   M3 down(r0,w1)
//   M4 down(r1,w0)
//   M5 up  (r0)
//
// One memory op per cycle. The SRAM has 1-cycle read latency, so a read
// issued in cycle t is compared in cycle t+1 while the next op is already
// on the bus (exp_q / addr_q hold what the read was supposed to return).
// First mismatch sets fail and freezes fail_addr; the run always goes to
// the end. done stays high until the next start.
//
// algo_sel 00 : "0" = all zeros, "1" = all ones
//          01 : "0" = 0x55..,    "1" = 0xAA..  (checkerboard within a word)
//          1x : reserved, runs as 00
//
// Ports
//   sys_clk, sys_rst_n : system clock / reset (reset already synchronized)
//   start_sync         : start level, synchronized; a 0->1 edge starts a run
//   algo_sel_sync      : synchronized algo select, sampled when a run starts
//   mem_*              : single-port SRAM interface
//   done, fail, fail_addr : result, all sys_clk domain
//
// Clock domain: sys_clk only.

module mbist_ctrl #(
    parameter ADDR_W = 10,
    parameter DATA_W = 8
) (
    input  wire              sys_clk,
    input  wire              sys_rst_n,
    input  wire              start_sync,
    input  wire [1:0]        algo_sel_sync,

    output reg  [ADDR_W-1:0] mem_addr,
    output reg  [DATA_W-1:0] mem_wdata,
    output reg               mem_we,
    output reg               mem_re,
    input  wire [DATA_W-1:0] mem_rdata,

    output reg               done,
    output reg               fail,
    output reg  [ADDR_W-1:0] fail_addr
);

    localparam [ADDR_W-1:0] ADDR_MAX = {ADDR_W{1'b1}};
    localparam [DATA_W-1:0] CHKBD    = {DATA_W{2'b01}};    // ...0101

    localparam [1:0] S_IDLE  = 2'd0,
                     S_ARM   = 2'd1,
                     S_RUN   = 2'd2,
                     S_FLUSH = 2'd3;

    reg [1:0]        st;
    reg [2:0]        elem;
    reg              step;
    reg [ADDR_W-1:0] addr;
    reg              start_d;
    reg [DATA_W-1:0] bg0;              // data for "0"; "1" is ~bg0

    // read pipeline
    reg              rd_pend;
    reg [DATA_W-1:0] exp_q;
    reg [ADDR_W-1:0] addr_q;

    wire start_rise = start_sync & ~start_d;

    // decode current (elem, step)
    wire op_read   = (elem != 3'd0) && (step == 1'b0);
    wire last_step = (elem == 3'd0) || (elem == 3'd5) || step;
    wire dir_down  = (elem == 3'd3) || (elem == 3'd4);
    wire rd_one    = (elem == 3'd2) || (elem == 3'd4);    // r1 vs r0
    wire wr_one    = (elem == 3'd1) || (elem == 3'd3);    // w1 vs w0
    wire elem_end  = dir_down ? (addr == {ADDR_W{1'b0}}) : (addr == ADDR_MAX);

    wire [DATA_W-1:0] rd_val = rd_one ? ~bg0 : bg0;
    wire [DATA_W-1:0] wr_val = wr_one ? ~bg0 : bg0;

    // memory port, straight from the FSM registers
    always @(*) begin
        mem_addr  = addr;
        mem_re    = (st == S_RUN) &&  op_read;
        mem_we    = (st == S_RUN) && !op_read;
        mem_wdata = wr_val;
    end

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            start_d <= 1'b0;
        else
            start_d <= start_sync;
    end

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            st   <= S_IDLE;
            elem <= 3'd0;
            step <= 1'b0;
            addr <= {ADDR_W{1'b0}};
            bg0  <= {DATA_W{1'b0}};
        end else begin
            case (st)
                S_IDLE: begin
                    if (start_rise)
                        st <= S_ARM;
                end

                // algo_sel is taken one cycle after the start edge, which
                // gives it an extra cycle to settle (see top-level notes)
                S_ARM: begin
                    bg0  <= (algo_sel_sync == 2'b01) ? CHKBD : {DATA_W{1'b0}};
                    elem <= 3'd0;
                    step <= 1'b0;
                    addr <= {ADDR_W{1'b0}};
                    st   <= S_RUN;
                end

                S_RUN: begin
                    if (!last_step) begin
                        step <= 1'b1;
                    end else begin
                        step <= 1'b0;
                        if (!elem_end) begin
                            addr <= dir_down ? addr - 1'b1 : addr + 1'b1;
                        end else if (elem == 3'd5) begin
                            st <= S_FLUSH;
                        end else begin
                            elem <= elem + 3'd1;
                            // M3/M4 walk down, everything else up
                            addr <= (elem == 3'd2 || elem == 3'd3) ? ADDR_MAX : {ADDR_W{1'b0}};
                        end
                    end
                end

                // wait for the last read to come back
                S_FLUSH: st <= S_IDLE;

                default: st <= S_IDLE;
            endcase
        end
    end

    // compare stage
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rd_pend <= 1'b0;
            exp_q   <= {DATA_W{1'b0}};
            addr_q  <= {ADDR_W{1'b0}};
        end else begin
            rd_pend <= mem_re;
            if (mem_re) begin
                exp_q  <= rd_val;
                addr_q <= addr;
            end
        end
    end

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            done      <= 1'b0;
            fail      <= 1'b0;
            fail_addr <= {ADDR_W{1'b0}};
        end else if (st == S_IDLE && start_rise) begin
            done      <= 1'b0;
            fail      <= 1'b0;
            fail_addr <= {ADDR_W{1'b0}};
        end else begin
            if (rd_pend && (mem_rdata != exp_q) && !fail) begin
                fail      <= 1'b1;
                fail_addr <= addr_q;
            end
            if (st == S_FLUSH)
                done <= 1'b1;
        end
    end

endmodule
