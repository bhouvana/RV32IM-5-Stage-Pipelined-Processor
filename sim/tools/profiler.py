#!/usr/bin/env python3
"""
Performance profiler (docs/adr/0026-performance-profiler.md, Generation 1's
"performance profiler" item). Consumes the hardware performance-monitoring
CSRs docs/adr/0025-hpc-performance-csrs.md (Phase J) built but deliberately
left unconsumed: mcycle/minstret, and 9 generic mhpmcounter3-11/mhpmevent3-
11 pairs.

Sibling to sim/tools/bench_runner.py, not an extension of it -- bench_runner
varies RTL *parameters* across two runs of the same testbench-side counters;
this tool runs one config and extracts many *new* counters (real hardware
values, not testbench taps) for a single-run report. Counters are read via
real `csrrs` instructions the profiled kernel itself executes (confirmed via
AskUserQuestion during this phase's own scoping pass), appended as an
epilogue before each kernel's own mandatory `jal x0, halt` spin loop (docs/
adr/0011) -- this keeps the profiler meaningful on real FPGA hardware later,
not just in simulation, unlike a testbench-side hierarchical tap.

Only 9 physical mhpmcounters exist, but there are 19 possible event codes
(0=off, 1-9 this project's original events, 10-18 this phase's own 9-way
stall-cause breakdown) -- one run can't observe all of them. Two runs per
kernel, mirroring bench_runner.py's own "vary one axis, rerun, diff"
precedent:
  Run A (defaults): mcycle/minstret + mhpmcounter3-11 at their reset-default
    event wiring (1-9: branches, mispredicts, I$/D$ hit/miss, aggregate
    stall, interrupts, exceptions).
  Run B: mhpmevent3-11 reprogrammed (via `csrrwi`, BEFORE the kernel body
    runs so the whole kernel is observed) to events 10-18, the 9-way
    per-cause stall breakdown this phase's own RTL work (Phase K1) added.

Instruction mix is a STATIC opcode-class histogram (from the kernel's own
source text), not a new dynamic hardware counter -- a deliberate scope
choice (see the ADR), not an oversight: a dynamic, loop-aware mix would need
as many new event codes as opcode classes, on top of the 9 stall-cause ones
already added.

Usage: python profiler.py --iverilog-dir /c/iverilog/bin
       python profiler.py --iverilog-dir /c/iverilog/bin --json report.json
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asm import assemble, write_mem  # noqa: E402

# design/riscv_defs.vh
MCYCLE, MINSTRET = 0xB00, 0xB02
MHPMCOUNTER3_BASE = 0xB03
MHPMEVENT3_BASE = 0x323
NUM_HPM = 9

# Per-cause stall events this phase (K1) added, in mhpmcounter3-11's own
# array order once reprogrammed (index 0 -> mhpmcounter3, etc).
STALL_CAUSE_NAMES = ["hazard", "div", "mem", "fp", "float_lu", "itlb", "dtlb", "icache", "imem_wait"]
# Original reset-default events, same array order (mhpmcounter3-11).
ORIGINAL_EVENT_NAMES = ["branches_retired", "mispredicts", "icache_hit", "icache_miss",
                         "dcache_hit", "dcache_miss", "stall_aggregate", "interrupts", "exceptions"]

# Any free registers work for the epilogue's own dump -- the halt loop after
# it never reads anything, so there's no collision risk with whatever the
# kernel itself used for its own computation.
DUMP_REGS_A = list(range(19, 31))  # x19 (mcycle), x20 (minstret), x21-x29 (9 original events)
DUMP_REGS_B = list(range(19, 28))  # x19-x27 (9 stall-cause events)

# Rough static instruction-mix buckets -- a mnemonic-prefix classification,
# not a full decode (asm.py already fully decodes for real assembly;
# duplicating that here would be needless for a "what kind of instruction
# is this" histogram).
MIX_BUCKETS = [
    ("branch", ("beq", "bne", "blt", "bge", "ble", "bgt")),
    ("jump", ("jal", "jalr")),
    ("load", ("lw", "lh", "lb", "lhu", "lbu", "flw")),
    ("store", ("sw", "sh", "sb", "fsw")),
    ("muldiv", ("mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu")),
    ("fp", ("fadd.s", "fsub.s", "fmul.s", "fdiv.s", "fsqrt.s", "fmadd.s", "fmsub.s",
            "fnmadd.s", "fnmsub.s", "fcvt.w.s", "fcvt.wu.s", "fcvt.s.w", "fcvt.s.wu",
            "fmv.x.w", "fmv.w.x", "fclass.s", "feq.s", "flt.s", "fle.s", "fmin.s", "fmax.s")),
    ("csr", ("csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci")),
    ("system", ("ecall", "ebreak", "mret", "sret", "sfence.vma", "fence", "nop")),
]


def classify_mix(kernel_lines):
    counts = {}
    total = 0
    for raw in kernel_lines:
        line = raw.split("#", 1)[0].strip()
        if not line or line.endswith(":"):
            continue
        mn = re.split(r"[,\s]+", line)[0].lower()
        bucket = next((name for name, mns in MIX_BUCKETS if mn in mns), "alu")
        counts[bucket] = counts.get(bucket, 0) + 1
        total += 1
    return counts, total


def csrrs(rd, csr_addr):
    return f"csrrs x{rd}, {csr_addr:#x}, x0"


def csrrwi(csr_addr, uimm):
    return f"csrrwi x0, {csr_addr:#x}, {uimm}"


def insert_before_halt(lines, new_lines):
    """Insert new_lines just before the mandatory `halt:` label every test
    program in this repo ends with (docs/adr/0011) -- reused verbatim so
    the counter reads execute before the halt loop's own jal x0,halt is the
    first thing sim/tb/profiler_template.v's halt-detector sees, and labels
    (loop targets etc.) stay symbolic, so a shifted preamble never breaks
    an existing kernel's own control flow."""
    out = []
    inserted = False
    for line in lines:
        if not inserted and line.strip() == "halt:":
            out.extend(new_lines)
            inserted = True
        out.append(line)
    if not inserted:
        raise ValueError("kernel has no `halt:` label to insert the epilogue before")
    return out


def build_run_a(kernel_lines):
    epilogue = [csrrs(19, MCYCLE), csrrs(20, MINSTRET)]
    epilogue += [csrrs(21 + i, MHPMCOUNTER3_BASE + i) for i in range(NUM_HPM)]
    return insert_before_halt(kernel_lines, epilogue)


def build_run_b(kernel_lines):
    # Each mhpmcounterN keeps counting under its OLD (reset-default) event
    # for the few cycles its own reprogramming csrrwi takes to commit -- a
    # real contamination this phase's own calibration caught by running
    # (mhpmcounter5 briefly still counting icache_hit, its old default,
    # while its mhpmevent5 write is still in flight), not a hardware bug.
    # Zeroing every counter with `csrrw rd, csr, x0` (an unconditional
    # write, unlike csrrs/csrrc) right after all 9 reprogram writes removes
    # that residue before the kernel body's own real execution starts.
    preamble = [csrrwi(MHPMEVENT3_BASE + i, 10 + i) for i in range(NUM_HPM)]
    preamble += [f"csrrw x0, {(MHPMCOUNTER3_BASE + i):#x}, x0" for i in range(NUM_HPM)]
    epilogue = [csrrs(19 + i, MHPMCOUNTER3_BASE + i) for i in range(NUM_HPM)]
    return preamble + insert_before_halt(kernel_lines, epilogue)


def run_sim(lines, name, tag, work_dir, iverilog_bin, template, mem_size):
    words = assemble(lines)
    mem_path = os.path.join(work_dir, f"{tag}.mem")
    write_mem(words, mem_path, mem_size)

    # Generous flat margin: real hardware counter reads add a handful of
    # instructions, and (Phase K1's own tb_perf_stallcause_k1.v calibration)
    # a single fdiv.s can cost ~52 cycles alone -- sized well above any
    # per-instruction average these small kernels could plausibly hit.
    max_time = (len(words) * 80 + 2000) * 10

    dump_v = os.path.join(work_dir, f"{tag}.v")
    out_path = os.path.join(work_dir, f"{tag}.out").replace("\\", "/")
    init_file_rel = os.path.relpath(mem_path, start=os.getcwd()).replace("\\", "/")
    with open(template) as f:
        tpl = f.read()
    tpl = (tpl.replace("__INIT_FILE__", init_file_rel)
              .replace("__MAX_TIME__", str(max_time))
              .replace("__OUT_FILE__", out_path)
              .replace("__MEM_SIZE__", str(mem_size))
              .replace("__HAZARD_STRATEGY__", "0")
              .replace("__PIPELINE_PROFILE__", "0")
              .replace("__BRANCH_PREDICTOR__", "0")
              .replace("__CACHE_MODE__", "0")
              .replace("__MEM_LATENCY_I__", "0")
              .replace("__MEM_LATENCY_D__", "0"))
    with open(dump_v, "w") as f:
        f.write(tpl)

    vvp_path = os.path.join(work_dir, f"{tag}.vvp")
    iverilog_exe = os.path.join(iverilog_bin, "iverilog.exe") if iverilog_bin else "iverilog"
    vvp_exe = os.path.join(iverilog_bin, "vvp.exe") if iverilog_bin else "vvp"
    r = subprocess.run([iverilog_exe, "-g2005", "-I", "design", "-o", vvp_path, dump_v],
                        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{name}/{tag}: compile error: {r.stderr.strip()[:500]}")
    r = subprocess.run([vvp_exe, vvp_path], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out_path):
        raise RuntimeError(f"{name}/{tag}: simulation error: {r.stdout.strip()[:500]} {r.stderr.strip()[:500]}")

    with open(out_path) as f:
        vals = [int(l.strip()) for l in f if l.strip()]
    cycles = vals[0]
    regs = vals[1:33]
    return cycles, regs


def profile_kernel(name, prog_s, work_dir, iverilog_bin, template, mem_size):
    with open(prog_s) as f:
        kernel_lines = f.readlines()

    mix_counts, mix_total = classify_mix(kernel_lines)

    cycles_a, regs_a = run_sim(build_run_a(kernel_lines), name, f"{name}_a", work_dir, iverilog_bin, template, mem_size)
    mcycle, minstret = regs_a[19], regs_a[20]
    original = {ORIGINAL_EVENT_NAMES[i]: regs_a[21 + i] for i in range(NUM_HPM)}

    cycles_b, regs_b = run_sim(build_run_b(kernel_lines), name, f"{name}_b", work_dir, iverilog_bin, template, mem_size)
    stall_causes = {STALL_CAUSE_NAMES[i]: regs_b[19 + i] for i in range(NUM_HPM)}

    ipc = minstret / mcycle if mcycle else 0.0
    branches, mispredicts = original["branches_retired"], original["mispredicts"]
    branch_accuracy = (1.0 - mispredicts / branches) if branches else None
    ih, im = original["icache_hit"], original["icache_miss"]
    icache_hit_rate = ih / (ih + im) if (ih + im) else None
    dh, dm = original["dcache_hit"], original["dcache_miss"]
    dcache_hit_rate = dh / (dh + dm) if (dh + dm) else None
    stall_pct = original["stall_aggregate"] / mcycle if mcycle else 0.0
    stall_cause_sum = sum(stall_causes.values())

    return {
        "name": name,
        "cycles_a": cycles_a, "cycles_b": cycles_b,
        "mcycle": mcycle, "minstret": minstret,
        "ipc": ipc, "cpi": (1.0 / ipc) if ipc else None,
        "branch_accuracy": branch_accuracy,
        "icache_hit_rate": icache_hit_rate, "dcache_hit_rate": dcache_hit_rate,
        "stall_pct": stall_pct,
        "original_events": original,
        "stall_causes": stall_causes,
        "stall_cause_sum": stall_cause_sum,
        "instruction_mix": mix_counts, "instruction_mix_total": mix_total,
    }


def fmt_pct(x):
    return f"{100.0 * x:.1f}%" if x is not None else "n/a"


def print_report(results):
    for r in results:
        print(f"=== {r['name']} ===")
        print(f"  cycles={r['mcycle']:<8} instructions(minstret)={r['minstret']:<8} "
              f"IPC={r['ipc']:.3f}  CPI={r['cpi']:.3f}" if r["cpi"] else f"  cycles={r['mcycle']}")
        print(f"  branch accuracy: {fmt_pct(r['branch_accuracy'])}  "
              f"I$ hit rate: {fmt_pct(r['icache_hit_rate'])}  D$ hit rate: {fmt_pct(r['dcache_hit_rate'])}")
        print(f"  stall cycles: {fmt_pct(r['stall_pct'])} of total ({r['original_events']['stall_aggregate']} cycles)")
        print("  stall breakdown (per-cause / aggregate):")
        agg = r["original_events"]["stall_aggregate"] or 1
        for cause, count in r["stall_causes"].items():
            print(f"    {cause:<10} {count:<6} ({fmt_pct(count / agg)})")
        print(f"  instruction mix (static, {r['instruction_mix_total']} instructions):")
        for bucket, count in sorted(r["instruction_mix"].items(), key=lambda kv: -kv[1]):
            print(f"    {bucket:<10} {count:<4} ({fmt_pct(count / r['instruction_mix_total'])})")
        print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iverilog-dir", default=None)
    ap.add_argument("--programs-dir", default="sim/benchmarks")
    ap.add_argument("--json", default=None, help="write the full report to this path as JSON")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    template = os.path.join(here, "..", "tb", "profiler_template.v")

    progs = sorted(glob.glob(os.path.join(args.programs_dir, "bench_*.s")))
    if not progs:
        print(f"No bench_*.s programs found under {args.programs_dir}")
        sys.exit(1)

    results = []
    with tempfile.TemporaryDirectory() as work_dir:
        for prog_s in progs:
            name = os.path.splitext(os.path.basename(prog_s))[0]
            # Larger than bench_runner.py's own MEM_SIZE_OVERRIDES -- this
            # tool's epilogue/preamble adds ~11-18 real instructions on top
            # of each kernel's own body, which the small 128-byte default
            # (bench_runner.py's own baseline) has no headroom for.
            mem_size = 1024 if name == "bench_bubble_sort" else 256
            try:
                results.append(profile_kernel(name, prog_s, work_dir, args.iverilog_dir, template, mem_size))
            except RuntimeError as e:
                print(f"FAIL  {e}")

    print_report(results)

    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=2)
        print(f"wrote {args.json}")

    if len(results) != len(progs):
        sys.exit(1)


if __name__ == "__main__":
    main()
