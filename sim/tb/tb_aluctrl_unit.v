`include "ALUCtrl.v"

// Generation 2 (Phase M, docs/adr/0028-rv64-migration-phase-m.md). Standalone
// unit test for ALUCtrl.v's shift-immediate discriminator fix: SRL-vs-SRA
// selection must key off funct7[6:1] only, not the full 7-bit funct7, so
// RV64I's widened 6-bit shamt (which uses inst[25], the old funct7's low
// bit) doesn't accidentally flip SRL/SRA selection. Sweeps funct7 with bit25
// at both 0 and 1 for both the BASE (SRL) and ALT (SRA) top-6-bit patterns,
// confirming bit25 never changes the outcome -- independent of the full
// pipeline, ALU.v, or ImmGen.v.
//
// Phase N (docs/adr/0030-branch-encoding-fix.md) added the branch funct3->ALUCtl checks
// below: blt/bge at real RISC-V spec funct3 positions (100/101), this core's custom
// ble/bgt at the vacated reserved positions (010/011), bltu/bgeu (110/111) unchanged.
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
        ALUOp = `ALUOP_ITYPE;
        funct3_c = 3'b101;  // srli/srai funct3

        // Legal RV32 encodings (bit25=0): unaffected by the fix.
        funct7_c = 7'b0000000;  // FUNCT7_BASE
        #1 check_ctl(`ALUCTL_SRL, "funct7=BASE, bit25=0 -> SRL");
        funct7_c = 7'b0100000;  // FUNCT7_ALT
        #1 check_ctl(`ALUCTL_SRA, "funct7=ALT, bit25=0 -> SRA");

        // RV64-shaped: bit25 set (part of the widened 6-bit shamt), top 6
        // bits (funct6) still BASE/ALT -- must still select SRL/SRA
        // correctly despite bit25 now carrying real shamt data.
        funct7_c = 7'b0000001;  // funct6=000000 (BASE), bit25=1
        #1 check_ctl(`ALUCTL_SRL, "funct6=BASE, bit25=1 (shamt bit) -> still SRL");
        funct7_c = 7'b0100001;  // funct6=010000 (ALT), bit25=1
        #1 check_ctl(`ALUCTL_SRA, "funct6=ALT, bit25=1 (shamt bit) -> still SRA");

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
