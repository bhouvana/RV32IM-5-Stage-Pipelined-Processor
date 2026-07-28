#!/usr/bin/env python3
"""
Compile, convert, and run a real compiled-C program on this core
(docs/ROADMAP.md Phase 10 -- CoreMark/Dhrystone, following up on the
hand-written sim/benchmarks/bench_*.s kernels). Ties together:
  1. riscv-none-elf-gcc (or equivalent), compiling + linking against
     sim/benchmarks/c/link.ld + crt0.S + libc_stubs.c.
  2. sim/tools/elf2mem.py, splitting the resulting ELF into separate
     instruction/data memory images (this core is Harvard architecture --
     see link.ld's header comment for why that split is needed at all).
  3. sim/tb/c_bench_template.v via Icarus Verilog, running the real RTL and
     reporting cycle count + final architectural state (x10/a0 and all of
     data memory -- there's no UART/printf on this core, so this is the
     only way to get a result out, same technique every other tool in this
     repo that needs final state already uses).

Usage:
    python build_c_bench.py smoke_test.c --gcc riscv-none-elf-gcc \\
        --objcopy riscv-none-elf-objcopy --iverilog-dir /c/iverilog/bin
"""
import argparse
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C_DIR = os.path.join(HERE, "..", "benchmarks", "c")


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        cmd_str = " ".join(str(c) for c in cmd)
        raise RuntimeError(f"command failed: {cmd_str}\n{r.stdout}\n{r.stderr}")
    return r


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sources", nargs="+", help="C source file(s), e.g. smoke_test.c or coremark's core_*.c + a port")
    ap.add_argument("--include-dirs", nargs="*", default=[], help="extra -I directories (e.g. CoreMark's own dir)")
    ap.add_argument("--gcc", default="riscv-none-elf-gcc")
    ap.add_argument("--objcopy", default="riscv-none-elf-objcopy")
    ap.add_argument("--iverilog-dir", default=None)
    ap.add_argument("--mem-size", type=int, default=32768, help="bytes; shared by IMEM and DMEM (docs/adr/0012, 0015)")
    ap.add_argument("--hazard-strategy", type=int, default=0, choices=[0, 1])
    ap.add_argument("--max-time", type=int, default=200000000, help="Verilog time units before giving up")
    ap.add_argument("--extra-cflags", default="",
                     help="space-separated, e.g. --extra-cflags=\"-DITERATIONS=1 -DTOTAL_DATA_SIZE=400\" "
                          "(argparse can't take multiple -D-style tokens as separate argv words)")
    ap.add_argument("--keep", action="store_true", help="don't delete the work directory; print its path")
    args = ap.parse_args()

    work_dir = tempfile.mkdtemp(prefix="cbench_")
    try:
        elf_path = os.path.join(work_dir, "prog.elf")
        cflags = [
            "-march=rv32im", "-mabi=ilp32",
            "-nostdlib", "-nostartfiles", "-ffreestanding",
            "-Wl,-T," + os.path.join(C_DIR, "link.ld"),
            # RISC-V GCC places small globals in .sdata/.sbss for gp-relative
            # addressing by default -- this core's link.ld has no such
            # section (only .data/.bss), and crt0.S never initializes gp
            # (x3) at all. Left enabled, small scalar globals (e.g.
            # CoreMark's seed*_volatile) silently end up outside the
            # extracted .data range and read back as zero/garbage --
            # verified directly: nm showed seed4_volatile at an address
            # past _data_end, and the program looped forever on a
            # zero-initialized iteration count. -msmall-data-limit=0
            # forces everything into ordinary .data/.bss, which the
            # existing linker script and elf2mem.py already handle.
            "-msmall-data-limit=0",
            "-O2",
        ] + args.extra_cflags.split()
        for d in [C_DIR] + args.include_dirs:
            cflags += ["-I", d]

        sources = [os.path.join(C_DIR, "crt0.S"), os.path.join(C_DIR, "libc_stubs.c")] + args.sources
        cmd = [args.gcc] + cflags + sources + ["-o", elf_path]
        print("compiling:", " ".join(cmd))
        run(cmd)

        imem_mem = os.path.join(work_dir, "imem.mem")
        dmem_mem = os.path.join(work_dir, "dmem.mem")
        run([sys.executable, os.path.join(HERE, "elf2mem.py"), elf_path,
             "--imem-out", imem_mem, "--dmem-out", dmem_mem,
             "--imem-size", str(args.mem_size), "--dmem-size", str(args.mem_size),
             "--objcopy", args.objcopy])
        print(f"converted: {imem_mem}, {dmem_mem}")

        template_path = os.path.join(HERE, "..", "tb", "c_bench_template.v")
        with open(template_path) as f:
            tpl = f.read()
        cycles_out = os.path.join(work_dir, "cycles.out").replace("\\", "/")
        state_out = os.path.join(work_dir, "state.out").replace("\\", "/")
        imem_rel = os.path.relpath(imem_mem, start=os.getcwd()).replace("\\", "/")
        dmem_rel = os.path.relpath(dmem_mem, start=os.getcwd()).replace("\\", "/")
        tpl = (tpl.replace("__INIT_FILE__", imem_rel)
                  .replace("__DATA_INIT_FILE__", dmem_rel)
                  .replace("__MEM_SIZE__", str(args.mem_size))
                  .replace("__MAX_TIME__", str(args.max_time))
                  .replace("__CYCLES_OUT_FILE__", cycles_out)
                  .replace("__STATE_OUT_FILE__", state_out)
                  .replace("__HAZARD_STRATEGY__", str(args.hazard_strategy)))
        dump_v = os.path.join(work_dir, "c_bench_run.v")
        with open(dump_v, "w") as f:
            f.write(tpl)

        vvp_path = os.path.join(work_dir, "c_bench_run.vvp")
        iverilog_exe = os.path.join(args.iverilog_dir, "iverilog.exe") if args.iverilog_dir else "iverilog"
        vvp_exe = os.path.join(args.iverilog_dir, "vvp.exe") if args.iverilog_dir else "vvp"
        run([iverilog_exe, "-g2005", "-I", "design", "-o", vvp_path, dump_v])
        r = subprocess.run([vvp_exe, vvp_path], capture_output=True, text=True)
        print(r.stdout)
        if r.stderr.strip():
            print(r.stderr, file=sys.stderr)

        if not os.path.exists(cycles_out) or not os.path.exists(state_out):
            print("FAILED: no output produced (likely a timeout -- see above)")
            sys.exit(1)

        with open(cycles_out) as f:
            cycles = int(f.read().strip())
        with open(state_out) as f:
            vals = [int(l.strip()) & 0xFFFFFFFF for l in f if l.strip()]
        regs = vals[:32]
        mem = vals[32:32 + args.mem_size]

        print(f"\ncycles = {cycles}")
        print(f"x10/a0 (main()'s return value, per the standard calling convention) = {regs[10]} ({regs[10]:#x})")
        return regs, mem, cycles
    finally:
        if args.keep:
            print(f"work dir kept: {work_dir}")
        else:
            import shutil
            shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
