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
`define OPCODE_SYSTEM 7'b1110011  // CSR instructions, ecall, ebreak, mret (docs/adr/0011-csr-and-exceptions.md)

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

// ---- RV32M (docs/adr/0006-rv32m.md) ----
`define ALUCTL_MUL    5'b10011
`define ALUCTL_MULH   5'b10100
`define ALUCTL_MULHSU 5'b10110
`define ALUCTL_MULHU  5'b10111
`define ALUCTL_DIV    5'b11000
`define ALUCTL_DIVU   5'b11001
`define ALUCTL_REM    5'b11010
`define ALUCTL_REMU   5'b11011

// funct7 values used to distinguish R-type sub-ops now that ALUCtrl sees the
// full 7-bit field (previously only inst[30] was threaded through, enough
// for add/sub but not enough to add a whole new funct7=0000001 group).
`define FUNCT7_BASE   7'b0000000  // add/sll/slt/sltu/xor/srl/or/and
`define FUNCT7_ALT    7'b0100000  // sub/sra, and this core's custom ctz
`define FUNCT7_MULDIV 7'b0000001  // RV32M

// ---- CSR / exceptions (docs/adr/0011-csr-and-exceptions.md) ----
// M-mode only: no S-mode/U-mode, no PMP, no real interrupts (this design
// has no interrupt lines) -- synchronous exceptions (illegal instruction,
// ecall, ebreak) and the 5 CSRs needed to handle and return from them.

// SYSTEM opcode funct3 (inst[14:12]): which CSR op, or "not a CSR read/
// write at all" (000 -- ecall/ebreak/mret, distinguished by inst[31:20]).
`define CSR_F3_NONE   3'b000
`define CSR_F3_RW     3'b001
`define CSR_F3_RS     3'b010
`define CSR_F3_RC     3'b011
`define CSR_F3_RWI    3'b101
`define CSR_F3_RSI    3'b110
`define CSR_F3_RCI    3'b111

// inst[31:20] (the "csr" field position) for funct3=000's three defined instructions.
`define CSR_IMM12_ECALL  12'h000
`define CSR_IMM12_EBREAK 12'h001
`define CSR_IMM12_MRET   12'h302

// CSR addresses (standard RISC-V machine-mode assignments)
`define CSR_ADDR_MSTATUS  12'h300
`define CSR_ADDR_MTVEC    12'h305
`define CSR_ADDR_MSCRATCH 12'h340
`define CSR_ADDR_MEPC     12'h341
`define CSR_ADDR_MCAUSE   12'h342

// mcause values this core can actually raise (exceptions only -- interrupt
// bit, mcause[31], is always 0 here since nothing generates interrupts)
`define MCAUSE_ILLEGAL_INSTRUCTION 32'd2
`define MCAUSE_BREAKPOINT          32'd3
`define MCAUSE_ECALL_FROM_M        32'd11

`endif
