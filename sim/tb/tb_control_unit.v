`include "Control.v"

// Generation 2 (Phase M, docs/adr/0028-rv64-migration-phase-m.md). Standalone
// unit test for Control.v's new XLEN-gated OPCODE_OP_32/OPCODE_OP_IMM_32
// decode: illegal-instruction trap at XLEN=32 (previously-reserved
// encodings), real decode at XLEN=64. Two DUTs, same shape as
// tb_immgen_unit.v's Width=32/Width=64 pair.
module tb_control_unit;
    reg [6:0] opcode = 0;
    reg [6:0] funt7 = 0;
    reg [2:0] funt3 = 0;
    reg [11:0] csr_imm12 = 0;

    wire branch32, memRead32, memtoReg32, memWrite32, ALUSrc32, regWrite32;
    wire [1:0] ALUOp32;
    wire [2:0] funct3_32;
    wire [6:0] funct7_32;
    wire jump32, jalr32, lui32, auipc32, isCsr32, isEcall32, isEbreak32, isMret32;
    wire isSret32, isSfenceVma32, isFence32, illegalOpcode32, fRegWrite32;

    wire branch64, memRead64, memtoReg64, memWrite64, ALUSrc64, regWrite64;
    wire [1:0] ALUOp64;
    wire [2:0] funct3_64;
    wire [6:0] funct7_64;
    wire jump64, jalr64, lui64, auipc64, isCsr64, isEcall64, isEbreak64, isMret64;
    wire isSret64, isSfenceVma64, isFence64, illegalOpcode64, fRegWrite64;

    Control #(.XLEN(32)) dut32(
        .opcode(opcode), .funt7(funt7), .funt3(funt3), .csr_imm12(csr_imm12),
        .branch(branch32), .memRead(memRead32), .memtoReg(memtoReg32), .ALUOp(ALUOp32),
        .memWrite(memWrite32), .ALUSrc(ALUSrc32), .regWrite(regWrite32),
        .funct3(funct3_32), .funct7(funct7_32), .jump(jump32), .jalr(jalr32),
        .lui(lui32), .auipc(auipc32), .isCsr(isCsr32), .isEcall(isEcall32),
        .isEbreak(isEbreak32), .isMret(isMret32), .isSret(isSret32),
        .isSfenceVma(isSfenceVma32), .isFence(isFence32),
        .illegalOpcode(illegalOpcode32), .fRegWrite(fRegWrite32)
    );

    Control #(.XLEN(64)) dut64(
        .opcode(opcode), .funt7(funt7), .funt3(funt3), .csr_imm12(csr_imm12),
        .branch(branch64), .memRead(memRead64), .memtoReg(memtoReg64), .ALUOp(ALUOp64),
        .memWrite(memWrite64), .ALUSrc(ALUSrc64), .regWrite(regWrite64),
        .funct3(funct3_64), .funct7(funct7_64), .jump(jump64), .jalr(jalr64),
        .lui(lui64), .auipc(auipc64), .isCsr(isCsr64), .isEcall(isEcall64),
        .isEbreak(isEbreak64), .isMret(isMret64), .isSret(isSret64),
        .isSfenceVma(isSfenceVma64), .isFence(isFence64),
        .illegalOpcode(illegalOpcode64), .fRegWrite(fRegWrite64)
    );

    integer checks = 0;
    integer fails = 0;

    task check_bit;
        input actual, expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: %b, expected %b", label, actual, expected);
            end else begin
                $display("pass  %0s: %b", label, actual);
            end
        end
    endtask

    initial begin
        opcode = `OPCODE_OP_32;
        #1;
        check_bit(illegalOpcode32, 1'b1, "OP-32 at XLEN=32: traps illegal");
        check_bit(regWrite32, 1'b0, "OP-32 at XLEN=32: regWrite stays 0");
        check_bit(illegalOpcode64, 1'b0, "OP-32 at XLEN=64: not illegal");
        check_bit(regWrite64, 1'b1, "OP-32 at XLEN=64: regWrite=1");
        check_bit(ALUOp64 == `ALUOP_RTYPE, 1'b1, "OP-32 at XLEN=64: ALUOp=RTYPE");

        opcode = `OPCODE_OP_IMM_32;
        #1;
        check_bit(illegalOpcode32, 1'b1, "OP-IMM-32 at XLEN=32: traps illegal");
        check_bit(regWrite32, 1'b0, "OP-IMM-32 at XLEN=32: regWrite stays 0");
        check_bit(illegalOpcode64, 1'b0, "OP-IMM-32 at XLEN=64: not illegal");
        check_bit(regWrite64, 1'b1, "OP-IMM-32 at XLEN=64: regWrite=1");
        check_bit(ALUSrc64, 1'b1, "OP-IMM-32 at XLEN=64: ALUSrc=1");
        check_bit(ALUOp64 == `ALUOP_ITYPE, 1'b1, "OP-IMM-32 at XLEN=64: ALUOp=ITYPE");

        if (fails == 0)
            $display("PASS  control_unit (%0d checks)", checks);
        else
            $display("FAIL  control_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
