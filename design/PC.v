`default_nettype none

module PC #(
    parameter XLEN = 32   // docs/adr/0015-xlen-and-regcount-parameterization.md
)(
    input clk,
    input rst,
    input stall,
    input [XLEN-1:0] pc_i,
    output reg [XLEN-1:0] pc_o
);

always @(posedge clk ) begin
	if (~rst)
		pc_o <={XLEN{1'b0}};
	else
        if(stall)
            pc_o <= pc_o;
        else
		pc_o <= pc_i;
end
endmodule

`default_nettype wire
