`default_nettype none

module reg4(
    input clk,
    input rst,
    input memtoReg_regem,
    input regWrite_regem,
    input [31:0] readData,
    input [31:0] ALUOut_regem,
    input [4:0] write_to_Reg_regem,
    input jump_regem,
    input [31:0] pc_plus4_regem,
    output reg memtoReg_regwb,
    output reg regWrite_regwb,
    output reg [31:0] readData_regwb,
    output reg [31:0] ALUOut_regwb,
    output reg [4:0] write_to_Reg_regwb,
    output reg jump_regwb,
    output reg [31:0] pc_plus4_regwb
);

always@(posedge clk)
begin
    if(~rst)
    begin
    memtoReg_regwb <= 0;
    regWrite_regwb <= 0;
    readData_regwb <= 0;
    ALUOut_regwb <= 0;
    write_to_Reg_regwb <=0;
    jump_regwb <= 0;
    pc_plus4_regwb <= 0;

    end
    else
    begin
    memtoReg_regwb <= memtoReg_regem;
    regWrite_regwb <= regWrite_regem;
    readData_regwb <= readData;
    ALUOut_regwb <= ALUOut_regem;
    write_to_Reg_regwb <= write_to_Reg_regem;
    jump_regwb <= jump_regem;
    pc_plus4_regwb <= pc_plus4_regem;
    end
end
endmodule

`default_nettype wire
