# ADR 0033: Memory-Capacity Scale-Up (Generation 3, Phase Q)

## Problem

Phase P (`docs/adr/0032`) closed out a genuinely new Sv39 MMU/TLB/PTW, deliberately truncating the
walker's own formed addresses to 20 bits — "since this core's actual physical memory is tens of
KB, not gigabytes" — and explicitly flagged Phase Q as "the natural place to revisit this... once
the core's real memory actually needs more than that." Per `docs/ROADMAP_VISION.md`'s Generation 3
sequence, Phase Q's stated goal is "memory-capacity scale-up, real MBs for an actual kernel image,"
ahead of Phase R (ns16550a/CLINT register compatibility), Phase S (SBI firmware), and Phase T (a
real riscv64 Linux kernel boot attempt).

Three scope questions confirmed via `AskUserQuestion` (research-first, per this project's own
established phase workflow):

1. **Keep the 20-bit PPN truncation in `Ptw.v`/`Ptw39.v` exactly as-is.** Research (an `Explore`
   agent reading both walkers directly, not assumed from the ADR 0032 framing) found the truncation
   was never actually the binding constraint the docs implied: 20 bits of PPN, at a 4KB page size,
   already reaches `2^20 × 4KB = 4GB` — comfortably past any realistic kernel-image target. Widening
   it would be real RTL churn for zero functional gain below 4GB.
2. **Target `MEM_SIZE_BYTES = 67108864` (64MB, `0x4000000`)** — realistic headroom for a minimal
   RV64 Linux kernel image + initramfs + working RAM, comfortably under `riscv_defs.vh`'s
   `` `MMIO_BASE `` (`0x1000_0000`, 256MB), so no address-map restructuring is needed.
3. **A bounded-window approach for the constrained-random harness's dump/compare**, not exact
   touched-address-set tracking (the user's own "sparse compare" answer, simplified during design
   after reading `sim/tools/random_gen.py` directly — see Design below).

## Design

Unlike every prior MMU-shaped phase (F, O, P), this phase's own hardest problems turned out to be
almost entirely in *verification-tooling scale*, not RTL correctness — the RTL side (Q1, Q2) needed
two small, well-understood cost-bounding changes and found zero logic bugs; the tooling side (Q3, Q4)
found two real, non-obvious bugs, both by running, neither anticipated by the plan.

### Q1: Feasibility gate + bounded zero-init

Both `InstructionMemory.v` and `DataMemoryBRAM.v` already declared genuinely `SIZE_BYTES`-parametric
flat byte arrays (`reg [7:0] mem [0:SIZE_BYTES-1]`) — no width-truncation bug, unlike the PPN
question above. But both zero-initialize the *entire* array in an explicit `for` loop at time
0/reset. Nothing in this project's history had run Icarus at MB scale (the largest `MEM_SIZE_BYTES`
ever exercised before this phase was 16384 bytes, Phase P). Rather than assume this would "just
work" because the array declaration itself is parametric, this phase treated it as a real go/no-go
checkpoint: a throwaway two-module testbench at `SIZE_BYTES=67108864`, timed directly.

**Measured**: the old unconditional zero-init loop took **2m46.760s wall-clock** for a trivial
reset with no actual program execution — confirming the risk was real, not hypothetical. Fixed by
bounding the zero-init loop (and the `$readmemb` load range alongside it) to a `ZERO_INIT_LIMIT`
`localparam`, `(SIZE_BYTES < 65536) ? SIZE_BYTES : 65536` — a fixed 64KB window, matching every
real program's actual footprint with enormous headroom (the largest program this project's own
harness has ever generated is a few hundred bytes). **Re-measured after the fix: 1.049s** — the
same probe, same 64MB size. Bit-exact at every pre-existing `SIZE_BYTES` (≤16384, all below the
65536 cap), confirmed by the full 88/88 directed suite and zero-warning compile immediately after.

### Q2: New large-memory end-to-end directed test

`sim/programs/mem_capacity_scaleup_q2.s` / `sim/tb/tb_mem_capacity_scaleup_q2.v`
(`MEM_SIZE_BYTES=67108864`, XLEN=64, no MMU — see Alternatives considered for why MMU+large-memory
interaction is out of scope): a baseline store+load near address 0, then a second store+load at the
literal top of the 64MB region (`MEM_SIZE_BYTES-8`, 8-byte-aligned for `sd`/`ld`). This is the one
test in the whole phase that actually exercises the full address range end-to-end through
`WbDecoder`/`RamWishboneAdapter`/`DataMemoryBRAM` — every other test (including the random corpus,
by design, see Q3) stays within the low 64KB window. Passes cleanly; no RTL bugs found here.

### Q3: Bounded-window dump/compare in the random-test harness

`sim/tools/run_random_tests.py`'s dump-and-compare is `O(mem_size)` on both sides — the RTL's own
`$fdisplay` loop and the Python-side parse/compare. At 64MB this would mean tens of millions of
dumped lines per seed. The recommended "track touched address set" answer was simplified during
design: reading `random_gen.py` directly (not assumed) showed every constrained-random program's
real memory accesses are already confined to a small, fixed low range regardless of `mem_size`
(`addr_space = min(mem_size, 4096)` in `--mmu` mode; load/store immediate offsets separately capped
to 2047 in every mode) and that `x2`/`sp` is never used as a real stack pointer by the generator
(only as scratch for timer/page-table setup). So a fixed 64KB window from address 0 —
`SCALEUP_WINDOW_BYTES`, matching `ZERO_INIT_LIMIT` — is provably sufficient for the entire
constrained-random corpus at any `MEM_SIZE_BYTES`, with the real touched range topping out around
`base_addr + 2051 ≈ 2083` bytes. Applied to three places: the RTL dump loop
(`dump_regs_interrupt_template.v`), the Python-side parse/compare bound, and the `.mem` file size
`asm.py` writes (a real program never needs more than the window, so padding the file out to the
true `mem_size` would itself be tens of millions of lines written to disk per seed).

Also fixed a pre-existing gap this phase's own sweep needed: `dump_regs_template.v` (the plain,
non-interrupt/non-mmu template) hardcodes its dump loop to 128 and never substitutes
`MEM_SIZE_BYTES` on the `PIPELINED` instantiation at all, so `--mem-size` silently had no effect on
a plain run before this phase (only `--interrupt`/`--mmu` runs routed through the parameterized
template). Fixed by widening the template-selection condition to also route any explicit non-default
`--mem-size` through `dump_regs_interrupt_template.v`.

## Real bugs/findings

Two real bugs, both found by running, both in tooling (not RTL) — continuing this project's
established "wire a new subsystem live" pattern for the RTL side (zero bugs, Q1/Q2) while the
tooling side keeps finding real problems only under execution:

1. **`$readmemb` range mismatch, a self-inflicted warning.** After Q1's `ZERO_INIT_LIMIT` fix,
   `InstructionMemory.v`'s `$readmemb(INIT_FILE, insts, 0, SIZE_BYTES-1)` still requested the full
   `SIZE_BYTES-1` range while the actual `.mem` file (correctly sized to the real tiny program) was
   far shorter — Icarus warned "not enough words in the file for the requested range" every time.
   Harmless (the untouched words already sit at the same 0 the bounded zero-init just wrote), but
   avoidable. Fixed by bounding the `$readmemb` range to `ZERO_INIT_LIMIT-1` too, applied to both
   `InstructionMemory.v` (exercised, confirmed the warning disappears) and `DataMemoryBRAM.v`'s
   parallel `$readmemb` call (not currently exercised by any real `DATA_INIT_FILE` user, fixed
   proactively for consistency with the identical latent issue).
2. **An unsound "defense-in-depth" idea, tried and reverted.** An early version of Q3's design also
   dumped three explicit high-address "spot checks" (`mem_size-8`, `mem_size-4`, `mem_size/2`)
   beyond the main window, intended to catch a hypothetical out-of-window RTL corruption bug. Tried
   at `--mem-size 200000` (deliberately beyond the 65536-byte window, to exercise the truncation
   path before committing to a full 64MB run) and immediately crashed: `ValueError: invalid literal
   for int() with base 10: 'x'`. Root cause: those addresses sit *outside* `DataMemoryBRAM.v`'s own
   bounded zero-init window, so they are genuinely undefined (`X`) in the RTL by design — the exact
   mechanism Q1's own cost-bounding relies on. Comparing an always-`X` RTL value against the ISS's
   always-defined-zero Python model isn't a real check at all, just a guaranteed parse failure
   regardless of whether any actual bug exists. Removed entirely — the exhaustive `[0, dump_window)`
   compare already covers the real touched range (≈2KB) with 30x headroom, and nothing outside the
   zero-initialized window can be soundly compared without also re-introducing the cost this phase
   exists to remove.
3. **The real one: `max_time` was computed from the wrong word count, and this phase's own Q3
   change made it catastrophic.** `run_one`'s `max_time = (len(words) * 70 + 200) * 10` used
   `len(words)` from `load_words(prog_mem)` — a full parse of the *padded* `.mem` file, not the real
   program length. This was already a latent inefficiency before this phase (at the old Sv39-MMU
   `mem_size=16384`, `len(words)=4096` versus a real program of maybe 30-40 instructions — a ~100x
   inflated budget, silently absorbed because 16384 was still small enough to stay fast). Q3's own
   fix of capping `asm.py`'s `--size` argument to `dump_window` (65536, a *constant*, not scaling
   down with the real program) made this catastrophic for any large `--mem-size`: `len(words)`
   became a fixed 16384 regardless of program size, inflating `max_time` to over 11 million time
   units (~1.1 million cycles) for a program that finishes in a few hundred. Measured directly: a
   single seed at `MEM_SIZE_BYTES=67108864` took **2m40.087s** wall-clock before the fix. Found not
   by suspicion but by direct investigation — a background 200-seed sweep was visibly not progressing
   after several minutes, `Get-Process` confirmed a single `vvp` process genuinely burning CPU (not
   hung), and a controlled single-seed timing test isolated the exact stage. Fixed by parsing the
   real instruction count directly from `asm.py`'s own stdout (`"N instructions -> ..."`, already
   printed, just not consumed) instead of re-deriving it from the padded file. **Re-measured after
   the fix: 2.638s** for the same seed — the actual RTL/ISS work was never slow; only the simulated
   time *budget* was wrong. This fix applies to every existing call site too (not just Phase Q's own
   large sizes), since `len(words)` was always somewhat inflated at any `mem_size` — re-verified
   the full existing corpus (88/88 directed, all four random-regression axes) stayed clean afterward.

## Alternatives considered

**Exact touched-address-set tracking for the dump/compare** (the originally recommended answer),
instead of a fixed bounded window. Rejected as unnecessary complexity: `random_gen.py`'s own
existing `base_addr`/`addr_space`/immediate-offset bounds already provably confine every generated
program's real accesses to a small window regardless of `mem_size`, so a fixed window achieves the
identical practical guarantee — provable equivalence, not a weaker approximation — for far less
code (no set-tracking machinery needed in the generator or the harness).

**Widening `Ptw.v`/`Ptw39.v`'s PPN truncation** past 20 bits, either to 32 bits (matching
`WbDecoder`'s existing 32-bit `SIZE`-array slice) or to full spec width (34-bit Sv32 / 56-bit
Sv39). Rejected (confirmed via `AskUserQuestion`): the 20-bit truncation already reaches 4GB, far
past any realistic target this phase or the near-term Generation 3 roadmap needs; either widening
would be real RTL churn with no functional benefit below 4GB.

**Restructuring `riscv_defs.vh`'s `MMIO_BASE` (256MB)** to make room for a larger RAM region.
Not needed at 64MB (well under the ceiling) — left as a real, documented prerequisite for any future
target that approaches 256MB, not attempted here.

**MMU+large-memory as an independently stress-tested combination** (a Q2-style directed test run
through Sv39 translation, or folding `--mmu` into Q2 itself). Deliberately not built: since the PPN
truncation stays unchanged and already supports up to 4GB (comfortably past 64MB), MMU translation
at 64MB reduces to "produce a physical address that flows through the same
`WbDecoder`/`DataMemoryBRAM` path Q2 already validates" — no new interaction to prove. Q4's own
Sv39-MMU volume sweep at the real 64MB target (100/100 clean) is the actual empirical confirmation
of this argument, not just the arithmetic.

## Validation strategy

Q1's own go/no-go timing probe (throwaway, deleted after use) before any further RTL. Q2's new
directed test, run standalone before joining the suite. Q3's regression-safety re-run at every
pre-existing size/mode (plain, `--interrupt`, `--mmu` at both XLEN=32/64) through the new windowed
mechanism, confirming identical pass/fail behavior — `dump_window == mem_size` at every one of
those sizes, so this is provably the exact old full-dump behavior, not a new code path being trusted
for the first time at small scale. A deliberate mid-scale check (`--mem-size 200000`, between the
window and the real target) exercised the actual truncation path cheaply before committing to a full
64MB sweep — this is exactly where the spot-check bug (finding 2) surfaced, and re-running the same
mid-scale check after removing it confirmed the fix.

Full closing bar, all re-run after the `max_time` fix (finding 3) to confirm it changed nothing but
speed: **88/88 directed tests** (`bash sim/run_tests.sh`, up from 87/87 — Q2's new test), zero-warning
`iverilog -Wall -g2005 -I design -tnull design/*.v` compile, and constrained-random cross-check clean
at: 100/100 default (XLEN=32), 60/60 XLEN=64 non-MMU, 60/60 Sv32-MMU, 60/60 Sv39-MMU (all at the
existing small sizes, regression), plus **100/100 non-MMU and 100/100 Sv39-MMU at the real
`MEM_SIZE_BYTES=67108864` (64MB) target** — Phase Q's own volume sweep, ~2.6s/seed average, ~4m17s
per 100-seed batch total.

## Future improvements

`MMIO_BASE` restructuring is not needed at 64MB but would be a real prerequisite if a future target
ever approached 256MB. MMU+large-memory interaction beyond the PPN-truncation argument (see
Alternatives considered) was not independently stress-tested with a directed test — the volume
sweep's own empirical confirmation was judged sufficient, but a dedicated directed test would be
cheap if a future phase's work depends on the distinction specifically. Icarus's own behavioral flat
array elaborates and simulates fine at 64MB (this phase's own measurements), but this says nothing
about real FPGA BRAM inference at that size, which stays unvalidated scaffolding per
`fpga/README.md` — Generation 3's own near-term plan (Phase R/S/T) stays software-simulation-only
regardless. Phase R (`Uart.v`/`Timer.v` register-layout redesign for ns16550a/CLINT compatibility)
is next per `docs/ROADMAP_VISION.md`.
