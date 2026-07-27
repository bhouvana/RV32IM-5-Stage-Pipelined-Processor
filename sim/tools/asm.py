#!/usr/bin/env python3
"""
Minimal assembler for this repository's RV32I-subset core (design/riscvpipeline.v).

This is NOT a general RISC-V assembler: it only encodes the instructions this
specific datapath implements, using this core's specific (partly custom)
encodings -- notably the branch funct3 map (ble/bgt instead of bltu/bgeu, see
docs/ARCHITECTURE.md sec 5) and the custom `ctz` op. Output is a byte stream
in the big-endian, $readmemb-compatible binary-ASCII format InstructionMemory.v
expects (one 8-bit binary string per line, most-significant byte first).

Usage: python asm.py program.s -o program.mem
"""
import argparse
import re
import sys

REG_RE = re.compile(r"^x(\d+)$")


def reg(tok):
    m = REG_RE.match(tok.strip())
    if not m:
        raise ValueError(f"expected register (x0-x31), got {tok!r}")
    n = int(m.group(1))
    if not (0 <= n <= 31):
        raise ValueError(f"register out of range: {tok!r}")
    return n


def imm(tok, bits, signed=True):
    v = tok if isinstance(tok, int) else int(tok.strip(), 0)
    lo = -(1 << (bits - 1)) if signed else 0
    hi = (1 << (bits - 1)) - 1 if signed else (1 << bits) - 1
    if not (lo <= v <= hi):
        raise ValueError(f"immediate {v} out of range [{lo},{hi}]")
    return v & ((1 << bits) - 1)


def u(v, bits):
    return v & ((1 << bits) - 1)


# opcode constants (this core's decode table, see design/riscv_defs.vh)
OP_R = 0b0110011
OP_I = 0b0010011
OP_LOAD = 0b0000011
OP_STORE = 0b0100011
OP_BRANCH = 0b1100011
OP_JAL = 0b1101111
OP_JALR = 0b1100111
OP_LUI = 0b0110111
OP_AUIPC = 0b0010111
OP_CUSTOM = 0b0101010

FUNCT7_BASE = 0b0000000
FUNCT7_ALT = 0b0100000    # sub/sra, and this core's custom ctz
FUNCT7_MULDIV = 0b0000001  # RV32M

R_TYPE = {  # mnemonic: (full funct7, funct3)
    "add": (FUNCT7_BASE, 0b000), "sub": (FUNCT7_ALT, 0b000), "sll": (FUNCT7_BASE, 0b001),
    "slt": (FUNCT7_BASE, 0b010), "sltu": (FUNCT7_BASE, 0b011), "xor": (FUNCT7_BASE, 0b100),
    "srl": (FUNCT7_BASE, 0b101), "sra": (FUNCT7_ALT, 0b101), "or": (FUNCT7_BASE, 0b110), "and": (FUNCT7_BASE, 0b111),
    # RV32M (docs/adr/0006-rv32m.md) -- shares the R-type opcode, distinguished by funct7=0000001
    "mul": (FUNCT7_MULDIV, 0b000), "mulh": (FUNCT7_MULDIV, 0b001),
    "mulhsu": (FUNCT7_MULDIV, 0b010), "mulhu": (FUNCT7_MULDIV, 0b011),
    "div": (FUNCT7_MULDIV, 0b100), "divu": (FUNCT7_MULDIV, 0b101),
    "rem": (FUNCT7_MULDIV, 0b110), "remu": (FUNCT7_MULDIV, 0b111),
}
I_TYPE = {  # mnemonic: funct3 (funct7[5] used only by srli/srai)
    "addi": 0b000, "slli": 0b001, "slti": 0b010, "sltiu": 0b011,
    "xori": 0b100, "srli": 0b101, "srai": 0b101, "ori": 0b110, "andi": 0b111,
}
BRANCH = {  # mnemonic: funct3 -- beq/bne/blt/bge/ble/bgt/bltu/bgeu (ble/bgt custom, see docs/ARCHITECTURE.md sec 5)
    "beq": 0b000, "bne": 0b001, "blt": 0b010, "bge": 0b011,
    "ble": 0b100, "bgt": 0b101, "bltu": 0b110, "bgeu": 0b111,
}
LOAD = {"lb": 0b000, "lh": 0b001, "lw": 0b010, "lbu": 0b100, "lhu": 0b101}
STORE = {"sb": 0b000, "sh": 0b001, "sw": 0b010}


def r_type(mn, rd, rs1, rs2):
    f7, f3 = R_TYPE[mn]
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OP_R


def i_type(mn, rd, rs1, immv):
    f3 = I_TYPE[mn]
    if mn in ("slli", "srli", "srai"):
        shamt = imm(immv, 5, signed=False)
        f7 = FUNCT7_ALT if mn == "srai" else FUNCT7_BASE
        # imm12 covers inst[31:20] == funct7(7 bits) ++ shamt(5 bits).
        imm12 = (f7 << 5) | shamt
    else:
        imm12 = imm(immv, 12, signed=True)
    return (u(imm12, 12) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OP_I


def load(mn, rd, offs, rs1):
    imm12 = imm(offs, 12, signed=True)
    return (u(imm12, 12) << 20) | (rs1 << 15) | (LOAD[mn] << 12) | (rd << 7) | OP_LOAD


def store(mn, rs2, offs, rs1):
    imm12 = imm(offs, 12, signed=True)
    hi = (imm12 >> 5) & 0x7F
    lo = imm12 & 0x1F
    return (hi << 25) | (rs2 << 20) | (rs1 << 15) | (STORE[mn] << 12) | (lo << 7) | OP_STORE


def jalr(rd, offs, rs1):
    imm12 = imm(offs, 12, signed=True)
    return (u(imm12, 12) << 20) | (rs1 << 15) | (rd << 7) | OP_JALR


def u_type(opcode, rd, imm20):
    # imm20 is inst[31:12] directly (i.e. already "the upper 20 bits"), not
    # left-shifted again here -- matches typical `lui rd, 0x12345` usage.
    v = imm(imm20, 20, signed=False)
    return (v << 12) | (rd << 7) | opcode


def branch(mn, rs1, rs2, offset_bytes):
    f3 = BRANCH[mn]
    v = imm(offset_bytes, 13, signed=True)
    if v & 1:
        raise ValueError("branch offset must be even")
    b12 = (v >> 12) & 1
    b11 = (v >> 11) & 1
    b10_5 = (v >> 5) & 0x3F
    b4_1 = (v >> 1) & 0xF
    return (b12 << 31) | (b10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (b11 << 7) | (b4_1 << 8) | OP_BRANCH


def jal(rd, offset_bytes):
    v = imm(offset_bytes, 21, signed=True)
    if v & 1:
        raise ValueError("jal offset must be even")
    b20 = (v >> 20) & 1
    b10_1 = (v >> 1) & 0x3FF
    b11 = (v >> 11) & 1
    b19_12 = (v >> 12) & 0xFF
    return (b20 << 31) | (b19_12 << 12) | (b11 << 20) | (b10_1 << 21) | (rd << 7) | OP_JAL


def ctz(rd, rs1):
    # custom op: opcode 0101010, funct7=0100000 (FUNCT7_ALT), funct3=111 (see design/ALUCtrl.v ALUCtl=10101)
    return (FUNCT7_ALT << 25) | (0 << 20) | (rs1 << 15) | (0b111 << 12) | (rd << 7) | OP_CUSTOM


def assemble(lines):
    # pass 1: strip comments/whitespace, record label addresses
    stmts = []
    addr = 0
    labels = {}
    for raw in lines:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.endswith(":"):
            labels[line[:-1].strip()] = addr
            continue
        stmts.append((addr, line))
        addr += 4

    def resolve(tok, cur_addr):
        tok = tok.strip()
        if tok in labels:
            return labels[tok] - cur_addr
        return int(tok, 0)

    words = []
    for cur_addr, line in stmts:
        parts = re.split(r"[,\s]+", line.strip())
        mn = parts[0].lower()
        args = parts[1:]

        if mn == "nop":
            words.append(i_type("addi", 0, 0, 0))
        elif mn in R_TYPE:
            rd, rs1, rs2 = reg(args[0]), reg(args[1]), reg(args[2])
            words.append(r_type(mn, rd, rs1, rs2))
        elif mn == "ctz":
            rd, rs1 = reg(args[0]), reg(args[1])
            words.append(ctz(rd, rs1))
        elif mn in I_TYPE:
            rd, rs1 = reg(args[0]), reg(args[1])
            words.append(i_type(mn, rd, rs1, args[2]))
        elif mn in LOAD:
            rd = reg(args[0])
            m = re.match(r"(-?\w+)\((x\d+)\)", args[1])
            words.append(load(mn, rd, m.group(1), reg(m.group(2))))
        elif mn in STORE:
            rs2 = reg(args[0])
            m = re.match(r"(-?\w+)\((x\d+)\)", args[1])
            words.append(store(mn, rs2, m.group(1), reg(m.group(2))))
        elif mn in BRANCH:
            rs1, rs2 = reg(args[0]), reg(args[1])
            words.append(branch(mn, rs1, rs2, resolve(args[2], cur_addr)))
        elif mn == "jal":
            rd = reg(args[0])
            words.append(jal(rd, resolve(args[1], cur_addr)))
        elif mn == "jalr":
            rd = reg(args[0])
            m = re.match(r"(-?\w+)\((x\d+)\)", args[1])
            words.append(jalr(rd, m.group(1), reg(m.group(2))))
        elif mn == "lui":
            rd = reg(args[0])
            words.append(u_type(OP_LUI, rd, args[1]))
        elif mn == "auipc":
            rd = reg(args[0])
            words.append(u_type(OP_AUIPC, rd, args[1]))
        else:
            raise ValueError(f"unknown mnemonic {mn!r} in line: {line!r}")
    return words


def write_mem(words, path, size_bytes=128):
    data = bytearray(size_bytes)
    for i, w in enumerate(words):
        off = i * 4
        if off + 4 > size_bytes:
            raise ValueError(f"program exceeds {size_bytes}-byte instruction memory")
        data[off + 0] = (w >> 24) & 0xFF
        data[off + 1] = (w >> 16) & 0xFF
        data[off + 2] = (w >> 8) & 0xFF
        data[off + 3] = w & 0xFF
    with open(path, "w") as f:
        for b in data:
            f.write(f"{b:08b}\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--size", type=int, default=128)
    args = ap.parse_args()

    with open(args.source) as f:
        lines = f.readlines()
    try:
        words = assemble(lines)
    except ValueError as e:
        print(f"asm error: {e}", file=sys.stderr)
        sys.exit(1)
    write_mem(words, args.output, args.size)
    print(f"{args.source}: {len(words)} instructions -> {args.output}")


if __name__ == "__main__":
    main()
