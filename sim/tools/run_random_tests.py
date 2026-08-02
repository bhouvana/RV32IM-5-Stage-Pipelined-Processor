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


def run_one(seed, n_instrs, work_dir, iverilog_bin, template, hazard_strategy=0, pipeline_profile=0,
            mem_size=128, interrupt=None, branch_predictor=0, mmu=False):
    prog_s = os.path.join(work_dir, f"r{seed}.s")
    prog_mem = os.path.join(work_dir, f"r{seed}.mem")
    text, interrupt_info = gen_program(seed, n_instrs, mem_size=mem_size, interrupt=interrupt, mmu=mmu)
    with open(prog_s, "w") as f:
        f.write(text)

    asm_py = os.path.join(os.path.dirname(os.path.abspath(__file__)), "asm.py")
    r = subprocess.run([sys.executable, asm_py, prog_s, "-o", prog_mem, "--size", str(mem_size)],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return False, f"assembler error: {r.stderr.strip()}"

    words = load_words(prog_mem)
    iss = ISS(mem_size=mem_size)
    # docs/adr/0020-soc-integration.md (Phase D10). Matches the RTL's own
    # real (armed but not precisely timed) hardware interrupt with an
    # externally scheduled one on the ISS side -- see gen_program's own
    # docstring for why the two don't need to agree on the exact
    # instruction boundary.
    if interrupt_info is not None:
        iss.schedule_interrupt(interrupt_info["after"], interrupt_info["cause"])
    try:
        iss.run(words, max_steps=5000)
    except Exception as e:  # noqa: BLE001
        return False, f"ISS error: {e}"

    # Multi-cycle divisions/fdiv.s/fsqrt.s dominate runtime -- budget
    # generously: every instruction could in principle be one (fdiv.s is
    # the longest at ~51 iterations, docs/adr/0019 Phase C4), plus margin.
    max_time = (len(words) * 70 + 200) * 10
    dump_v = os.path.join(work_dir, f"r{seed}.v")
    out_path = os.path.join(work_dir, f"r{seed}.out").replace("\\", "/")
    init_file_rel = os.path.relpath(prog_mem, start=os.getcwd()).replace("\\", "/")
    with open(template) as f:
        tpl = f.read()
    uart_stimulus = ""
    if interrupt in ("uart", "both"):
        # Starts almost immediately and completes in ~40 cycles
        # (CLKS_PER_BIT=4 * 10 bit periods) -- comfortably early and fast
        # relative to max_time, landing well within the generously-margined
        # "somewhere before the program's own halt loop" safety window
        # gen_program's docstring describes.
        uart_stimulus = "repeat (5) @(posedge clk);\n        drive_rx_byte(8'hA5);"
    tpl = (tpl.replace("__INIT_FILE__", init_file_rel).replace("__MAX_TIME__", str(max_time))
              .replace("__OUT_FILE__", out_path).replace("__HAZARD_STRATEGY__", str(hazard_strategy))
              .replace("__PIPELINE_PROFILE__", str(pipeline_profile)).replace("__MEM_SIZE__", str(mem_size))
              .replace("__BRANCH_PREDICTOR__", str(branch_predictor))
              .replace("__UART_STIMULUS__", uart_stimulus))
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
    # Layout matches dump_regs_template.v/dump_regs_interrupt_template.v
    # exactly: 32 int regs, mem_size mem bytes, 32 float regs, fflags, frm
    # (docs/adr/0019-f-extension.md Phase C9).
    rtl_regs = vals[:32]
    rtl_mem = vals[32:32 + mem_size]
    rtl_fregs = vals[32 + mem_size:32 + mem_size + 32]
    rtl_fflags = vals[32 + mem_size + 32]
    rtl_frm = vals[32 + mem_size + 33]

    mismatches = []
    for i in range(32):
        if rtl_regs[i] != iss.regs[i]:
            mismatches.append(f"x{i}: RTL={rtl_regs[i]:#x} ISS={iss.regs[i]:#x}")
    for i in range(mem_size):
        if rtl_mem[i] != iss.mem[i]:
            mismatches.append(f"mem[{i}]: RTL={rtl_mem[i]:#x} ISS={iss.mem[i]:#x}")
    for i in range(32):
        if rtl_fregs[i] != iss.fregs[i]:
            mismatches.append(f"f{i}: RTL={rtl_fregs[i]:#010x} ISS={iss.fregs[i]:#010x}")
    if rtl_fflags != iss.fflags:
        mismatches.append(f"fflags: RTL={rtl_fflags:#x} ISS={iss.fflags:#x}")
    if rtl_frm != iss.frm:
        mismatches.append(f"frm: RTL={rtl_frm:#x} ISS={iss.frm:#x}")

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
    ap.add_argument("--hazard-strategy", type=int, default=0, choices=[0, 1],
                     help="riscvpipeline.v's HAZARD_STRATEGY (docs/adr/0016): 0=forwarding (default), 1=stall-only")
    ap.add_argument("--pipeline-profile", type=int, default=0, choices=[0, 1],
                     help="riscvpipeline.v's PIPELINE_PROFILE (docs/adr/0018): "
                          "0=5-stage (default), 1=6-stage split-fetch")
    ap.add_argument("--branch-predictor", type=int, default=0, choices=[0, 1],
                     help="riscvpipeline.v's BRANCH_PREDICTOR (docs/adr/0021): "
                          "0=static not-taken (default), 1=dynamic BHT+BTB")
    # docs/adr/0020-soc-integration.md (Phase D10). Opt-in, not default-on --
    # every existing invocation (no --interrupt) behaves exactly as before,
    # against the original dump_regs_template.v at mem_size=128.
    ap.add_argument("--interrupt", choices=["timer", "uart", "both"], default=None,
                     help="opt-in interrupt-injection mode (docs/adr/0020 Phase D10/D11): "
                          "arm and fire the given source once during each generated program "
                          "(\"both\" arms and pends both simultaneously, exercising MEI-over-MTI priority)")
    ap.add_argument("--mem-size", type=int, default=None,
                     help="override InstructionMemory/DataMemory size in bytes; "
                          "defaults to 128 normally, 256 when --interrupt is set "
                          "(room for the extra prefix/handler instructions), "
                          "8192 when --mmu is set (room for the page table's own two pages)")
    # docs/adr/00NN-mmu-sv32.md (Phase F7). Opt-in, not default-on -- every
    # existing invocation (no --mmu) behaves exactly as before. Mutually
    # exclusive with --interrupt in this phase (see gen_program's own
    # docstring for why).
    ap.add_argument("--mmu", action="store_true",
                     help="opt-in Sv32 translation mode (docs/adr/00NN-mmu-sv32.md Phase F7): "
                          "run the whole generated program as translated U-mode code, through a "
                          "generator-guaranteed-valid identity page table")
    args = ap.parse_args()

    if args.interrupt and args.mmu:
        print("error: --interrupt and --mmu are mutually exclusive in this generator (Phase F7 scope)", file=sys.stderr)
        sys.exit(2)

    if args.mem_size is not None:
        mem_size = args.mem_size
    elif args.mmu:
        mem_size = 8192
    elif args.interrupt:
        mem_size = 256
    else:
        mem_size = 128

    here = os.path.dirname(os.path.abspath(__file__))
    # docs/adr/00NN-mmu-sv32.md (Phase F7): MMU mode reuses the interrupt
    # template -- it already parameterizes MEM_SIZE_BYTES and the memory-
    # dump loop correctly (the plain default template hardcodes 128 bytes
    # both places); its own interrupt-specific pieces (uart_rx wiring,
    # drive_rx_byte) are simply unused/harmless when --mmu is set without
    # --interrupt (uart_stimulus stays the empty string, same as a plain
    # --interrupt-less run through this same template would see).
    template_name = "dump_regs_interrupt_template.v" if (args.interrupt or args.mmu) else "dump_regs_template.v"
    template = os.path.join(here, "..", "tb", template_name)

    passed = 0
    failed = 0
    with tempfile.TemporaryDirectory() as work_dir:
        for i in range(args.count):
            seed = args.seed_start + i
            ok, msg = run_one(seed, args.n_instrs, work_dir, args.iverilog_dir, template,
                              args.hazard_strategy, args.pipeline_profile,
                              mem_size=mem_size, interrupt=args.interrupt,
                              branch_predictor=args.branch_predictor, mmu=args.mmu)
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
