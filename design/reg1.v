module reg1(
    input clk,
    input rst,
    input stall,
    input [31:0] inst,
    input [31:0] pc_o,
    input branch_regde,
    input zero,
    input jump,       // unconditional redirect (jal) resolved in EX, same squash as a taken branch
    output reg [31:0] inst_regfd,
    output reg [31:0] pc_o_regfd
);

always@(posedge clk)
begin
    if(~rst)
    begin
    inst_regfd <= 0;
    pc_o_regfd <= 0;
    end
    else
        begin
            if((branch_regde & zero) | jump)
            begin
                
                inst_regfd <= 32'h00000013;
                pc_o_regfd <= 0;
            end
            else if(stall)
            begin
                inst_regfd <= inst_regfd;
                pc_o_regfd <= pc_o_regfd;
            end
            else
            begin
                inst_regfd <= inst;
                pc_o_regfd <= pc_o;
            end
    end
end

endmodule