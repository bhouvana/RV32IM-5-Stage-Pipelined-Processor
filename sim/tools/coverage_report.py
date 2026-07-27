#!/usr/bin/env python3
"""
Functional coverage aggregator (docs/ROADMAP.md V-5). Runs the full
directed suite with -DCOVERAGE, collects each test's coverage.txt
(design/riscvpipeline.v's dump_coverage task), sums counts across the whole
suite, and reports which ALUCtl operations / branch types / hazard classes
were never exercised.

This is functional coverage (did we exercise X), not statement/branch
coverage from a formal tool (none was available in this environment, see
docs/adr/0010-random-testing-and-coverage.md) -- it answers "does the suite
touch every instruction category and hazard class," not "does it touch
every line of RTL."

Usage: python coverage_report.py --iverilog-dir C:/iverilog/bin
Must be run from the repository root.
"""
import argparse
import glob
import os
import subprocess
import sys

ALUCTL_NAMES = {
    0: "ADD", 1: "SUB", 2: "SLL", 3: "SLT", 4: "SLTU", 5: "XOR", 6: "SRL", 7: "SRA",
    8: "OR", 9: "AND", 10: "BEQ", 11: "BNE", 12: "BLT", 13: "BGE", 14: "BLE (custom)",
    16: "BGT (custom)", 17: "BLTU", 18: "BGEU", 19: "MUL", 20: "MULH", 21: "CTZ (custom)",
    22: "MULHSU", 23: "MULHU", 24: "DIV", 25: "DIVU", 26: "REM", 27: "REMU", 31: "ILLEGAL",
}
# DIV/DIVU/REM/REMU's ALUCtl value is sampled here every cycle a div/rem
# instruction occupies EX (docs/adr/0009) -- the ALU itself never computes
# anything for these codes (the divider does), but the wire still reads
# that value throughout the ~33-cycle stall, so these counts are real and
# expected to be large (cycles stalled, not "times computed").
BRANCH_F3_NAMES = {0: "beq", 1: "bne", 2: "blt", 3: "bge", 4: "ble", 5: "bgt", 6: "bltu", 7: "bgeu"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iverilog-dir", default=None)
    args = ap.parse_args()

    iverilog = os.path.join(args.iverilog_dir, "iverilog.exe") if args.iverilog_dir else "iverilog"
    vvp = os.path.join(args.iverilog_dir, "vvp.exe") if args.iverilog_dir else "vvp"

    total_alu = [0] * 32
    total_branch_taken = [0] * 8
    total_branch_not_taken = [0] * 8
    total_stall = total_flush = total_div = total_jump = 0

    tb_files = sorted(glob.glob("sim/tb/tb_*.v"))
    for tb in tb_files:
        name = os.path.splitext(os.path.basename(tb))[0]
        vvp_path = f"_cov_{name}.vvp"
        r = subprocess.run([iverilog, "-g2005", "-DCOVERAGE", "-I", "design", "-I", "sim/tb", "-o", vvp_path, tb],
                            capture_output=True, text=True)
        if r.returncode != 0:
            print(f"COMPILE FAIL {name}: {r.stderr.strip()[:300]}")
            continue
        subprocess.run([vvp, vvp_path], capture_output=True, text=True)
        os.remove(vvp_path)

        if not os.path.exists("coverage.txt"):
            print(f"WARN  {name}: no coverage.txt produced")
            continue
        with open("coverage.txt") as f:
            for line in f:
                parts = line.split()
                if parts[0] == "alu_ctl":
                    total_alu[int(parts[1])] += int(parts[2])
                elif parts[0] == "branch_taken":
                    total_branch_taken[int(parts[1])] += int(parts[2])
                elif parts[0] == "branch_not_taken":
                    total_branch_not_taken[int(parts[1])] += int(parts[2])
                elif parts[0] == "stall_cycles":
                    total_stall += int(parts[1])
                elif parts[0] == "flush_cycles":
                    total_flush += int(parts[1])
                elif parts[0] == "div_cycles":
                    total_div += int(parts[1])
                elif parts[0] == "jump_cycles":
                    total_jump += int(parts[1])
        os.remove("coverage.txt")

    print(f"\n=== ALUCtl coverage (across {len(tb_files)} directed tests) ===")
    uncovered = []
    for code in sorted(ALUCTL_NAMES):
        name = ALUCTL_NAMES[code]
        cnt = total_alu[code]
        marker = "  " if cnt > 0 or code == 31 else "!!"
        print(f"  {marker} {code:2d} {name:16s} {cnt:6d} cycles")
        if cnt == 0 and code != 31:
            uncovered.append(name)

    print("\n=== branch outcome coverage (each type, taken vs. not-taken) ===")
    for f3 in range(8):
        t, nt = total_branch_taken[f3], total_branch_not_taken[f3]
        marker = "!!" if (t == 0 or nt == 0) else "  "
        print(f"  {marker} {BRANCH_F3_NAMES[f3]:5s} taken={t:5d}  not-taken={nt:5d}")

    print("\n=== hazard/control-flow event coverage ===")
    print(f"  load-use stall cycles (Hazard.v):     {total_stall}")
    print(f"  load-use flush/bubble cycles:          {total_flush}")
    print(f"  multi-cycle divide stall cycles:       {total_div}")
    print(f"  jal/jalr cycles in EX:                 {total_jump}")

    if uncovered:
        print(f"\n!! {len(uncovered)} ALUCtl operation(s) never exercised by the directed suite: {', '.join(uncovered)}")
    if total_stall == 0:
        print("!! load-use stall never exercised")
    if total_div == 0:
        print("!! multi-cycle divide stall never exercised")
    for f3 in range(8):
        if total_branch_taken[f3] == 0:
            print(f"!! {BRANCH_F3_NAMES[f3]} never taken")
        if total_branch_not_taken[f3] == 0:
            print(f"!! {BRANCH_F3_NAMES[f3]} never not-taken")


if __name__ == "__main__":
    main()
