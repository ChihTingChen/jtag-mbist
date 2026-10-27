// sync_2ff.v
//
// Plain two-flop synchronizer. Only for single-bit signals, or for
// multi-bit buses that are guaranteed stable while being sampled
// (each bit may resolve one cycle apart otherwise).
//
// Ports
//   clk, rst_n : destination domain clock / async reset
//   d          : signal from the source domain
//   q          : synchronized output
//
// Clock domain: destination (clk).

module sync_2ff #(
    parameter WIDTH = 1
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [WIDTH-1:0] d,
    output reg  [WIDTH-1:0] q
);

    reg [WIDTH-1:0] meta;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta <= {WIDTH{1'b0}};
            q    <= {WIDTH{1'b0}};
        end else begin
            meta <= d;
            q    <= meta;
        end
    end

endmodule
