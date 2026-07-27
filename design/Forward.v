module Forward (

    input [4:0] readReg1_regde,
    input [4:0] readReg2_regde,
    input [4:0] write_to_Reg_regem,
    input [4:0] write_to_Reg_regwb,
    input regWrite_regwb,
    input regWrite_regem,
    output reg [1:0] forwardA,
    output reg [1:0] forwardB
    //output flush,
    //output stall
);
//assign flush = ( regWrite_regde && ((write_to_Reg_regde ==readReg1_fd) || (write_to_Reg_regde == readReg2_fd))) ? 1'b1 : 1'b0;
//assign stall = flush;
always@(*)
begin
if( regWrite_regem &&( write_to_Reg_regem !=0) && (write_to_Reg_regem == readReg1_regde))
    forwardA =2'b10;  //( when the diffrence between PC is 8)
else if( regWrite_regwb &&( write_to_Reg_regwb !=0) && (write_to_Reg_regwb == readReg1_regde))
    forwardA =2'b01;  //( when the diffrence between PC is 4)
else
    forwardA =2'b00;  //everything is ok

if( regWrite_regem &&( write_to_Reg_regem !=0) && (write_to_Reg_regem == readReg2_regde))
    forwardB =2'b10;
else if( regWrite_regwb &&( write_to_Reg_regwb !=0) && (write_to_Reg_regwb == readReg2_regde))
    forwardB =2'b01;
else
    forwardB =2'b00; // same thing as above but instead of readReg1 its readReg2

end
endmodule
