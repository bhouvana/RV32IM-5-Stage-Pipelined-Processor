# ADR 0017: Two real compiled-C toolchain bugs found porting CoreMark and Dhrystone

## Problem

`sim/benchmarks/c/`'s compiled-C toolchain infrastructure (linker script,
`elf2mem.py`, `build_c_bench.py`) was verified end-to-end on a small,
deliberately trivial smoke test (`sim/benchmarks/c/README.md`'s "real gotchas
already found" list documents three issues that surfaced there: byte order,
VMA/LMA, and a Verilog NBA scheduling bug). Porting the two real,
industry-standard benchmarks CoreMark and Dhrystone on top of that same
infrastructure (`docs/ROADMAP.md` Phase 10) found two further real bugs —
both invisible to the smoke test because it never exercised the code paths
they depend on, and both would affect *any* sufficiently real compiled-C
program on this core, not just these two benchmarks.

Both were found the same way every bug in this project has been: by
actually running the program and getting a wrong answer, not by reasoning
about the toolchain in advance. Both manifested identically at first —
a genuine infinite loop, indistinguishable from "just needs more simulation
time" until debug instrumentation (a throwaway testbench dumping PC/redirect
signals periodically) showed the DUT cycling through the *exact same*
instruction sequence forever.

## Bug 1: RISC-V GCC's `.sdata`/`gp` small-data placement

### Symptom

CoreMark (`sim/benchmarks/c/coremark_port/`), built with `-DITERATIONS=1`
so its outer iteration count should be fixed and small, ran for 20,000,000+
simulated cycles without reaching its halt loop. A debug testbench dumping
`pc_o_regde`/`inst_regfd` every 20,000 cycles showed the exact same ~13-point
address sequence repeating with a constant ~260,000-cycle period, forever —
not "slow progress," a genuine loop.

### Root cause

RISC-V GCC places small global scalars into `.sdata`/`.sbss` (not
`.data`/`.bss`) by default, addressed relative to the `gp` register for a
smaller encoding. `sim/benchmarks/c/link.ld` only defines `.text`/`.rodata`/
`.data`/`.bss` output sections; `.sdata`/`.sbss` are orphans that `ld` places
somewhere after them without complaint (no link error, no warning that
stops the build). `sim/tools/elf2mem.py`'s `--only-section .data` extraction
never captured them, and `sim/benchmarks/c/crt0.S` never initializes `gp` in
the first place (small-data addressing needs it set to the middle of
`.sdata`, which a real startup normally does with
`.option push / la gp, __global_pointer$ / .option pop`).

Confirmed directly: `nm` on the compiled ELF showed CoreMark's
`seed4_volatile` (a small `volatile ee_s32`, non-zero-initialized, i.e.
genuinely `.data`-shaped) at an address *past* `_data_end` — outside the
region `elf2mem.py` extracted at all. Whatever ended up at that address in
the simulated `DataMemoryBRAM.v` was leftover reset-zero, not the intended
value `1`. `core_main.c` reads that seed to set `results[0].iterations`; a
silently-zeroed iteration count is exactly the shape of CoreMark's own
auto-detect-iteration-count fallback path — though the *actual* observed
behavior (constant-period, non-growing loop) turned out to mean the count
had gone in a different, still-wrong direction (see Bug 2's investigation
below for how this was disentangled from Bug 2's near-identical symptom).

### Fix

`sim/tools/build_c_bench.py` now always passes `-msmall-data-limit=0`,
which disables the RISC-V small-data optimization entirely and forces every
global into ordinary `.data`/`.bss` — sections the existing linker script
and extraction already handle correctly. No RTL change; no linker script
change.

## Bug 2: `.rodata` routed to IMEM instead of DMEM

### Symptom

With Bug 1 fixed, CoreMark completed correctly (see Validation below), but
Dhrystone (`sim/benchmarks/c/dhrystone_port/`) still hung — same signature,
a debug testbench showed `pc_o_regde` permanently stuck oscillating between
two addresses (a call site and its callee), forever.

### Root cause

This core is Harvard architecture: `design/InstructionMemory.v` (fetch) and
`design/DataMemoryBRAM.v` (load/store) are independent memories, and a
`lw`/`lb`-class instruction always addresses the latter, never the former,
regardless of what's stored at that address. The first version of
`sim/benchmarks/c/link.ld` placed `.rodata` (string literals, `const` data)
in the `IMEM` output region alongside `.text` — a reasonable-sounding
"read-only stuff goes with code" assumption that is simply wrong for a
split-memory design: `.rodata` is never instruction-fetched, it's *read*
with ordinary load instructions. Every load from a string literal or
`const` array therefore silently returned zeroed `DataMemoryBRAM.v` content
instead of the real bytes.

This was invisible to `smoke_test.c` (no string literals) and to
CoreMark's port (its `ee_printf` stub takes `(void)fmt` and never
dereferences the format string it's handed — the address gets computed and
passed as an argument, but nothing ever loads through it). It was fatal to
Dhrystone: `dhrystone_main.c` calls `strcpy(Str_1_Loc, "DHRYSTONE PROGRAM, ...")`
several times, which *does* read every byte of the literal. With those reads
returning zero, `Func_2`'s `while (Int_Loc <= 2) if (Func_1(...) == Ident_1) Int_Loc += 1;`
— whose single-iteration behavior depends on two specific characters from
the (corrupted, now-empty) strings actually differing — never took the `if`
branch, so `Int_Loc` never advanced and the loop ran forever.

### Fix, and the two ways the first two fix attempts went wrong

The correct fix: give `.rodata` its own output section targeting `DMEM`,
not `IMEM`, and extract it into the DMEM-side memory image, not the IMEM
one. Two intermediate attempts at the mechanics of this were tried and
rejected before landing on the working version, both caught by actually
rebuilding and rerunning rather than assumed correct from the script alone:

1. **No explicit LMA for `.data`, letting it inherit `.rodata`'s
   contiguously.** Works when `.rodata` is non-empty, but a program with
   *no* `.rodata` at all (`smoke_test.c`) makes the section vanish
   entirely, so `.data` fell back to its default LMA (== its VMA, `0`) and
   collided with `.text`'s LMA — the exact "section .data LMA overlaps
   section .text LMA" error `docs/adr` history (this tool's original
   VMA/LMA fix) already exists to avoid. Caught by rebuilding
   `smoke_test.c` as a regression check, not assumed safe.
2. **Give `.rodata` and `.data` their own far-apart LMAs, extract both
   together in one `objcopy -O binary` call** (mirroring how IMEM's
   `.text.init`+`.text` extraction already works). `objcopy -O binary`
   lays out a *multi-section* extraction by absolute LMA span — with the
   two LMAs far apart, the "combined" output spans the entire gap between
   them, zero-padded. A 32KB target region briefly became a ~256MB output
   file. Caught immediately (`elf2mem.py`'s own size check raised loudly)
   rather than silently doing the wrong thing.

The working version: `.rodata` and `.data` each get their own real, distinct
LMA (`RODATA_LMA`, `DMEM_LMA`), and `sim/tools/elf2mem.py` extracts each of
them *independently* (single-section `objcopy` calls, each returning just
that section's own bytes at whatever size it actually is), then places each
blob into the output DMEM image at its own real VMA offset — read via `nm`
on `_rodata_start`/`_data_start`, the linker-computed values, rather than
inferred/recomputed in Python (which would have to reproduce the linker's
own alignment rules to get right). `.bss` needs no equivalent handling,
same as before: it's already correctly represented by leaving those bytes
zero in a pre-zeroed output buffer.

## Alternatives considered

- **Add a real `gp` setup to `crt0.S` and map `.sdata`/`.sbss` in `link.ld`
  instead of disabling small-data.** More faithful to how a real embedded
  target would do it, but strictly more code and complexity for a benefit
  (slightly smaller code size) this project doesn't need — `-msmall-data-limit=0`
  is the standard, documented way freestanding/bare-metal RISC-V builds
  without a real startup sequence avoid this exact class of bug, and is a
  single flag versus a new startup responsibility.
- **Keep `.rodata` in IMEM, add a special-cased "if a load address falls
  within the IMEM range, read from IMEM instead" path.** Rejected outright:
  that's routing data reads through the instruction memory port based on
  address heuristics, which is both a real hack in the toolchain and would
  misrepresent what a synthesizable version of this core could actually do
  (a real Harvard core has no way to loads-from-fetch-port; the two ports
  are physically separate). Moving `.rodata` to the side that's actually
  correct for its access pattern is the honest fix.

## Validation strategy

- `smoke_test.c` rebuilt and rerun after *every* change in this ADR
  (regression check, not assumed unaffected): unchanged, 79 cycles,
  `x10 = 360`.
- CoreMark (`sim/benchmarks/c/coremark_port/`), `TOTAL_DATA_SIZE=400`,
  `ITERATIONS=1`: completed (no longer hangs) in 37,323 cycles after Bug 1's
  fix alone. Standard `PERFORMANCE_RUN` configuration (`TOTAL_DATA_SIZE=2000`
  default, seeds `0,0,0x66`) run against `list_known_crc[0]`/
  `matrix_known_crc[0]`/`state_known_crc[0]` — see `docs/ROADMAP.md`'s
  Phase 10 status update for the specific result.
- Dhrystone (`sim/benchmarks/c/dhrystone_port/`), `Number_Of_Runs=500`:
  completed in 462,126 cycles after Bug 2's fix. Every documented expected
  final value verified directly out of the post-halt data-memory dump via
  `nm` (address) + `sim/tools/read_dump.py` (value), not inferred: `Int_Glob
  == 5`, `Bool_Glob == 1`, `Ch_1_Glob == 'A'` (65), `Ch_2_Glob == 'B'` (66),
  `Arr_1_Glob[8] == 7`, `Arr_2_Glob[8][7] == 510` (`Number_Of_Runs + 10`) —
  all six match dhrystone_main.c's own "should be" comments exactly.
- Full directed suite (`sim/run_tests.sh`) and `iverilog -Wall` re-run
  after these changes: unaffected, since none of this touches `design/`
  RTL — purely `sim/benchmarks/c/link.ld`, `sim/tools/elf2mem.py`, and
  `sim/tools/build_c_bench.py`.

## Future improvements

- Neither bug required any RTL change — both were purely toolchain
  (linker script / ELF-to-memory-image conversion) issues. Worth stating
  plainly: this core's Harvard-architecture RTL behaved exactly as
  designed throughout; the bugs were entirely in the bridge between a real
  compiler/linker's assumptions and this core's specific memory layout.
- A real `gp`-relative small-data path (this ADR's first rejected
  alternative for Bug 1) remains legitimate future work if code size ever
  matters enough to justify it — not currently a goal.
