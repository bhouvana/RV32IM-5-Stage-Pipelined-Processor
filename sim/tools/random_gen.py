#!/usr/bin/env python3
"""
Constrained-random instruction sequence generator (docs/ROADMAP.md V-4).

Constraints chosen to make every generated program *safe to compare*
without needing exception handling (this core has none yet) or a general
loop-detector:
  - x31 is reserved as a fixed memory-safe base pointer, set once at the
    very start and never overwritten by random instructions; all loads/
    stores use it as rs1 with a small, width-appropriate-aligned offset so
    every address stays inside DataMemory's 128 bytes.
  - Branches/jumps only ever target a *later* instruction (forward-only) --
    guarantees termination without a step limit doing the real safety work.
  - Division-by-zero and INT_MIN/-1 overflow are NOT avoided: both
    design/Divider.v and sim/tools/iss.py implement the same spec-mandated
    results, so hitting those cases is extra coverage, not a hazard.
"""
import random

R_TYPE = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
          "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
I_TYPE = ["addi", "slti", "sltiu", "xori", "ori", "andi"]  # slli/srli/srai handled separately (shamt, not full imm)
SHIFT_I = ["slli", "srli", "srai"]
BRANCH = ["beq", "bne", "blt", "bge", "ble", "bgt", "bltu", "bgeu"]

BASE_REG = 31       # reserved memory-safe base pointer
GP_REGS = list(range(1, 31))  # x1..x30, random general-purpose pool


def gen_program(seed, n_instrs=16, base_addr=32):
    rnd = random.Random(seed)
    lines = [f"addi x{BASE_REG}, x0, {base_addr}"]
    labels_at = {}  # instruction index -> label name, resolved into text at the end

    # Build a flat instruction list first (as dicts), then assign forward-only
    # branch/jump targets once every instruction's final index is known.
    instrs = []
    for _ in range(n_instrs):
        kind = rnd.choices(
            ["r", "i", "shift", "load", "store", "branch", "jal"],
            weights=[30, 20, 10, 12, 12, 10, 6],
        )[0]

        if kind == "r":
            mn = rnd.choice(R_TYPE)
            rd, rs1, rs2 = rnd.choice(GP_REGS), rnd.choice(GP_REGS), rnd.choice(GP_REGS)
            instrs.append(f"{mn} x{rd}, x{rs1}, x{rs2}")
        elif kind == "i":
            mn = rnd.choice(I_TYPE)
            rd, rs1 = rnd.choice(GP_REGS), rnd.choice(GP_REGS)
            imm = rnd.randint(-2048, 2047)
            instrs.append(f"{mn} x{rd}, x{rs1}, {imm}")
        elif kind == "shift":
            mn = rnd.choice(SHIFT_I)
            rd, rs1 = rnd.choice(GP_REGS), rnd.choice(GP_REGS)
            shamt = rnd.randint(0, 31)
            instrs.append(f"{mn} x{rd}, x{rs1}, {shamt}")
        elif kind == "load":
            mn = rnd.choice(["lb", "lh", "lw", "lbu", "lhu"])
            rd = rnd.choice(GP_REGS)
            width = {"lb": 1, "lbu": 1, "lh": 2, "lhu": 2, "lw": 4}[mn]
            max_off = 128 - base_addr - width
            off = rnd.randrange(0, max_off + 1, width) if max_off >= 0 else 0
            instrs.append(f"{mn} x{rd}, {off}(x{BASE_REG})")
        elif kind == "store":
            mn = rnd.choice(["sb", "sh", "sw"])
            rs2 = rnd.choice(GP_REGS)
            width = {"sb": 1, "sh": 2, "sw": 4}[mn]
            max_off = 128 - base_addr - width
            off = rnd.randrange(0, max_off + 1, width) if max_off >= 0 else 0
            instrs.append(f"{mn} x{rs2}, {off}(x{BASE_REG})")
        elif kind == "branch":
            mn = rnd.choice(BRANCH)
            rs1, rs2 = rnd.choice(GP_REGS), rnd.choice(GP_REGS)
            instrs.append(("branch", mn, rs1, rs2))
        elif kind == "jal":
            rd = rnd.choice(GP_REGS)
            instrs.append(("jal", rd))

    # Second pass: resolve forward-only branch/jal targets now that the
    # total instruction count (hence valid label positions) is known.
    out = [lines[0]]
    for idx, item in enumerate(instrs):
        cur_idx = idx + 1  # +1 for the leading addi
        if isinstance(item, tuple) and item[0] == "branch":
            _, mn, rs1, rs2 = item
            # Strictly forward; if this is the last instruction there's
            # nothing after it to target, so fall back to the trailing end
            # label instead of an invalid (empty) range.
            target_idx = rnd.randint(min(cur_idx + 1, len(instrs)), len(instrs))  # strictly forward, may be the end label
            out.append(f"{mn} x{rs1}, x{rs2}, __L{target_idx}")
            labels_at.setdefault(target_idx, f"__L{target_idx}")
        elif isinstance(item, tuple) and item[0] == "jal":
            _, rd = item
            # Strictly forward; if this is the last instruction there's
            # nothing after it to target, so fall back to the trailing end
            # label instead of an invalid (empty) range.
            target_idx = rnd.randint(min(cur_idx + 1, len(instrs)), len(instrs))
            out.append(f"jal x{rd}, __L{target_idx}")
            labels_at.setdefault(target_idx, f"__L{target_idx}")
        else:
            out.append(item)

        if (cur_idx + 1) in labels_at:
            out.append(labels_at[cur_idx + 1] + ":")

    if len(instrs) in labels_at:
        out.append(labels_at[len(instrs)] + ":")
    out.append("nop")
    out.append("nop")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--n", type=int, default=16)
    ap.add_argument("-o", "--output")
    args = ap.parse_args()
    text = gen_program(args.seed, args.n)
    if args.output:
        with open(args.output, "w") as f:
            f.write(text)
    else:
        print(text)
