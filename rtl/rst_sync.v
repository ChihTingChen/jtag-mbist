// rst_sync.v
//
// Reset synchronizer: asserts asynchronously, releases synchronously
// two clocks after rst_n_in goes high, so no flop sees the reset edge
// close to its clock edge.
//
// Ports
//   clk       : destination clock
//   rst_n_in  : raw active-low reset (async)
//   rst_n_out : reset for the clk domain
//
// Clock domain: clk.

module rst_sync (
    input  wire clk,
    input  wire rst_n_in,
    output wire rst_n_out
);

    reg r1, r2;

    always @(posedge clk or negedge rst_n_in) begin
        if (!rst_n_in) begin
            r1 <= 1'b0;
            r2 <= 1'b0;
        end else begin
            r1 <= 1'b1;
            r2 <= r1;
        end
    end

    assign rst_n_out = r2;

endmodule
