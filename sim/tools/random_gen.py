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
  - CSR read/write (`csrrw`/`csrrs`/`csrrc`(+i)) is included in the mix --
    pure register/CSR data movement, no control-flow risk. `ecall`/`ebreak`/
    `mret`/deliberately-illegal instructions are deliberately NOT generated:
    unlike CSR reads/writes, those redirect control flow to mtvec/mepc,
    which would need real safety machinery (a guaranteed-safe mtvec, trap-
    recursion tracking) to keep programs forward-only and terminating --
    disproportionate for what's already covered by directed tests
    (ecall_trap.s, ebreak_trap.s, illegal_instr.s, aluctl_illegal.s,
    mret_return.s). See docs/ROADMAP.md / ARCHITECTURE.md sec 15.
  - docs/adr/0019-f-extension.md (Phase C9): float instructions are mixed
    in too, no new safety machinery needed -- flw/fsw reuse the same
    BASE_REG-relative safe-addressing pattern as lw/sw (the *address*
    register is always integer, even for fsw/flw), and NaN/Inf/subnormal/
    overflow/underflow results are extra coverage exactly like integer
    div-by-zero above: design/FALU.v & friends and sim/tools/iss.py's
    float model both implement the same spec-mandated results (including
    this core's own documented subnormal-flush-to-zero deviation), so
    hitting those cases is exactly the point, not a hazard. A handful of
    "interesting" float32 bit patterns (0, -0, 1.0, +/-inf, NaN,
    subnormal, near the overflow/underflow boundary) are seeded into a
    subset of float registers up front (construction needs a scratch
    integer register, GP_REGS is reused for this transiently -- no
    permanent reservation needed, since seeding happens once, before any
    randomly generated instruction) precisely so those edge cases show up
    in the arithmetic mix at a much higher rate than uniform-random 32-bit
    patterns would produce on their own (most random bit patterns land on
    unremarkable finite normals).
"""
import random

R_TYPE = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
          "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
I_TYPE = ["addi", "slti", "sltiu", "xori", "ori", "andi"]  # slli/srli/srai handled separately (shamt, not full imm)
SHIFT_I = ["slli", "srli", "srai"]
BRANCH = ["beq", "bne", "blt", "bge", "ble", "bgt", "bltu", "bgeu"]
CSR_REG_OP = ["csrrw", "csrrs", "csrrc"]
CSR_IMM_OP = ["csrrwi", "csrrsi", "csrrci"]
CSR_NAMES = ["mstatus", "mtvec", "mscratch", "mepc", "mcause"]

BASE_REG = 31       # reserved memory-safe base pointer
GP_REGS = list(range(1, 31))  # x1..x30, random general-purpose pool

# docs/adr/0019-f-extension.md (Phase C9). No reserved index -- FRegister.v
# hardwires nothing, every one of f0-f31 is fair game.
FREGS = list(range(0, 32))
FP_ARITH = ["fadd.s", "fsub.s", "fmul.s", "fdiv.s"]  # 2-operand + optional rm
FP_SGNJ = ["fsgnj.s", "fsgnjn.s", "fsgnjx.s"]
FP_MINMAX = ["fmin.s", "fmax.s"]
FP_CMP = ["feq.s", "flt.s", "fle.s"]  # writes the INTEGER file
FP_CVT_TO_INT = ["fcvt.w.s", "fcvt.wu.s"]  # writes the INTEGER file
FP_CVT_FROM_INT = ["fcvt.s.w", "fcvt.s.wu"]  # reads the INTEGER file
FMADD_FAMILY = ["fmadd.s", "fmsub.s", "fnmsub.s", "fnmadd.s"]
RM_NAMES = ["rne", "rtz", "rdn", "rup", "rmm", "dyn"]
FCSR_NAMES = ["fflags", "frm", "fcsr"]  # via asm.py's raw-address fallback (no name table entry needed)
FCSR_ADDR = {"fflags": "0x1", "frm": "0x2", "fcsr": "0x3"}

# A curated set of "interesting" float32 bit patterns -- see this module's
# own docstring for why these are seeded explicitly rather than relying on
# uniform-random 32-bit patterns to stumble into them. Kept short (each
# entry costs 2 instructions -- lui + fmv.w.x, all chosen with zero low-12
# bits specifically to avoid a 3rd addi instruction) since InstructionMemory
# is only 128 bytes (32 instructions) end to end, shared with the leading
# base-pointer setup, the trailing halt loop, and n_instrs of actual random
# instructions -- see gen_program's own budget comment.
FLOAT_SEED_BITS = [
    0x00000000,  # +0.0
    0x3F800000,  # 1.0
    0xBF800000,  # -1.0
    0x7F800000,  # +infinity
    0x7FC00000,  # canonical quiet NaN
    0x00400000,  # a subnormal (input flush-to-zero coverage)
]


def const_to_reg_instrs(rd, bits32):
    # Standard "build an arbitrary 32-bit constant" idiom: lui supplies the
    # upper 20 bits, addi's sign-extended 12-bit immediate corrects the
    # lower 12 -- when the low 12 bits' own top bit is set, addi would
    # sign-extend them negative, so the lui half is pre-incremented by 1 to
    # compensate (the classic lui+addi construction every RISC-V assembler
    # uses for li).
    lo = bits32 & 0xFFF
    hi = (bits32 >> 12) & 0xFFFFF
    if lo & 0x800:
        hi = (hi + 1) & 0xFFFFF
    lines = [f"lui x{rd}, {hi:#x}"]
    if lo != 0:
        lo_signed = lo - 0x1000 if (lo & 0x800) else lo
        lines.append(f"addi x{rd}, x{rd}, {lo_signed}")
    return lines


def gen_program(seed, n_instrs=16, base_addr=32):
    # Budget check, not just documentation: InstructionMemory is 128 bytes
    # (32 instructions) -- 1 (base addi) + 2*len(FLOAT_SEED_BITS) (seeding)
    # + n_instrs + 1 (trailing jal) must not exceed that, or asm.py's
    # write_mem raises before this is ever a silent problem.
    budget = 1 + 2 * len(FLOAT_SEED_BITS) + n_instrs + 1
    if budget > 32:
        raise ValueError(f"n_instrs={n_instrs} would overflow the 32-instruction budget "
                          f"(base+seed+jal already use {budget - n_instrs})")
    rnd = random.Random(seed)
    lines = [f"addi x{BASE_REG}, x0, {base_addr}"]
    # docs/adr/0019-f-extension.md (Phase C9): seed a subset of float
    # registers with curated "interesting" bit patterns before any
    # randomly generated instruction runs -- x30 is scratch here only
    # (see this module's own docstring for why no permanent reservation
    # is needed). Every float register not seeded here just starts at its
    # reset default (0.0), itself a perfectly good input. Kept as a
    # separate static block (not folded into `lines`, which the label-
    # resolution pass below only ever reads index 0 of) -- unconditional,
    # sequential, and never itself a branch/jal target, so it can just be
    # spliced in after the base-pointer line with no index bookkeeping.
    seed_lines = []
    for i, bits in enumerate(FLOAT_SEED_BITS):
        fr = i + 1  # f1, f2, ... -- f0 deliberately left at its 0.0 reset default
        seed_lines.extend(const_to_reg_instrs(30, bits))
        seed_lines.append(f"fmv.w.x f{fr}, x30")
    labels_at = {}  # instruction index -> label name, resolved into text at the end

    # Build a flat instruction list first (as dicts), then assign forward-only
    # branch/jump targets once every instruction's final index is known.
    instrs = []
    for _ in range(n_instrs):
        kind = rnd.choices(
            ["r", "i", "shift", "load", "store", "branch", "jal", "csr",
             "fp_arith", "fp_sqrt", "fp_sgnj", "fp_minmax", "fp_cmp",
             "fp_cvt_to_int", "fp_cvt_from_int", "fp_madd", "fload", "fstore", "fcsr"],
            weights=[24, 16, 8, 10, 10, 8, 5, 6,
                     10, 4, 4, 4, 4,
                     4, 4, 6, 6, 6, 4],
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
        elif kind == "csr":
            csr = rnd.choice(CSR_NAMES)
            rd = rnd.choice(GP_REGS)
            if rnd.random() < 0.5:
                mn = rnd.choice(CSR_REG_OP)
                rs1 = rnd.choice(GP_REGS)
                instrs.append(f"{mn} x{rd}, {csr}, x{rs1}")
            else:
                mn = rnd.choice(CSR_IMM_OP)
                uimm = rnd.randint(0, 31)  # zero-extended 5-bit field, see ImmGen.v/Control.v
                instrs.append(f"{mn} x{rd}, {csr}, {uimm}")
        elif kind == "jal":
            rd = rnd.choice(GP_REGS)
            instrs.append(("jal", rd))
        elif kind == "fp_arith":
            mn = rnd.choice(FP_ARITH)
            rd, rs1, rs2 = rnd.choice(FREGS), rnd.choice(FREGS), rnd.choice(FREGS)
            rm = rnd.choice(RM_NAMES)
            instrs.append(f"{mn} f{rd}, f{rs1}, f{rs2}, {rm}")
        elif kind == "fp_sqrt":
            rd, rs1 = rnd.choice(FREGS), rnd.choice(FREGS)
            rm = rnd.choice(RM_NAMES)
            instrs.append(f"fsqrt.s f{rd}, f{rs1}, {rm}")
        elif kind == "fp_sgnj":
            mn = rnd.choice(FP_SGNJ)
            rd, rs1, rs2 = rnd.choice(FREGS), rnd.choice(FREGS), rnd.choice(FREGS)
            instrs.append(f"{mn} f{rd}, f{rs1}, f{rs2}")
        elif kind == "fp_minmax":
            mn = rnd.choice(FP_MINMAX)
            rd, rs1, rs2 = rnd.choice(FREGS), rnd.choice(FREGS), rnd.choice(FREGS)
            instrs.append(f"{mn} f{rd}, f{rs1}, f{rs2}")
        elif kind == "fp_cmp":
            mn = rnd.choice(FP_CMP)
            rd, rs1, rs2 = rnd.choice(GP_REGS), rnd.choice(FREGS), rnd.choice(FREGS)
            instrs.append(f"{mn} x{rd}, f{rs1}, f{rs2}")
        elif kind == "fp_cvt_to_int":
            mn = rnd.choice(FP_CVT_TO_INT)
            rd, rs1 = rnd.choice(GP_REGS), rnd.choice(FREGS)
            rm = rnd.choice(RM_NAMES)
            instrs.append(f"{mn} x{rd}, f{rs1}, {rm}")
        elif kind == "fp_cvt_from_int":
            mn = rnd.choice(FP_CVT_FROM_INT)
            rd, rs1 = rnd.choice(FREGS), rnd.choice(GP_REGS)
            rm = rnd.choice(RM_NAMES)
            instrs.append(f"{mn} f{rd}, x{rs1}, {rm}")
        elif kind == "fp_madd":
            mn = rnd.choice(FMADD_FAMILY)
            rd, rs1, rs2, rs3 = rnd.choice(FREGS), rnd.choice(FREGS), rnd.choice(FREGS), rnd.choice(FREGS)
            rm = rnd.choice(RM_NAMES)
            instrs.append(f"{mn} f{rd}, f{rs1}, f{rs2}, f{rs3}, {rm}")
        elif kind == "fload":
            rd = rnd.choice(FREGS)
            max_off = 128 - base_addr - 4
            off = rnd.randrange(0, max_off + 1, 4) if max_off >= 0 else 0
            instrs.append(f"flw f{rd}, {off}(x{BASE_REG})")
        elif kind == "fstore":
            rs2 = rnd.choice(FREGS)
            max_off = 128 - base_addr - 4
            off = rnd.randrange(0, max_off + 1, 4) if max_off >= 0 else 0
            instrs.append(f"fsw f{rs2}, {off}(x{BASE_REG})")
        elif kind == "fcsr":
            csr = FCSR_ADDR[rnd.choice(FCSR_NAMES)]
            rd = rnd.choice(GP_REGS)
            if rnd.random() < 0.5:
                mn = rnd.choice(CSR_REG_OP)
                rs1 = rnd.choice(GP_REGS)
                instrs.append(f"{mn} x{rd}, {csr}, x{rs1}")
            else:
                mn = rnd.choice(CSR_IMM_OP)
                uimm = rnd.randint(0, 31)
                instrs.append(f"{mn} x{rd}, {csr}, {uimm}")

    # Second pass: resolve forward-only branch/jal targets now that the
    # total instruction count (hence valid label positions) is known.
    out = [lines[0]] + seed_lines
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
    # Spin here instead of running off the end into instruction memory's
    # zero-filled remainder -- opcode 0000000 is not a valid instruction and
    # (correctly, after docs/adr/0011-csr-and-exceptions.md) now traps.
    out.append("__halt:")
    out.append("jal x0, __halt")
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
