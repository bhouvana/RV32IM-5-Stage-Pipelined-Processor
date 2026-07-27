`default_nettype none

module Mux4to1 #(
    parameter size = 32
) 
(
    input [1:0] sel,
    input signed [size-1:0] s0, //read from rs1
    input signed [size-1:0] s1, //read from ALU after ex reg buffer
    input signed [size-1:0] s2, //read from mem
    //input signed [size-1:0] s3,
    output signed [size-1:0] out
);
    
assign out = (sel == 2'b00) ? s0 : ((sel == 2'b01) ? s1 : ((sel == 2'b10) ? s2 : s0));   // default

//assign out = (sel== 2'b11) ? s3 : s0;
    
endmodule

`default_nettype wire
