`include "ALUCtrl.v"

// Phase N (docs/adr/0030-branch-encoding-fix.md). Standalone unit test for ALUCtrl.v's
// branch funct3->ALUCtl mapping: blt/bge at real RISC-V spec funct3 positions (100/101),
// this core's custom ble/bgt at the vacated reserved positions (010/011), bltu/bgeu
// (110/111) unchanged. Independent of the full pipeline, ALU.v, or asm.py/disasm.py/iss.py.
module tb_aluctrl_unit;
    reg  [1:0] ALUOp = 0;
    reg  [6:0] funct7_c = 0;
    reg  [2:0] funct3_c = 0;
    wire [4:0] ALUCtl;

    ALUCtrl dut(.ALUOp(ALUOp), .funct7_c(funct7_c), .funct3_c(funct3_c), .ALUCtl(ALUCtl));

    integer checks = 0;
    integer fails = 0;

    task check_ctl;
        input [4:0] expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (ALUCtl !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: ALUCtl=%b, expected %b", label, ALUCtl, expected);
            end else begin
                $display("pass  %0s: ALUCtl=%b", label, ALUCtl);
            end
        end
    endtask

    initial begin
        ALUOp = `ALUOP_BRANCH;
        funct7_c = 0; // branches don't use funct7

        funct3_c = 3'b100;
        #1 check_ctl(`ALUCTL_BLT, "funct3=100 -> BLT (real spec position)");
        funct3_c = 3'b101;
        #1 check_ctl(`ALUCTL_BGE, "funct3=101 -> BGE (real spec position)");
        funct3_c = 3'b010;
        #1 check_ctl(`ALUCTL_BLE, "funct3=010 -> BLE (custom, moved to reserved slot)");
        funct3_c = 3'b011;
        #1 check_ctl(`ALUCTL_BGT, "funct3=011 -> BGT (custom, moved to reserved slot)");
        funct3_c = 3'b110;
        #1 check_ctl(`ALUCTL_BLTU, "funct3=110 -> BLTU (unchanged)");
        funct3_c = 3'b111;
        #1 check_ctl(`ALUCTL_BGEU, "funct3=111 -> BGEU (unchanged)");

        if (fails == 0)
            $display("PASS  aluctrl_unit (%0d checks)", checks);
        else
            $display("FAIL  aluctrl_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
