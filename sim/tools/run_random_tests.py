#!/usr/bin/env python3
"""
Constrained-random cross-check driver (docs/ROADMAP.md V-4). For each of N
seeds: generate a random program (random_gen.py), compute expected final
architectural state with the reference model (iss.py), run the same program
through the real RTL simulation (Icarus Verilog), and compare.

Usage: python run_random_tests.py --count 30 --iverilog-dir /c/iverilog/bin
Must be run from the repository root.
"""
import argparse
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from iss import ISS  # noqa: E402
from random_gen import gen_program  # noqa: E402


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


def run_one(seed, n_instrs, work_dir, iverilog_bin, template):
    prog_s = os.path.join(work_dir, f"r{seed}.s")
    prog_mem = os.path.join(work_dir, f"r{seed}.mem")
    with open(prog_s, "w") as f:
        f.write(gen_program(seed, n_instrs))

    asm_py = os.path.join(os.path.dirname(os.path.abspath(__file__)), "asm.py")
    r = subprocess.run([sys.executable, asm_py, prog_s, "-o", prog_mem], capture_output=True, text=True)
    if r.returncode != 0:
        return False, f"assembler error: {r.stderr.strip()}"

    words = load_words(prog_mem)
    iss = ISS()
    try:
        iss.run(words, max_steps=5000)
    except Exception as e:  # noqa: BLE001
        return False, f"ISS error: {e}"

    # Multi-cycle divisions dominate runtime -- budget generously: every
    # instruction could in principle be a division (~33 cycles), plus margin.
    max_time = (len(words) * 40 + 200) * 10
    dump_v = os.path.join(work_dir, f"r{seed}.v")
    out_path = os.path.join(work_dir, f"r{seed}.out").replace("\\", "/")
    init_file_rel = os.path.relpath(prog_mem, start=os.getcwd()).replace("\\", "/")
    with open(template) as f:
        tpl = f.read()
    tpl = tpl.replace("__INIT_FILE__", init_file_rel).replace("__MAX_TIME__", str(max_time)).replace("__OUT_FILE__", out_path)
    with open(dump_v, "w") as f:
        f.write(tpl)

    vvp_path = os.path.join(work_dir, f"r{seed}.vvp")
    iverilog_exe = os.path.join(iverilog_bin, "iverilog.exe") if iverilog_bin else "iverilog"
    vvp_exe = os.path.join(iverilog_bin, "vvp.exe") if iverilog_bin else "vvp"
    r = subprocess.run([iverilog_exe, "-g2005", "-I", "design", "-o", vvp_path, dump_v],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return False, f"compile error: {r.stderr.strip()[:500]}"
    r = subprocess.run([vvp_exe, vvp_path], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out_path):
        return False, f"simulation error: {r.stdout.strip()[:500]} {r.stderr.strip()[:500]}"

    with open(out_path) as f:
        vals = [int(l.strip()) & 0xFFFFFFFF for l in f if l.strip()]
    rtl_regs = vals[:32]
    rtl_mem = vals[32:160]

    mismatches = []
    for i in range(32):
        if rtl_regs[i] != iss.regs[i]:
            mismatches.append(f"x{i}: RTL={rtl_regs[i]:#x} ISS={iss.regs[i]:#x}")
    for i in range(128):
        if rtl_mem[i] != iss.mem[i]:
            mismatches.append(f"mem[{i}]: RTL={rtl_mem[i]:#x} ISS={iss.mem[i]:#x}")

    if mismatches:
        return False, "; ".join(mismatches[:8]) + (" ..." if len(mismatches) > 8 else "")
    return True, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=30)
    ap.add_argument("--n-instrs", type=int, default=16)
    ap.add_argument("--seed-start", type=int, default=1)
    ap.add_argument("--iverilog-dir", default=None)
    ap.add_argument("--keep-failures", action="store_true", help="don't delete work dir contents for failing seeds")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    template = os.path.join(here, "..", "tb", "dump_regs_template.v")

    passed = 0
    failed = 0
    with tempfile.TemporaryDirectory() as work_dir:
        for i in range(args.count):
            seed = args.seed_start + i
            ok, msg = run_one(seed, args.n_instrs, work_dir, args.iverilog_dir, template)
            if ok:
                passed += 1
                print(f"pass  seed={seed}")
            else:
                failed += 1
                print(f"FAIL  seed={seed}: {msg}")
                if args.keep_failures:
                    keep_dir = os.path.join(os.getcwd(), f"random_fail_{seed}")
                    os.makedirs(keep_dir, exist_ok=True)
                    for fn in (f"r{seed}.s", f"r{seed}.mem", f"r{seed}.v"):
                        src = os.path.join(work_dir, fn)
                        if os.path.exists(src):
                            with open(src, "rb") as sf, open(os.path.join(keep_dir, fn), "wb") as df:
                                df.write(sf.read())

    print(f"\n=== random cross-check: {passed}/{passed+failed} programs matched ISS reference ===")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
