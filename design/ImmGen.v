`default_nettype none

// Immediate extraction: RV32I's five immediate encodings (I/S/B/U/J-type,
// plus the CSR/SYSTEM zero-extended case) decoded from the raw instruction
// word and sign-extended (or, for CSR addresses, zero-extended) per RV32I's
// spec.
module ImmGen#(parameter Width = 32) (
    input [Width-1:0] inst,
    output reg signed [Width-1:0] imm
);

    wire [6:0] opcode = inst[6:0];
    always @(*)
    begin
        // Default prevents latch inference for opcodes with no immediate
        // field (R-type, the custom op) that fall through this case.
        imm = {Width{1'b0}};
        case(opcode)
            7'b0010011: //addi subi ori slti andi lw all I type instructions
            begin
                if(inst[14:12] == 3'b101 || inst[14:12] == 3'b001)
                    begin
                    imm = {{20{1'b0}},inst[24:20]};
                    end
                else if(inst[14:12] == 3'b011)
                    begin
                    imm = $unsigned({{20{inst[31]}},inst[31:20]});
                    end
                else
                    begin
                    imm = {{20{inst[31]}},inst[31:20]};
                    end
            end


            7'b1100011: //beq
            begin
                //imm[12] = inst[31];
                //imm[11] = inst[7];
                //imm[10:5] = inst[30:25];
                //imm[4:1] = inst[11:8] 
                imm = {1'b0,{20{inst[31]}}, inst[7], inst[30:25], inst[11:8]};
 
            end
            7'b0000011://lw
            begin
                imm = {{20{inst[31]}},inst[31:20]};
            end


            7'b0100011://sw
            begin
                //imm[11:5] = inst[31:25];
                  //imm[4:0] =inst[11:7];
                imm = {{20{inst[31]}},inst[31:25],inst[11:7]};
            end


            7'b1101111://jal
            begin
                //imm[20] = inst[31];
                //imm[19:12] = inst[19:11];
                 //imm[11] = inst[20];
                //imm[10:1] = inst[30:21];
                imm ={1'b0,{11{inst[31]}},inst[31],inst[19:12],inst[20],inst[30:21]};
            end

            7'b1100111://jalr -- plain I-type immediate (NOT the shifted branch/jal
            begin                //convention: jalr's target is rs1+imm, computed directly, no ShiftLeftOne)
                imm = {{20{inst[31]}},inst[31:20]};
            end

            7'b0110111, //lui
            7'b0010111: //auipc -- both U-type: imm = inst[31:12] in the top 20 bits, low 12 zero
            begin
                imm = {inst[31:12], 12'b0};
            end

            7'b1110011: //SYSTEM (csrrw/csrrs/csrrc+i, ecall, ebreak, mret) --
                        //inst[31:20] is the CSR address for real csrrX ops
            begin      //(riscvpipeline.v takes imm[11:0] as csr_addr); zero-
                       //extended since a CSR address isn't sign-extended
                imm = {20'b0, inst[31:20]};
            end

	endcase
    end
            
endmodule

`default_nettype wire
