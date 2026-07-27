module Control (
    input [6:0] opcode,
    //
    input funt7,
    input [2:0] funt3,
    //
    output reg branch,
    output reg memRead,
    output reg memtoReg,
    output reg [1:0] ALUOp,
    output reg memWrite,
    output reg ALUSrc,
    output reg regWrite,
    output reg [2:0] funct3,
    output reg funct7,
    output reg jump   // unconditional control transfer (JAL); target = EX-stage adder, link = PC+4
    );

always@(*)begin

    branch    = 0;
    memRead   = 0;
    memtoReg  = 0;
    ALUOp     = 2'b00;
    memWrite  = 0;
    ALUSrc    = 0;
    regWrite  = 0;
    jump      = 0;


case(opcode)
    7'b0101010: 
    begin// the new instruction that u people asked for
    
        branch =0;
        memRead =0;
        memtoReg =0;
        ALUOp =2'b10;
        memWrite =0;
        ALUSrc =0;
        regWrite =1;
        
    end

    7'b0000011: 
    begin//load inst
    
        branch =0;
        memRead =1;
        memtoReg =1;
        ALUOp =2'b00;
        memWrite =0;
        ALUSrc =1;
        regWrite =1;
        
    end
    7'b0100011://store inst
    begin
        branch =0;
        memRead =0;
        memtoReg =0;
        ALUOp =2'b00;
        memWrite =1;
        ALUSrc =1;
        regWrite =0;
      
    end

    7'b0010011://immediate inst
    begin
        branch =0;
        memRead =0;
        memtoReg =0;
        ALUOp =2'b11;
        memWrite =0;
        ALUSrc =1;
        regWrite =1;
        
    end
    
    7'b0110011://add and sub R type inst
    begin
         branch =0;
        memRead =0;
         memtoReg =0;
        ALUOp =2'b10;
        memWrite =0;
        ALUSrc =0;
        regWrite =1;
        
    end

    7'b1100011://branch inst
    begin
        branch =1;
        memRead =0;
        memtoReg =0;
        ALUOp =2'b01;
        memWrite =0;
        ALUSrc =0;
        regWrite =0;
        
    end

    7'b1101111://jump and link inst (jal)
    begin
        branch =0;
        memRead =0;
        memtoReg =0;
        ALUOp =2'b00;
        memWrite =0;
        ALUSrc =0;   // ALU result is unused for jal (target/link computed on dedicated adders)
        regWrite =1;
        jump = 1;

    end
    default:
    begin

    branch    = 0;
    memRead   = 0;
    memtoReg  = 0;
    ALUOp     = 2'b00;
    memWrite  = 0;
    ALUSrc    = 0;
    regWrite  = 0;
    jump      = 0;

    end
endcase

 funct3 = funt3;
 funct7 = funt7;
    

end
endmodule
  