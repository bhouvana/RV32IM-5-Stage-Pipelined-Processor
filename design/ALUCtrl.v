module ALUCtrl (
    input [1:0] ALUOp,
      
    input funct7_c,    //funct7 = funct7[5] 6th bit of the 7 bit number funct7 taken from the instruction
    input [2:0] funct3_c,
    output reg [4:0] ALUCtl
);
wire [2:0] funct3   = funct3_c;
wire       funct7 = funct7_c;
wire [5:0] concat1;
wire [4:0] concat2;

assign concat2 = {ALUOp,funct3};
assign concat1 = {ALUOp,funct7,funct3};
always@(*)
begin
if(ALUOp == 2'b00)
    begin
        ALUCtl = 5'b00000;
    end
else if(ALUOp == 2'b10)
    begin
    case(concat1)
        6'b100000: // add
        ALUCtl = 5'b00000;
        6'b101000: //subtract
        ALUCtl = 5'b00001;
        6'b100001://shift left logical
        ALUCtl = 5'b00010;
        6'b100010://set less than
        ALUCtl = 5'b00011;
        6'b100011://set less than unsigned
        ALUCtl = 5'b00100;
        6'b100100://xor
        ALUCtl = 5'b00101;
        6'b100101://srl
        ALUCtl = 5'b00110;
        6'b101101://sra
        ALUCtl = 5'b00111;
        6'b100110:
        ALUCtl = 5'b01000;//OR
        6'b100111:
        ALUCtl = 5'b01001;//AND
        6'b101111:
        ALUCtl = 5'b10101;//new instruction calculating number of trailing zeroes
        default:
        ALUCtl = 5'b11111;//jaathre
    endcase
    end


else if(ALUOp == 2'b01)
    begin
    case(concat2)
        5'b01000: //beq
        ALUCtl = 5'b01010;//beq
        5'b01001: //bne
        ALUCtl = 5'b01011;//bne
        5'b01010: //blt
        ALUCtl = 5'b01100;//blt
        5'b01011: //bge
        ALUCtl = 5'b01101;//bge
        5'b01100: //ble
        ALUCtl = 5'b01110;//ble
        5'b01101: // bgt
        ALUCtl = 5'b10000;//bgt
        default:
        ALUCtl = 5'b11111;//jaathre
    endcase
    end
else if(ALUOp == 2'b11)
    begin
    case(concat2)
        5'b11000: // add imm
        ALUCtl = 5'b00000;
        5'b11001://shift left logical imm
        ALUCtl = 5'b00010;
        5'b11010://set less than imm
        ALUCtl = 5'b00011;
        5'b11011://set less than unsigned imm
        ALUCtl = 5'b00100;
        5'b11100://xor imm
        ALUCtl = 5'b00101;
        5'b11101://srl imm and sra imm
        begin
            if(funct7 ==1)
            ALUCtl = 5'b00111;
            else
            ALUCtl = 5'b00110;
        end
        5'b11110:
        ALUCtl = 5'b01000;//OR imm
        5'b11111:
        ALUCtl = 5'b01001;//AND imm
        default:
        ALUCtl = 5'b11111;//jaathre
    endcase
    end

end
endmodule