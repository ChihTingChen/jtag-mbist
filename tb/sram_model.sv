// sram_model.sv
//
// Behavioral single-port SRAM for simulation only.
//   write: we=1, data written on rising clk
//   read : re=1, rdata valid after the next rising clk (1-cycle latency)
// Contents start random so the BIST cannot depend on power-up values.
//
// One fault at a time, injected from the TB by hierarchical call:
//   inject_stuck_at(addr, bit, val)           SAF: bit always reads val
//   inject_transition(addr, bit)              TF <up/0>: 0->1 write fails
//   inject_transition_dn(addr, bit)           TF <dn/1>: 1->0 write fails
//   inject_coupling(aggr, victim, bit)        CFid <up;1>, same bit position
//   inject_cf(aggr, abit, victim, vbit, rise, inv, val)
//                                             general CF: aggressor bit
//                                             rising (rise=1) or falling,
//                                             victim forced to val, or
//                                             inverted if inv=1
//   clear_faults()
//
// Clock domain: clk (sys_clk).

module sram_model #(
    parameter ADDR_W = 10,
    parameter DATA_W = 8
) (
    input  logic              clk,
    input  logic [ADDR_W-1:0] addr,
    input  logic [DATA_W-1:0] wdata,
    input  logic              we,
    input  logic              re,
    output logic [DATA_W-1:0] rdata
);

    localparam int N = 1 << ADDR_W;

    localparam int F_NONE  = 0;
    localparam int F_SA    = 1;
    localparam int F_TF_UP = 2;
    localparam int F_TF_DN = 3;
    localparam int F_CF    = 4;

    logic [DATA_W-1:0] mem [0:N-1];

    int f_type = F_NONE;
    int f_addr, f_bit;              // SAF / TF cell, CF victim
    int f_aaddr, f_abit;            // CF aggressor
    bit f_val, f_rise, f_inv;

    initial begin
        for (int i = 0; i < N; i++)
            mem[i] = $urandom;
        rdata = $urandom;
    end

    task automatic clear_faults();
        f_type = F_NONE;
    endtask

    task automatic inject_stuck_at(input int a, input int b, input bit v);
        f_type = F_SA;
        f_addr = a;
        f_bit  = b;
        f_val  = v;
        mem[a][b] = v;
    endtask

    task automatic inject_transition(input int a, input int b);
        f_type = F_TF_UP;
        f_addr = a;
        f_bit  = b;
    endtask

    task automatic inject_transition_dn(input int a, input int b);
        f_type = F_TF_DN;
        f_addr = a;
        f_bit  = b;
    endtask

    task automatic inject_cf(input int aggr, input int abit, input int victim, input int vbit,
                             input bit rise, input bit inv, input bit v);
        f_type  = F_CF;
        f_aaddr = aggr;
        f_abit  = abit;
        f_addr  = victim;
        f_bit   = vbit;
        f_rise  = rise;
        f_inv   = inv;
        f_val   = v;
    endtask

    task automatic inject_coupling(input int aggr, input int victim, input int b);
        inject_cf(aggr, b, victim, b, 1'b1, 1'b0, 1'b1);
    endtask

    always @(posedge clk) begin
        if (we) begin
            logic [DATA_W-1:0] old, nw;
            old = mem[addr];
            nw  = wdata;
            if (addr == f_addr) begin
                case (f_type)
                    F_SA:    nw[f_bit] = f_val;
                    F_TF_UP: if (!old[f_bit] &&  nw[f_bit]) nw[f_bit] = 1'b0;
                    F_TF_DN: if ( old[f_bit] && !nw[f_bit]) nw[f_bit] = 1'b1;
                    default: ;
                endcase
            end
            mem[addr] = nw;

            // coupling: aggressor transition disturbs the victim after the write
            if (f_type == F_CF && addr == f_aaddr &&
                old[f_abit] != nw[f_abit] && nw[f_abit] == f_rise) begin
                if (f_inv)
                    mem[f_addr][f_bit] = ~mem[f_addr][f_bit];
                else
                    mem[f_addr][f_bit] = f_val;
            end
        end

        if (re) begin
            logic [DATA_W-1:0] q;
            q = mem[addr];
            if (f_type == F_SA && addr == f_addr)
                q[f_bit] = f_val;
            rdata <= q;
        end
    end

endmodule
