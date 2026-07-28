# Compiled-C programs on this core (docs/ROADMAP.md Phase 10)

Infrastructure for running real compiled C (CoreMark, Dhrystone, or
anything else) on this core, as opposed to the hand-written-assembly
`sim/benchmarks/bench_*.s` kernels or `sim/programs/*.s` directed tests
(both use `sim/tools/asm.py`, this core's own small custom assembler, not
a real toolchain).

## What's here

- `link.ld` -- linker script. Read its header comment first: this core is
  Harvard architecture (independent instruction/data memories), which a
  standard RISC-V linker script doesn't expect, and getting the VMA/LMA
  split wrong here produces code that computes the wrong addresses at
  runtime -- silently, not a link or compile error.
- `crt0.S` -- minimal startup (`_start`): stack pointer, zero `.bss`, call
  `main()`, spin forever on return (this core's usual halt convention,
  `docs/adr/0011`).
- `libc_stubs.c` -- `memcpy`/`memset`/`memmove`/`memcmp`/`strlen`. The
  build uses `-nostdlib -nostartfiles -ffreestanding`, so nothing else is
  available; add more here only if a real program actually needs them
  (link errors will say so).
- `smoke_test.c` -- deliberately tiny, known-answer program (sums an array,
  returns 360 in `a0`). Exists to validate the whole toolchain -> linker ->
  `sim/tools/elf2mem.py` -> RTL pipeline on something small before
  debugging the same class of problem inside CoreMark's much larger
  codebase.

## Toolchain

A real RISC-V GCC is required -- `sim/tools/asm.py` cannot consume
compiler output. xPack's prebuilt Windows binaries are the easiest source:
https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases (grab
the `win32-x64` asset from Releases, not the repository source zip).

## Running something

```
python sim/tools/build_c_bench.py sim/benchmarks/c/smoke_test.c \
    --gcc /path/to/riscv-none-elf-gcc.exe \
    --objcopy /path/to/riscv-none-elf-objcopy.exe \
    --iverilog-dir /c/iverilog/bin
```

Reports cycle count and `x10`/`a0` (`main()`'s return value, standard
RISC-V calling convention) -- there is no UART/printf on this core, so
reading final architectural state directly (same technique every other
tool in this repo that needs final state already uses) is the only way to
get a result out. `sim/tb/c_bench_template.v` dumps the full register file
and all of data memory for anything that needs more than `x10` (e.g.
CoreMark's `results[0].crc`).

## Real gotchas already found (don't re-derive these)

- **Byte order is not symmetric between the two memories.** A real ELF is
  little-endian (RISC-V's actual spec). `design/DataMemoryBRAM.v` already
  matches that directly. `design/InstructionMemory.v` does NOT --
  `sim/tools/asm.py` packs its own instruction words big-endian, and
  `elf2mem.py` has to reverse each instruction word's byte order to match.
  Get this wrong and every instruction decodes as garbage from the first
  fetch.
- **VMA, not just LMA, has to be zero-based for both memories.** A first
  `link.ld` attempt gave `.data` a distinct nonzero *origin* to satisfy
  `ld`'s LMA-overlap check -- which also made the compiled code compute
  nonzero addresses for every global variable, since VMA is what address
  computations actually use. Fixed by keeping both memory regions at
  `ORIGIN = 0x0` and giving `.data` a separate `AT(...)` *load* address
  instead, which satisfies the same check without touching what the code
  computes.
- **Verilog NBA scheduling can silently lose a `$readmemb` pre-load.**
  `design/DataMemoryBRAM.v`'s reset-time zero-init loop used a nonblocking
  assignment to the same array `$readmemb` (called synchronously, in the
  same block) writes to -- the loop's writes commit at the end of the time
  step, after `$readmemb` already ran, clobbering it regardless of which
  one is written first in the source. Fixed by making the two paths
  mutually exclusive. See `docs/adr` history for the exact commit.

Both were found by actually running the smoke test and getting wrong
answers back (`X`-valued registers, garbage addresses), not by reading the
code and reasoning it should work -- consistent with this project's
verification standard everywhere else.
