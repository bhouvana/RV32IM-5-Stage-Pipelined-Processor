module reg2(
    input clk,
    input rst,
    input branch,
    input memRead,
    input memtoReg,
    input memWrite,
    input ALUSrc,
    input regWrite,
    input [4:0] writeReg,
    input [6:0] funct7,
    input [2:0] funct3,
    input [1:0] ALUOp,
    input [31:0] pc_o_regfd,
    input [31:0] readData1,
    input [31:0] readData2,
    input [31:0] imm,
    input [31:0] inst_regfd,
    input flush,
    input branch_taken, 
    input [4:0] readReg1,
    input [4:0] readReg2,
    input jump,
    input jalr,
    input lui,
    input auipc,

    output reg branch_regde,
    output reg memRead_regde,
    output reg memtoReg_regde,
    output reg memWrite_regde,
    output reg ALUSrc_regde,
    output reg regWrite_regde,
    output reg [1:0] ALUOp_regde,
    output reg [4:0] write_to_Reg_regde,
    output reg [31:0] pc_o_regde,
    output reg [31:0] readData1_regde,
    output reg [31:0] readData2_regde,
    output reg [31:0] imm_regde,
    output reg [31:0] inst_regde,
    output reg [6:0] funct7_regde,
    output reg [2:0] funct3_regde,
    output reg [4:0] readReg1_regde,
    output reg [4:0] readReg2_regde,
    output reg jump_regde,
    output reg jalr_regde,
    output reg lui_regde,
    output reg auipc_regde

);

always@(posedge clk)
begin
    if(~rst)
    begin
        branch_regde <= 0;
        memRead_regde <= 0;
        memtoReg_regde <= 0;
        memWrite_regde <= 0;
        ALUSrc_regde <=0 ;
        regWrite_regde <= 0;
        ALUOp_regde <= 0;
        write_to_Reg_regde <= 0 ;
        pc_o_regde <= 0;
        readData1_regde <= 0;
        readData2_regde <= 0;
        imm_regde <= 0;
        inst_regde <= 0 ;
        funct7_regde <= 0;
        funct3_regde <= 0;
        readData1_regde <= 0;
        readData2_regde <= 0;
        jump_regde <= 0;
        jalr_regde <= 0;
        lui_regde <= 0;
        auipc_regde <= 0;

    end

    else if(branch_taken)
    begin
    branch_regde       <= 0;
    memRead_regde      <= 0;
    memtoReg_regde     <= 0;
    memWrite_regde     <= 0;
    ALUSrc_regde       <= 0;
    regWrite_regde     <= 0;
    ALUOp_regde        <= 0;
    write_to_Reg_regde <= 5'b0;
    readData1_regde    <= 0;
    readData2_regde    <= 0;
    imm_regde          <= 0;
    pc_o_regde         <= 0;
    inst_regde         <= 32'h00000013;
    funct7_regde       <= 0;
    funct3_regde       <= 0;
    readReg1_regde     <= 0;
    readReg2_regde     <= 0;
    jump_regde         <= 0;
    jalr_regde         <= 0;
    lui_regde          <= 0;
    auipc_regde        <= 0;
end

    else if(flush)
    begin 
        branch_regde <= 0;
        memRead_regde <= 0;
        memtoReg_regde <= 0;
        memWrite_regde <= 0;
        ALUSrc_regde <=0 ;
        regWrite_regde <= 0;
        ALUOp_regde <= 0;
        write_to_Reg_regde <= 5'b00000 ;
        pc_o_regde <= pc_o_regfd;
        readData1_regde <= readData1;
        readData2_regde <= readData2;
        imm_regde <= imm;
        inst_regde <= inst_regfd ;
        funct7_regde <= funct7;
        funct3_regde <= funct3;
        readReg1_regde <= readReg1;
        readReg2_regde <= readReg2;
        jump_regde <= 0;
        jalr_regde <= 0;
        lui_regde <= 0;
        auipc_regde <= 0;
    end

    else
    begin
        branch_regde <= branch;
        memRead_regde <= memRead;
        memtoReg_regde <= memtoReg;
        memWrite_regde <= memWrite;
        ALUSrc_regde <= ALUSrc ;
        regWrite_regde <= regWrite;
        ALUOp_regde <= ALUOp;
        write_to_Reg_regde <= writeReg ;
        pc_o_regde <= pc_o_regfd;
        readData1_regde <= readData1;
        readData2_regde <= readData2;
        imm_regde <= imm;
        inst_regde <= inst_regfd ;
        funct7_regde <= funct7;
        funct3_regde <= funct3;
        readReg1_regde <= readReg1;
        readReg2_regde <= readReg2;
        jump_regde <= jump;
        jalr_regde <= jalr;
        lui_regde <= lui;
        auipc_regde <= auipc;

    end
end

endmodule









 
