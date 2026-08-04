#!/usr/bin/env python3
"""
Build the Verilator model + C++ harness for a real Linux boot attempt
(docs/adr/0036-linux-boot-attempt-phase-t.md). Bypasses Verilator's own
generated Makefile entirely -- this machine has no `make` (confirmed by a
real search; OSS CAD Suite bundles verilator but not make) -- by compiling
the generated C++ sources directly with g++. Static linking
(-static-libgcc -static-libstdc++ -static) is required, not optional: a
first attempt without it produced a real, silently-broken executable (exit
127, no output) from a missing MinGW runtime DLL not on PATH at run time --
found by actually running it, not assumed.

Usage:
    python build_kernel_boot.py --imem imem.mem --dmem dmem.mem \\
        --mem-size 67108864 [--clks-per-bit 4]
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# Real bug found by running: leaving REPO_ROOT/DESIGN_DIR as unresolved
# "...\..\.." relative segments (os.path.join alone doesn't collapse
# them) confused Verilator's own internal Windows path handling badly
# enough to silently break `include resolution inside riscv_defs.vh --
# normpath here, not just forward-slash conversion later, is the real fix.
REPO_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
DESIGN_DIR = os.path.join(REPO_ROOT, "design")
VERILATOR_DIR = os.path.join(REPO_ROOT, "sim", "verilator")

OSS_CAD_BIN = r"C:\oss-cad-suite\oss-cad-suite\bin"
OSS_CAD_VERILATOR_ROOT = r"C:\oss-cad-suite\oss-cad-suite\share\verilator"


def run(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd))
    r = subprocess.run(cmd, **kw)
    if r.returncode != 0:
        raise RuntimeError(f"command failed (rc={r.returncode}): {' '.join(str(c) for c in cmd)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--imem", required=True, help="path to InstructionMemory.v's own INIT_FILE .mem")
    ap.add_argument("--dmem", required=True, help="path to DataMemoryBRAM.v's own DATA_INIT_FILE .mem")
    ap.add_argument("--mem-size", type=int, required=True)
    ap.add_argument("--zero-init-limit-override", type=int, default=0,
                     help="docs/adr/0036 -- 0 (default) keeps Phase Q's own 64KB cap; a real "
                          "kernel-boot image needs this raised to cover build_linux_boot.py's "
                          "own reported zero_init_limit")
    ap.add_argument("--clks-per-bit", type=int, default=4,
                     help="UART_CLKS_PER_BIT -- a deliberate simplification (fast simulation, "
                          "not real-baud-accurate), matching every existing directed/random test's own convention")
    ap.add_argument("--verilator-bin", default=os.path.join(OSS_CAD_BIN, "verilator_bin.exe"))
    ap.add_argument("--verilator-root", default=OSS_CAD_VERILATOR_ROOT)
    # Explicit path, not a bare "g++" -- this project's Python tools run
    # under a native Windows Python whose subprocess PATH resolution
    # doesn't see Git Bash's own translated PATH (confirmed by running:
    # a bare "g++" here raised WinError 2, file not found, even though
    # `g++` resolves fine from an interactive Bash prompt).
    ap.add_argument("--gxx", default=r"C:\Users\poorn\mingw64\mingw64\bin\g++.exe")
    ap.add_argument("--out", default=os.path.join(VERILATOR_DIR, "vboot.exe"))
    ap.add_argument("--obj-dir", default=os.path.join(VERILATOR_DIR, "obj_dir_boot"))
    args = ap.parse_args()

    # Verilator's own internal path handling is confirmed more reliable
    # with forward slashes even on native Windows (found by running: an
    # earlier attempt with plain Windows backslash paths for -I/the
    # top-level source silently broke `include resolution inside
    # riscv_defs.vh, even though the exact same paths work fine from an
    # interactive Bash prompt using forward slashes) -- every verilator-
    # facing path here is forward-slash-normalized, not just the -G
    # string parameters.
    imem_rel = os.path.relpath(os.path.abspath(args.imem), start=REPO_ROOT).replace("\\", "/")
    dmem_rel = os.path.relpath(os.path.abspath(args.dmem), start=REPO_ROOT).replace("\\", "/")
    design_dir_fs = DESIGN_DIR.replace("\\", "/")
    top_src_fs = os.path.join(DESIGN_DIR, "riscvpipeline.v").replace("\\", "/")
    obj_dir_fs = args.obj_dir.replace("\\", "/")

    verilate_cmd = [
        args.verilator_bin,
        "-Wall", "-Wno-fatal",
        # Real warnings this phase's own lint pass confirmed are cosmetic/
        # pre-existing (see docs/adr/0036's own Design section) -- zero
        # %Error at any point, only these categories.
        "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC", "-Wno-LATCH", "-Wno-UNUSEDSIGNAL",
        "-Wno-BLKSEQ", "-Wno-UNUSEDPARAM", "-Wno-VARHIDDEN", "-Wno-DECLFILENAME",
        "-Wno-PINMISSING", "-Wno-CASEINCOMPLETE", "-Wno-UNOPTFLAT", "-Wno-UNSIGNED",
        # -I<dir> must be one concatenated token, not a separate argv
        # entry -- a real Verilator CLI quirk found by running: passing
        # "-I", design_dir as two list elements (which subprocess.run
        # does NOT rejoin, unlike a shell) made verilator's own arg
        # parser treat the directory as an entirely separate positional
        # module-file argument instead, silently breaking include
        # resolution for the real top-level source that followed it.
        "--cc", f"-I{design_dir_fs}",
        "-GXLEN=64",
        f"-GMEM_SIZE_BYTES={args.mem_size}",
        f'-GINIT_FILE="{imem_rel}"',
        f'-GDATA_INIT_FILE="{dmem_rel}"',
        f"-GUART_CLKS_PER_BIT={args.clks_per_bit}",
        f"-GZERO_INIT_LIMIT_OVERRIDE={args.zero_init_limit_override}",
        "--top-module", "PIPELINED",
        top_src_fs,
        "--Mdir", obj_dir_fs,
    ]
    env = dict(os.environ)
    env["VERILATOR_ROOT"] = args.verilator_root
    env["PATH"] = OSS_CAD_BIN + os.pathsep + env.get("PATH", "")
    run(verilate_cmd, cwd=REPO_ROOT, env=env)

    obj_cpps = [f for f in os.listdir(args.obj_dir) if f.startswith("VPIPELINED") and f.endswith(".cpp")]
    gxx_cmd = [
        args.gxx, "-O2", "-std=c++17",
        "-static-libgcc", "-static-libstdc++", "-static",
        "-I", args.obj_dir,
        "-I", os.path.join(args.verilator_root, "include"),
        "-I", os.path.join(args.verilator_root, "include", "vltstd"),
        os.path.join(VERILATOR_DIR, "sim_main.cpp"),
    ] + [os.path.join(args.obj_dir, f) for f in obj_cpps] + [
        os.path.join(args.verilator_root, "include", "verilated.cpp"),
        os.path.join(args.verilator_root, "include", "verilated_threads.cpp"),
        "-lpsapi",
        "-o", args.out,
    ]
    run(gxx_cmd, cwd=REPO_ROOT, env=env)
    print(f"done: {args.out}")


if __name__ == "__main__":
    main()
