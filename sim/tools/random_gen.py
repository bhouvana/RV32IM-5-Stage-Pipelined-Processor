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


def gen_program(seed, n_instrs=16, base_addr=32, mem_size=128, interrupt=None):
    """interrupt: None (default -- every existing caller's behavior,
    completely unaffected), or one of "timer"/"uart" to additionally arm
    that interrupt source and inject it somewhere during the random body.
    docs/adr/0020-soc-integration.md (Phase D10).

    The injected handler is deliberately architecturally inert -- `csrrw
    x0, mie, x0` (disarm both sources, preventing an immediate re-trigger
    once mstatus.MIE is restored -- mip is a real level signal on the RTL
    side, not edge-triggered) then `mret`, touching no GP/FP register and
    no memory. This is *why* the RTL and the ISS's own externally-scheduled
    firing point (see iss.py's schedule_interrupt) don't need to agree on
    the exact instruction boundary the interrupt lands on: since nothing
    the handler does is part of the compared final state, and D9's own
    redirect logic already guarantees no instruction is skipped or
    re-executed, the final architectural state after the whole program
    runs is identical regardless of exactly which cycle interrupted it --
    only *that* it fires (at most once) somewhere before the program's own
    halt loop is what this generator arranges, not precisely *when*. The
    RTL's own timing (a real, generously-margined MTIMECMP for the timer
    source, or the test rig's own driven UART byte for the external source)
    only needs to land somewhere in that same broad window, not at a
    specific cycle.
    """
    # Budget check, not just documentation: InstructionMemory is mem_size
    # bytes -- 1 (base addi) + 2*len(FLOAT_SEED_BITS) (seeding) + n_instrs +
    # 1 (trailing jal), plus interrupt mode's own prefix+handler, must not
    # exceed that, or asm.py's write_mem raises before this is ever a
    # silent problem.
    interrupt_prefix_cost = 0
    if interrupt is not None:
        # Common: addi+csrrw(mtvec)=2, addi+csrrw(mie)=2, csrrsi(mstatus)=1
        # -> 5. Timer-specific: TIMER_BASE's lui+addi(2), the mtimecmp
        # constant (up to 2, lui+addi) + its sw(1) -> up to 5. UART-specific:
        # MMIO_BASE's lui(1) + enable-value addi(1) + its sw(1) -> 3. Handler
        # (both): csrrw(mie<-0) + mret -> 2.
        interrupt_prefix_cost = 5 + (5 if interrupt == "timer" else 3) + 2
    budget = 1 + 2 * len(FLOAT_SEED_BITS) + n_instrs + 1 + interrupt_prefix_cost
    if budget > mem_size // 4:
        raise ValueError(f"n_instrs={n_instrs} would overflow the {mem_size}-byte budget "
                          f"(everything else already uses {budget - n_instrs} instructions)")
    rnd = random.Random(seed)
    interrupt_k = rnd.randint(1, n_instrs) if interrupt is not None else None
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

    # docs/adr/0020-soc-integration.md (Phase D10). mstatus/mepc/mcause are
    # mutated by the interrupt itself (mstatus's MIE/MPIE swap at trap
    # entry/mret, mepc, mcause) -- since the RTL's real hardware timing and
    # the ISS's own externally-scheduled firing point deliberately don't
    # agree on the exact instruction boundary (see this function's own
    # docstring), a random instruction that happens to *read* one of these
    # three CSRs would observe different values on either side of
    # wherever each side's interrupt actually landed, a genuine and
    # unavoidable divergence -- not a bug in the redirect logic itself.
    # mtvec/mscratch are untouched by trap/mret and stay safe. Same
    # "exclude what can't be made safe to compare" principle this
    # generator already applies to ecall/ebreak/mret/illegal instructions
    # (see the module docstring), just for CSR *reads* instead of control
    # flow.
    csr_names_pool = CSR_NAMES if interrupt is None else [
        n for n in CSR_NAMES if n not in ("mstatus", "mepc", "mcause")]

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
            max_off = mem_size - base_addr - width
            off = rnd.randrange(0, max_off + 1, width) if max_off >= 0 else 0
            instrs.append(f"{mn} x{rd}, {off}(x{BASE_REG})")
        elif kind == "store":
            mn = rnd.choice(["sb", "sh", "sw"])
            rs2 = rnd.choice(GP_REGS)
            width = {"sb": 1, "sh": 2, "sw": 4}[mn]
            max_off = mem_size - base_addr - width
            off = rnd.randrange(0, max_off + 1, width) if max_off >= 0 else 0
            instrs.append(f"{mn} x{rs2}, {off}(x{BASE_REG})")
        elif kind == "branch":
            mn = rnd.choice(BRANCH)
            rs1, rs2 = rnd.choice(GP_REGS), rnd.choice(GP_REGS)
            instrs.append(("branch", mn, rs1, rs2))
        elif kind == "csr":
            csr = rnd.choice(csr_names_pool)
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
            max_off = mem_size - base_addr - 4
            off = rnd.randrange(0, max_off + 1, 4) if max_off >= 0 else 0
            instrs.append(f"flw f{rd}, {off}(x{BASE_REG})")
        elif kind == "fstore":
            rs2 = rnd.choice(FREGS)
            max_off = mem_size - base_addr - 4
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

    if interrupt is None:
        return "\n".join(out) + "\n", None

    # docs/adr/0020-soc-integration.md (Phase D10). Prefix arms the chosen
    # source and enables interrupts; the handler (placed after the halt
    # loop, only ever reached via a real hardware redirect, never by
    # straight-line fall-through) is architecturally inert -- see this
    # function's own docstring for why. `mtvec` is patched in once the
    # prefix's own final instruction count is known -- same "placeholder,
    # then substitute the resolved address" approach the D9 directed test
    # programs used.
    core_instr_count = sum(1 for l in out if not l.rstrip().endswith(":"))
    if interrupt == "timer":
        mtimecmp_est = 100 + interrupt_k * 10  # generous, not precise -- see docstring
        prefix = [
            "lui   x2, 0x10000",
            "addi  x2, x2, 16",       # x2 = TIMER_BASE
            "addi  x5, x0, __MTVEC_PLACEHOLDER__",
            "csrrw x0, mtvec, x5",
            "addi  x6, x0, 128",      # MIE_MTIE_BIT
            "csrrw x0, mie, x6",
        ]
        prefix.extend(const_to_reg_instrs(7, mtimecmp_est))
        prefix.append("sw    x7, 4(x2)")
        prefix.append("csrrsi x0, mstatus, 8")
        cause = 0x80000007
    elif interrupt == "uart":
        prefix = [
            "lui   x1, 0x10000",      # x1 = UART_BASE
            "addi  x5, x0, __MTVEC_PLACEHOLDER__",
            "csrrw x0, mtvec, x5",
            "addi  x6, x0, -2048",    # MIE_MEIE_BIT, sign-extended (harmless -- CSR.v's mie_masked only reads bits 7/11)
            "csrrw x0, mie, x6",
            "addi  x8, x0, 1",
            "sw    x8, 12(x1)",       # CONTROL.rx_irq_enable <- 1
            "csrrsi x0, mstatus, 8",
        ]
        cause = 0x8000000B
    else:
        raise ValueError(f"unknown interrupt source {interrupt!r}")

    prefix_instr_count = sum(1 for l in prefix if not l.rstrip().endswith(":"))
    handler_addr = (prefix_instr_count + core_instr_count) * 4
    prefix = [l.replace("__MTVEC_PLACEHOLDER__", str(handler_addr)) for l in prefix]
    handler = ["handler:", "csrrw x0, mie, x0", "mret"]

    full = prefix + out + handler
    interrupt_info = {"after": interrupt_k, "cause": cause}
    return "\n".join(full) + "\n", interrupt_info


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--n", type=int, default=16)
    ap.add_argument("--mem-size", type=int, default=128)
    ap.add_argument("--interrupt", choices=["timer", "uart"], default=None)
    ap.add_argument("-o", "--output")
    args = ap.parse_args()
    text, interrupt_info = gen_program(args.seed, args.n, mem_size=args.mem_size, interrupt=args.interrupt)
    if interrupt_info is not None:
        print(f"# interrupt scheduled after instruction {interrupt_info['after']}, "
              f"cause={interrupt_info['cause']:#010x}")
    if args.output:
        with open(args.output, "w") as f:
            f.write(text)
    else:
        print(text)
