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

// ---- RV32F (docs/adr/0019-f-extension.md, Phase C of the redesign) ----
// Encoding constants only in this commit -- no RTL consumes any of these
// yet (mirrors this project's own precedent of declaring a new mechanism
// before anything wires it up, e.g. docs/adr/0018's Phase A1). This core
// implements F only, never D (double-precision) -- fmt is always FMT_S,
// and FLEN==XLEN==32 exactly, so NaN-boxing (which exists only to keep
// narrower-than-FLEN values distinguishable from real FLEN-wide ones) does
// not apply here and is deliberately not implemented (see the ADR).

// New opcodes (inst[6:0])
`define OPCODE_FP       7'b1010011  // fadd.s/fsub.s/fmul.s/.../feq.s/fcvt.*/fmv.*/fclass.s -- sub-op in funct5 (inst[31:27])
`define OPCODE_LOAD_FP  7'b0000111  // flw
`define OPCODE_STORE_FP 7'b0100111  // fsw
`define OPCODE_MADD     7'b1000011  // fmadd.s
`define OPCODE_MSUB     7'b1000111  // fmsub.s
`define OPCODE_NMSUB    7'b1001011  // fnmsub.s
`define OPCODE_NMADD    7'b1001111  // fnmadd.s

// fmt field (inst[26:25], present on OPCODE_FP and the MADD-family
// opcodes) -- 2'b00 (S, single-precision) is the only value this core ever
// produces or accepts; 2'b01 (D)/2'b10 (H)/2'b11 (Q) are other precisions
// this core does not implement.
`define FMT_S 2'b00

// OP-FP funct5 (inst[31:27]): which float operation. A recognized funct5
// with an unrecognized funct3/rs2 sub-selector below still traps as
// illegal, the same way ALUCtrl.v's own `default: ALUCTL_ILLEGAL` does for
// integer ops.
`define FUNCT5_FADD           5'b00000
`define FUNCT5_FSUB           5'b00001
`define FUNCT5_FMUL           5'b00010
`define FUNCT5_FDIV           5'b00011
`define FUNCT5_FSQRT          5'b01011  // rs2 must be 0 (single real operand, rs1)
`define FUNCT5_FSGNJ          5'b00100  // funct3 selects fsgnj.s/fsgnjn.s/fsgnjx.s
`define FUNCT5_FMINMAX        5'b00101  // funct3 selects fmin.s/fmax.s
`define FUNCT5_FCMP           5'b10100  // funct3 selects fle.s/flt.s/feq.s -- writes an INTEGER dest register
`define FUNCT5_FCVT_W_S       5'b11000  // rs2 selects fcvt.w.s/fcvt.wu.s -- writes an INTEGER dest register
`define FUNCT5_FCVT_S_W       5'b11010  // rs2 selects fcvt.s.w/fcvt.s.wu -- writes the FLOAT dest register
`define FUNCT5_FMV_X_W_FCLASS 5'b11100  // funct3 selects fmv.x.w/fclass.s -- both write an INTEGER dest register; rs2 must be 0
`define FUNCT5_FMV_W_X        5'b11110  // rs2 must be 0; writes the FLOAT dest register

// funct3 sub-selectors within a shared funct5 group
`define F3_FSGNJ_J      3'b000
`define F3_FSGNJ_JN     3'b001
`define F3_FSGNJ_JX     3'b010
`define F3_FMIN         3'b000
`define F3_FMAX         3'b001
`define F3_FLE          3'b000
`define F3_FLT          3'b001
`define F3_FEQ          3'b010
`define F3_FMV_X_W      3'b000
`define F3_FCLASS       3'b001

// rs2 sub-selectors (inst[24:20]) within FUNCT5_FCVT_W_S/FUNCT5_FCVT_S_W --
// only meaningful for those two funct5 groups; every other OP-FP funct5
// either ignores rs2 entirely (2-operand ops) or requires it to be 0
// (fsqrt.s/fmv.x.w/fmv.w.x/fclass.s, per spec -- a nonzero rs2 there is a
// reserved/illegal encoding, not a real conversion variant).
`define RS2_FCVT_W  5'b00000
`define RS2_FCVT_WU 5'b00001

// Rounding mode (inst[14:12] on OP-FP/MADD-family instructions, "rm").
// RM_DYN means "use frm's current value instead of a static per-instruction
// mode" -- see docs/adr/0019 and CSR_ADDR_FRM below. 3'b101/3'b110 are
// reserved (unrecognized rm -- see docs/adr/0019 for how this core handles it).
`define RM_RNE 3'b000  // round to nearest, ties to even (IEEE 754 default)
`define RM_RTZ 3'b001  // round toward zero
`define RM_RDN 3'b010  // round down (toward -infinity)
`define RM_RUP 3'b011  // round up (toward +infinity)
`define RM_RMM 3'b100  // round to nearest, ties to max magnitude
`define RM_DYN 3'b111  // dynamic -- use frm

// New CSR addresses (standard RISC-V assignments). fflags/frm are the two
// sub-fields of fcsr, also independently addressable per spec (a csrrw to
// fflags or frm alone must not disturb the other field).
`define CSR_ADDR_FFLAGS 12'h001
`define CSR_ADDR_FRM    12'h002
`define CSR_ADDR_FCSR   12'h003

`endif
