#!/usr/bin/env python3
"""
Benchmark runner (docs/ROADMAP.md Phase 10). Runs each sim/benchmarks/bench_*.s
kernel through both the independent ISS (sim/tools/iss.py, for instruction
count and a correctness cross-check -- same reference model V-4's random
testing already trusts) and the real RTL (Icarus Verilog, for cycle count),
and reports cycles / instructions / IPC per benchmark.

This is NOT CoreMark/Dhrystone: those need a real C compiler targeting this
core, and no RISC-V toolchain is available in this environment (checked
directly, not assumed -- see docs/adr, no ADR filed since this is pure
tooling, but the check is worth recording: `which riscv64-unknown-elf-gcc`
etc. all fail). These are small, hand-written kernels in this core's own
assembly dialect instead -- real, but not standardized, performance data.
Useful for relative comparisons between this core's own changes (e.g.
"did the MEM-stage retiming change memory-bound IPC"), not for comparing
against other cores' published CoreMark scores.

Cycle count is measured as the cycle EX first resolves the program's own
`jal x0, self` halt loop (see sim/tb/bench_template.v) -- a few cycles
before the pipeline fully drains, but that offset is constant across every
benchmark, so relative comparisons between them are unaffected.

Also doubles as the "compare hazard strategies" tool docs/ROADMAP.md Phase 6
named as a research-platform goal (docs/adr/0016-swappable-hazard-strategy.md):
--compare-strategies runs every benchmark under both riscvpipeline.v's
HAZARD_STRATEGY=0 (forwarding, the default/original design) and =1
(stall-only, no forwarding) and reports the cycle-count delta.

Usage: python bench_runner.py --iverilog-dir /c/iverilog/bin
       python bench_runner.py --compare-strategies --iverilog-dir /c/iverilog/bin
"""
import argparse
import glob
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from iss import ISS  # noqa: E402

# Per-benchmark memory size override (bytes; shared by instruction and data
# memory, see design/riscvpipeline.v's MEM_SIZE_BYTES). Default 128 (every
# other test program's assumption) unless a kernel needs more room --
# bench_bubble_sort.s does (docs/adr/0015 is what makes this a one-line
# runner change instead of an RTL one).
MEM_SIZE_OVERRIDES = {
    "bench_bubble_sort": 512,
}

# Expected x10/a0 result per benchmark, for the correctness cross-check
# (independent of the ISS -- these are hand-computed from what each kernel
# is actually supposed to do, the same way directed tests' expected values
# are, not derived from either model).
EXPECTED_X10 = {
    "bench_fib": 832040,           # fib(30)
    "bench_sum_array": 136,        # 1+2+...+16
    "bench_bubble_sort": 1,        # smallest of {1..6} after sorting ascending
}


def load_words(mem_path):
    with open(mem_path) as f:
        lines = [l.strip() for l in f if l.strip()]
    words = []
    for i in range(0, len(lines), 4):
        b = lines[i:i + 4]
        if len(b) < 4:
            break
        words.append(int(b[0] + b[1] + b[2] + b[3], 2))
    return words


def run_bench(name, prog_s, work_dir, iverilog_bin, template, mem_size, hazard_strategy=0):
    here = os.path.dirname(os.path.abspath(__file__))
    prog_mem = os.path.join(work_dir, f"{name}.mem")
    asm_py = os.path.join(here, "asm.py")
    r = subprocess.run([sys.executable, asm_py, prog_s, "-o", prog_mem, "--size", str(mem_size)],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return None, f"assembler error: {r.stderr.strip()}"

    words = load_words(prog_mem)
    iss = ISS(mem_size=mem_size)
    try:
        instrs = iss.run(words, max_steps=200000)
    except Exception as e:  # noqa: BLE001
        return None, f"ISS error: {e}"

    expected = EXPECTED_X10.get(name)
    if expected is not None and iss.regs[10] != expected:
        return None, f"ISS correctness check failed: x10={iss.regs[10]}, expected {expected}"

    # Strategy 1 (stall-only) can only ever take *more* cycles per
    # instruction than strategy 0 (forwarding) -- generous margin, not
    # tuned per-strategy.
    max_time = (instrs * 60 + 500) * 10
    dump_v = os.path.join(work_dir, f"{name}_hs{hazard_strategy}.v")
    out_path = os.path.join(work_dir, f"{name}_hs{hazard_strategy}.out").replace("\\", "/")
    init_file_rel = os.path.relpath(prog_mem, start=os.getcwd()).replace("\\", "/")
    with open(template) as f:
        tpl = f.read()
    tpl = (tpl.replace("__INIT_FILE__", init_file_rel)
              .replace("__MAX_TIME__", str(max_time))
              .replace("__OUT_FILE__", out_path)
              .replace("__MEM_SIZE__", str(mem_size))
              .replace("__HAZARD_STRATEGY__", str(hazard_strategy)))
    with open(dump_v, "w") as f:
        f.write(tpl)

    vvp_path = os.path.join(work_dir, f"{name}_hs{hazard_strategy}.vvp")
    iverilog_exe = os.path.join(iverilog_bin, "iverilog.exe") if iverilog_bin else "iverilog"
    vvp_exe = os.path.join(iverilog_bin, "vvp.exe") if iverilog_bin else "vvp"
    r = subprocess.run([iverilog_exe, "-g2005", "-I", "design", "-o", vvp_path, dump_v],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return None, f"compile error: {r.stderr.strip()[:500]}"
    r = subprocess.run([vvp_exe, vvp_path], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out_path):
        return None, f"simulation error: {r.stdout.strip()[:500]} {r.stderr.strip()[:500]}"

    with open(out_path) as f:
        cycles = int(f.read().strip())

    return {"instructions": instrs, "cycles": cycles, "ipc": instrs / cycles}, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iverilog-dir", default=None)
    ap.add_argument("--programs-dir", default="sim/benchmarks")
    ap.add_argument("--hazard-strategy", type=int, default=0, choices=[0, 1],
                     help="riscvpipeline.v's HAZARD_STRATEGY (docs/adr/0016): 0=forwarding (default), 1=stall-only")
    ap.add_argument("--compare-strategies", action="store_true",
                     help="run every benchmark under both strategies and report the delta")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    template = os.path.join(here, "..", "tb", "bench_template.v")

    progs = sorted(glob.glob(os.path.join(args.programs_dir, "bench_*.s")))
    if not progs:
        print(f"No bench_*.s programs found under {args.programs_dir}")
        sys.exit(1)

    strategies = (0, 1) if args.compare_strategies else (args.hazard_strategy,)
    all_results = {s: [] for s in strategies}
    with tempfile.TemporaryDirectory() as work_dir:
        for strategy in strategies:
            if args.compare_strategies:
                print(f"--- HAZARD_STRATEGY={strategy} ({'forwarding' if strategy == 0 else 'stall-only'}) ---")
            for prog_s in progs:
                name = os.path.splitext(os.path.basename(prog_s))[0]
                mem_size = MEM_SIZE_OVERRIDES.get(name, 128)
                result, err = run_bench(name, prog_s, work_dir, args.iverilog_dir, template, mem_size, strategy)
                if err:
                    print(f"FAIL  {name}: {err}")
                    all_results[strategy].append((name, None))
                else:
                    print(f"{name:<20} instructions={result['instructions']:<6} "
                          f"cycles={result['cycles']:<6} IPC={result['ipc']:.3f}")
                    all_results[strategy].append((name, result))
            print()

    if args.compare_strategies:
        print("=== comparison: forwarding (HS=0) vs. stall-only (HS=1) ===")
        by_name_0 = dict(all_results[0])
        by_name_1 = dict(all_results[1])
        for name, r0 in all_results[0]:
            r1 = by_name_1.get(name)
            if r0 is None or r1 is None:
                print(f"{name:<20} (incomplete, see FAIL above)")
                continue
            delta = r1["cycles"] - r0["cycles"]
            pct = 100.0 * delta / r0["cycles"]
            print(f"{name:<20} cycles: {r0['cycles']:<6} -> {r1['cycles']:<6}  "
                  f"({delta:+d}, {pct:+.1f}%)   IPC: {r0['ipc']:.3f} -> {r1['ipc']:.3f}")

    failed = [n for results in all_results.values() for n, r in results if r is None]
    total = sum(len(results) for results in all_results.values())
    if failed:
        print(f"\n=== {len(failed)}/{total} benchmark run(s) FAILED: {', '.join(failed)} ===")
        sys.exit(1)
    print(f"\n=== {total}/{total} benchmark run(s) completed cleanly ===")


if __name__ == "__main__":
    main()
