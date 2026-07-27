#!/usr/bin/env python3
"""
Converts sim/tb/gen_trace.v's trace.csv output into the embedded JS data
array used by the pipeline viewer artifact. Also disassembles each
instruction word using this core's exact encoding (see design/riscv_defs.vh)
so the viewer shows real mnemonics instead of raw hex.

Usage: python gen_trace.py trace.csv -o trace.json
"""
import argparse
import csv
import json


def sext(v, bits):
    v &= (1 << bits) - 1
    if v & (1 << (bits - 1)):
        v -= (1 << bits)
    return v


def disasm(word):
    word = int(word, 16)
    if word == 0:
        return "—"
    op = word & 0x7F
    rd = (word >> 7) & 0x1F
    f3 = (word >> 12) & 0x7
    rs1 = (word >> 15) & 0x1F
    rs2 = (word >> 20) & 0x1F
    f7b5 = (word >> 30) & 0x1
    imm_i = sext(word >> 20, 12)

    if word == 0x13:
        return "nop"

    if op == 0b0110011:
        names = {(0, 0): "add", (1, 0): "sub", (0, 1): "sll", (0, 2): "slt",
                 (0, 3): "sltu", (0, 4): "xor", (0, 5): "srl", (1, 5): "sra",
                 (0, 6): "or", (0, 7): "and"}
        mn = names.get((f7b5, f3), "r-type?")
        return f"{mn} x{rd},x{rs1},x{rs2}"
    if op == 0b0010011:
        if f3 in (1, 5):
            shamt = (word >> 20) & 0x1F
            mn = {1: "slli", 5: ("srai" if f7b5 else "srli")}[f3]
            return f"{mn} x{rd},x{rs1},{shamt}"
        names = {0: "addi", 2: "slti", 3: "sltiu", 4: "xori", 6: "ori", 7: "andi"}
        return f"{names.get(f3,'i-type?')} x{rd},x{rs1},{imm_i}"
    if op == 0b0000011:
        names = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}
        return f"{names.get(f3,'load?')} x{rd},{imm_i}(x{rs1})"
    if op == 0b0100011:
        imm_s = sext(((word >> 25) << 5) | ((word >> 7) & 0x1F), 12)
        names = {0: "sb", 1: "sh", 2: "sw"}
        return f"{names.get(f3,'store?')} x{rs2},{imm_s}(x{rs1})"
    if op == 0b1100011:
        b12 = (word >> 31) & 1
        b11 = (word >> 7) & 1
        b10_5 = (word >> 25) & 0x3F
        b4_1 = (word >> 8) & 0xF
        off = sext((b12 << 12) | (b11 << 11) | (b10_5 << 5) | (b4_1 << 1), 13)
        names = {0: "beq", 1: "bne", 2: "blt", 3: "bge", 4: "ble", 5: "bgt", 6: "bltu", 7: "bgeu"}
        return f"{names.get(f3,'branch?')} x{rs1},x{rs2},{off:+d}"
    if op == 0b1101111:
        b20 = (word >> 31) & 1
        b19_12 = (word >> 12) & 0xFF
        b11 = (word >> 20) & 1
        b10_1 = (word >> 21) & 0x3FF
        off = sext((b20 << 20) | (b19_12 << 12) | (b11 << 11) | (b10_1 << 1), 21)
        return f"jal x{rd},{off:+d}"
    if op == 0b1100111:
        return f"jalr x{rd},{imm_i}(x{rs1})"
    if op == 0b0110111:
        return f"lui x{rd},0x{(word>>12)&0xFFFFF:x}"
    if op == 0b0010111:
        return f"auipc x{rd},0x{(word>>12)&0xFFFFF:x}"
    if op == 0b0101010:
        return f"ctz x{rd},x{rs1}"
    return f"0x{word:08x}?"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv_path")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    rows = []
    with open(args.csv_path, newline="") as f:
        for r in csv.DictReader(f):
            rows.append({
                "cycle": int(r["cycle"]),
                "if": {"pc": int(r["if_pc"]), "inst": disasm(r["if_inst"])},
                "id": {"pc": int(r["id_pc"]), "inst": disasm(r["id_inst"]),
                       "stall": bool(int(r["stall"])), "flush": bool(int(r["flush"]))},
                "ex": {"pc": int(r["ex_pc"]), "inst": disasm(r["ex_inst"]),
                       "branchTaken": bool(int(r["branch_taken"])), "jump": bool(int(r["jump"])),
                       "aluOut": int(r["alu_out"]), "fwdA": int(r["forwardA"]), "fwdB": int(r["forwardB"])},
                "mem": {"we": bool(int(r["mem_we"])), "re": bool(int(r["mem_re"])),
                        "addr": int(r["mem_addr"]), "dest": int(r["mem_dest"]), "regWrite": bool(int(r["mem_regwrite"]))},
                "wb": {"dest": int(r["wb_dest"]), "val": int(r["wb_val"]), "regWrite": bool(int(r["wb_regwrite"]))},
            })

    # Trim trailing drain cycles once the program has run off the end of
    # instruction memory (IF shows nothing left to fetch) -- keeps the
    # viewer focused on the actual program instead of dozens of empty rows.
    while rows and rows[-1]["if"]["inst"] == "—" and rows[-1]["id"]["inst"] == "—":
        rows.pop()

    with open(args.output, "w") as f:
        json.dump(rows, f)
    print(f"{args.csv_path}: {len(rows)} cycles -> {args.output}")


if __name__ == "__main__":
    main()
