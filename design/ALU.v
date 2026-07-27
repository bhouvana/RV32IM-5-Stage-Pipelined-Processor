module ALU (
    input [4:0] ALUCtl,
    input [31:0] A,B,
    output reg [31:0] ALUOut,
    output reg zero,
    output reg branch_zero
);

integer i;
integer count;
integer done;

always@(*)
begin
    ALUOut = 0;
    branch_zero =0;
case(ALUCtl)
    5'b00000: 
    ALUOut = A + B;//simply adding
    5'b00001:
    ALUOut = A - B;//just subtracting
    5'b00010:
    ALUOut = (A << B);//logical shift left
    5'b00011:
    ALUOut = (A < B) ? 1 :0;//set less than
    5'b00100:
    ALUOut = ($unsigned(A) < $unsigned(B)) ? 1 : 0;//set less than unsigned
    5'b00101:
    ALUOut = A ^ B;//xor
    5'b00110:
    ALUOut = (A >> B);//shift right logical
    5'b00111:
    // A/B are plain (unsigned) ports, so >>> alone would silently degrade to a
    // logical shift (Verilog only sign-extends >>> when the operand's *type*
    // is signed). $signed(A) forces true sign-extension for negative operands.
    ALUOut = ($signed(A) >>> B);//shift right arithmetic
    5'b01000:
    ALUOut = ( A | B ) ;//OR
    5'b01001:
    ALUOut = ( A & B );//AND
    5'b01010:
        begin
            branch_zero = ( A == B ) ? 1 : 0;
            ALUOut = A & B;// beq
        end
    5'b01011:
        begin
            branch_zero = ( A != B ) ? 1 : 0;
            ALUOut = A & B;//bne
        end
    5'b01100:
        begin
            branch_zero = ( A < B ) ? 1 : 0;
            ALUOut = A & B;//blt
        end
    5'b01101:
        begin
            branch_zero = ( A >= B ) ? 1 : 0;
            ALUOut = A & B;//bge
        end
    5'b01110:
        begin
            branch_zero = ( A <= B ) ? 1 : 0;
            ALUOut = A & B;//ble
        end
    5'b01111:
        begin
            branch_zero = ( A > B ) ? 1 : 0;
            ALUOut = A & B;//bgt
        end
    5'b10101: 
        begin

            count = 0;
            done =0;
            for(i =0 ; i<31 ; i=i+1)
            begin
                if(A[i] == 0 && done ==0)
                    count = count + 1;
                else
                done =1;
            end
            ALUOut = count;
            
        end
    
endcase
            zero = branch_zero;
end

//assign zero = branch_zero;
    // ALU has two operand, it execute different operator based on ALUctl wire 
    // output zero is for determining taking branch or not 

endmodule

