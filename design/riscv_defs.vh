// Single source of truth for opcode/ALUCtl encodings used across Control.v,
// ALUCtrl.v, and ImmGen.v. Before this file, each module hardcoded its own
// copy of these literals (docs/ARCHITECTURE.md sec 12) -- a duplicated
// magic-number table is exactly what tends to drift silently when a new
// opcode gets added (RV32M, CSR, ...), so centralizing it now pays for
// itself the moment Phase 5 extension work starts.
//
// sim/tools/asm.py's OP_*/R_TYPE/I_TYPE/BRANCH tables are a second,
// independent copy of this same information (Python can't `include` a
// Verilog header) -- keep them in sync by hand until they're generated from
// a shared source (docs/ROADMAP.md notes this as a known gap).

`ifndef RISCV_DEFS_VH
`define RISCV_DEFS_VH

// ---- opcodes (inst[6:0]) ----
`define OPCODE_R      7'b0110011  // R-type ALU
`define OPCODE_I      7'b0010011  // I-type ALU (addi/slti/.../srai)
`define OPCODE_LOAD   7'b0000011  // lw (see docs/ARCHITECTURE.md sec 9: word-only today)
`define OPCODE_STORE  7'b0100011  // sw (word-only today)
`define OPCODE_BRANCH 7'b1100011  // beq/bne/blt/bge/ble/bgt/bltu/bgeu
`define OPCODE_JAL    7'b1101111
`define OPCODE_JALR   7'b1100111
`define OPCODE_LUI    7'b0110111
`define OPCODE_AUIPC  7'b0010111
`define OPCODE_CUSTOM 7'b0101010  // ctz (see design/ALUCtrl.v ALUCtl=10101)

// ---- ALUOp (Control.v output -> ALUCtrl.v input) ----
`define ALUOP_LOAD_STORE 2'b00  // lw/sw/jal: ALU always adds
`define ALUOP_BRANCH     2'b01
`define ALUOP_RTYPE      2'b10  // also covers OPCODE_CUSTOM (ctz)
`define ALUOP_ITYPE      2'b11

// ---- ALUCtl (ALUCtrl.v output -> ALU.v input) ----
`define ALUCTL_ADD  5'b00000
`define ALUCTL_SUB  5'b00001
`define ALUCTL_SLL  5'b00010
`define ALUCTL_SLT  5'b00011
`define ALUCTL_SLTU 5'b00100
`define ALUCTL_XOR  5'b00101
`define ALUCTL_SRL  5'b00110
`define ALUCTL_SRA  5'b00111
`define ALUCTL_OR   5'b01000
`define ALUCTL_AND  5'b01001
`define ALUCTL_BEQ  5'b01010
`define ALUCTL_BNE  5'b01011
`define ALUCTL_BLT  5'b01100
`define ALUCTL_BGE  5'b01101
`define ALUCTL_BLE  5'b01110  // custom (see docs/ARCHITECTURE.md sec 5: not standard RV32I)
`define ALUCTL_BGT  5'b10000  // custom
`define ALUCTL_BLTU 5'b10001
`define ALUCTL_BGEU 5'b10010
`define ALUCTL_CTZ  5'b10101  // custom
`define ALUCTL_ILLEGAL 5'b11111

`endif
