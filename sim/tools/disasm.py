#!/usr/bin/env python3
"""
Shared disassembler for this core's exact ISA (RV32I + RV32M + its specific
deviations -- ble/bgt custom branches, ctz custom op, CSR/ecall/ebreak/mret).
Single source of truth for turning a raw instruction word into a mnemonic
string, used by sim/tools/gen_trace.py (pipeline viewer) and
sim/tools/debugger.py (interactive ISS debugger, docs/ROADMAP.md Phase 8) --
previously gen_trace.py had its own copy that never learned RV32M or
CSR/SYSTEM encodings (an R-type instruction with funct7=0000001 only
differs from add/sub in the bit gen_trace.py's old disasm() didn't check,
so `mul x3,x1,x2` silently disassembled as `add x3,x1,x2` in the pipeline
viewer -- fixed here by checking the full 7-bit funct7 like design/ALUCtrl.v
does, not just bit 30).

Mirrors design/riscv_defs.vh's opcode/funct7 constants and design/ALUCtrl.v's
decode table -- kept as a second, independent reading of the encoding (like
sim/tools/iss.py) rather than importing anything RTL-side.
"""

OPCODE_R = 0b0110011
OPCODE_I = 0b0010011
OPCODE_LOAD = 0b0000011
OPCODE_STORE = 0b0100011
OPCODE_BRANCH = 0b1100011
OPCODE_JAL = 0b1101111
OPCODE_JALR = 0b1100111
OPCODE_LUI = 0b0110111
OPCODE_AUIPC = 0b0010111
OPCODE_CUSTOM = 0b0101010
OPCODE_SYSTEM = 0b1110011

FUNCT7_BASE = 0b0000000
FUNCT7_ALT = 0b0100000
FUNCT7_MULDIV = 0b0000001

CSR_NAMES = {0x300: "mstatus", 0x305: "mtvec", 0x340: "mscratch", 0x341: "mepc", 0x342: "mcause"}


def sext(v, bits):
    v &= (1 << bits) - 1
    if v & (1 << (bits - 1)):
        v -= (1 << bits)
    return v


def csr_name(addr):
    return CSR_NAMES.get(addr, f"0x{addr:03x}")


def disasm(word):
    """word: raw 32-bit instruction as an int. Returns a mnemonic string."""
    if word == 0x00000013:
        return "nop"
    if word == 0:
        return "—"  # only ever the reset/bubble value now (docs/adr/0014) -- a real
                     # program never actually contains a zero word (traps if fetched)

    op = word & 0x7F
    rd = (word >> 7) & 0x1F
    f3 = (word >> 12) & 0x7
    rs1 = (word >> 15) & 0x1F
    rs2 = (word >> 20) & 0x1F
    f7 = (word >> 25) & 0x7F
    imm_i = sext(word >> 20, 12)

    if op == OPCODE_R:
        if f7 == FUNCT7_MULDIV:
            names = {0: "mul", 1: "mulh", 2: "mulhsu", 3: "mulhu",
                      4: "div", 5: "divu", 6: "rem", 7: "remu"}
            return f"{names[f3]} x{rd},x{rs1},x{rs2}"
        if f7 == FUNCT7_ALT and f3 == 0b111:
            return f"ctz x{rd},x{rs1}"
        names = {(FUNCT7_BASE, 0): "add", (FUNCT7_ALT, 0): "sub", (FUNCT7_BASE, 1): "sll",
                  (FUNCT7_BASE, 2): "slt", (FUNCT7_BASE, 3): "sltu", (FUNCT7_BASE, 4): "xor",
                  (FUNCT7_BASE, 5): "srl", (FUNCT7_ALT, 5): "sra", (FUNCT7_BASE, 6): "or",
                  (FUNCT7_BASE, 7): "and"}
        mn = names.get((f7, f3), f"r-type?(f7={f7:#04x},f3={f3})")
        return f"{mn} x{rd},x{rs1},x{rs2}"

    if op == OPCODE_I:
        if f3 in (1, 5):
            shamt = (word >> 20) & 0x1F
            mn = {1: "slli", 5: ("srai" if f7 == FUNCT7_ALT else "srli")}[f3]
            return f"{mn} x{rd},x{rs1},{shamt}"
        names = {0: "addi", 2: "slti", 3: "sltiu", 4: "xori", 6: "ori", 7: "andi"}
        return f"{names.get(f3, 'i-type?')} x{rd},x{rs1},{imm_i}"

    if op == OPCODE_LOAD:
        names = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}
        return f"{names.get(f3, 'load?')} x{rd},{imm_i}(x{rs1})"

    if op == OPCODE_STORE:
        imm_s = sext(((word >> 25) << 5) | ((word >> 7) & 0x1F), 12)
        names = {0: "sb", 1: "sh", 2: "sw"}
        return f"{names.get(f3, 'store?')} x{rs2},{imm_s}(x{rs1})"

    if op == OPCODE_BRANCH:
        b12 = (word >> 31) & 1
        b11 = (word >> 7) & 1
        b10_5 = (word >> 25) & 0x3F
        b4_1 = (word >> 8) & 0xF
        off = sext((b12 << 12) | (b11 << 11) | (b10_5 << 5) | (b4_1 << 1), 13)
        names = {0: "beq", 1: "bne", 2: "blt", 3: "bge", 4: "ble", 5: "bgt", 6: "bltu", 7: "bgeu"}
        return f"{names.get(f3, 'branch?')} x{rs1},x{rs2},{off:+d}"

    if op == OPCODE_JAL:
        b20 = (word >> 31) & 1
        b19_12 = (word >> 12) & 0xFF
        b11 = (word >> 20) & 1
        b10_1 = (word >> 21) & 0x3FF
        off = sext((b20 << 20) | (b19_12 << 12) | (b11 << 11) | (b10_1 << 1), 21)
        return f"jal x{rd},{off:+d}"

    if op == OPCODE_JALR:
        return f"jalr x{rd},{imm_i}(x{rs1})"

    if op == OPCODE_LUI:
        return f"lui x{rd},0x{(word >> 12) & 0xFFFFF:x}"

    if op == OPCODE_AUIPC:
        return f"auipc x{rd},0x{(word >> 12) & 0xFFFFF:x}"

    if op == OPCODE_CUSTOM:
        return f"ctz x{rd},x{rs1}"

    if op == OPCODE_SYSTEM:
        csr_addr = (word >> 20) & 0xFFF
        if f3 == 0:
            return {0x000: "ecall", 0x001: "ebreak", 0x302: "mret"}.get(csr_addr, f"system?(imm12={csr_addr:#x})")
        names = {0b001: "csrrw", 0b010: "csrrs", 0b011: "csrrc",
                  0b101: "csrrwi", 0b110: "csrrsi", 0b111: "csrrci"}
        mn = names.get(f3, "csr?")
        if f3 & 0b100:  # *i variants: rs1's field position is a 5-bit zero-extended uimm
            return f"{mn} x{rd},{csr_name(csr_addr)},{rs1}"
        return f"{mn} x{rd},{csr_name(csr_addr)},x{rs1}"

    return f"0x{word:08x}?"
