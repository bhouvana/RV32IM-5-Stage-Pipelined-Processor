#!/usr/bin/env python3
"""
Converts sim/tb/gen_trace.v's trace.csv output into the embedded JS data
array used by the pipeline viewer artifact. Also disassembles each
instruction word (via sim/tools/disasm.py, shared with sim/tools/debugger.py)
so the viewer shows real mnemonics instead of raw hex.

Usage: python gen_trace.py trace.csv -o trace.json
"""
import argparse
import csv
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from disasm import disasm as _disasm  # noqa: E402


def disasm(hex_word, xlen=32):
    # Generation 2 (Phase M12, docs/adr/0028-rv64-migration-phase-m.md):
    # xlen only affects disasm()'s own plain slli/srli/srai shamt-width
    # rendering -- the viewer's underlying gen_trace.v testbench is still
    # explicitly PROFILE_5STAGE-only and untouched by this phase, so this is
    # display-only, not a claim that the full viewer supports XLEN=64.
    return _disasm(int(hex_word, 16), xlen=xlen)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv_path")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--xlen", type=int, default=32,
                     help="Generation 2: affects disassembly of plain slli/srli/srai shamt width only")
    args = ap.parse_args()

    rows = []
    with open(args.csv_path, newline="") as f:
        for r in csv.DictReader(f):
            rows.append({
                "cycle": int(r["cycle"]),
                "if": {"pc": int(r["if_pc"]), "inst": disasm(r["if_inst"], args.xlen)},
                "id": {"pc": int(r["id_pc"]), "inst": disasm(r["id_inst"], args.xlen),
                       "stall": bool(int(r["stall"])), "flush": bool(int(r["flush"]))},
                "ex": {"pc": int(r["ex_pc"]), "inst": disasm(r["ex_inst"], args.xlen),
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
