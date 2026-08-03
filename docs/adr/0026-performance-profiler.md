# ADR 0026: Performance profiler (Phase K)

## Problem

Phase J (`docs/adr/0025-hpc-performance-csrs.md`) built the hardware performance-monitoring CSRs
(`mcycle`/`minstret`, `mcountinhibit`, 9 generic `mhpmcounter3-11`/`mhpmevent3-11` pairs) but deliberately
built nothing to consume them — "the performance profiler ... is what actually consumes these counters ...
deliberately not built in this phase." Per the Generation 1 scope decision (`docs/ROADMAP_VISION.md`), the
profiler is the next Generation-1 item: "Automated reports: pipeline utilization, stall breakdown, branch
accuracy, cache statistics, IPC, CPI, instruction mix."

Three scope decisions confirmed with the user (`AskUserQuestion`, all three the more-ambitious option,
consistent with every phase before this one):

1. **Counters are read via real `csrrs` instructions the profiled program itself executes**, not a
   simulation-only hierarchical testbench tap — the profiler stays meaningful on real FPGA hardware later,
   not just in simulation.
2. **The aggregate "stall cycles" event gets a genuine per-cause breakdown** (which of load-use/div/mem/fp/
   float-load-use/itlb/dtlb/icache/imem-wait is actually stalling the pipeline), not just one aggregate
   percentage.
3. **The report covers all three `sim/benchmarks/bench_*.s` kernels in one command**, both a human table and
   JSON.

Research (direct reads, not assumed) found: `sim/tools/asm.py` already supports `csrrw`/`csrrs`/`csrrc`
(+immediate forms) — zero assembler changes needed. Every per-cause stall wire already exists standalone in
`design/riscvpipeline.v` — `stall` (base hazard), `div_stall`, `mem_stall`, `fp_stall`,
`float_load_use_hazard`, `itlb_miss`, `dtlb_miss`, `icache_miss`, `imem_wait` — their OR is the existing
`pc_stall`, already `hpm_event_pulse[7]`. `design/CSR.v`'s `mhpmevent[i]` was `reg [3:0]`, addressing events
0(off)-9 — 9 new stall-cause events need indices 10-18, which need 5 bits, not 4. `sim/tb/dump_regs_template.v`
and `sim/tb/bench_template.v` already establish the two techniques this phase combines: a full 32-register
dump via `dut.m_Register.regs[i]`, and halt-loop-triggered "program finished" detection
(`dut.unconditional_redirect && dut.redirect_target == dut.pc_o_regde`). Only 9 physical counters exist but
there are 19 possible event codes (0 off + 9 original + 9 stall-cause) — one run can't observe all of them,
so this phase uses **two runs per kernel**, mirroring `bench_runner.py`'s own "vary one axis, rerun, diff"
precedent. "Instruction mix" (the one report item with no hardware counter behind it) is reported via
**static decode of the assembled program** (an opcode-class histogram), not a new dynamic hardware counter —
a deliberate scope choice, not an oversight (a dynamic, loop-aware mix would need as many new event codes as
opcode classes, on top of the 9 stall-cause ones already added).

## Design

### K1: RTL — widen `mhpmevent` to 5 bits, add 9 stall-cause events (10-18)

`design/CSR.v`: `mhpmevent` becomes `reg [4:0]`, `hpm_event_pulse` grows from `[0:9]` to `[0:18]`
(`localparam NUM_HPM_EVENTS = 18`), 9 new input ports (`stall_hazard_pulse`/`stall_div_pulse`/
`stall_mem_pulse`/`stall_fp_pulse`/`stall_float_lu_pulse`/`stall_itlb_pulse`/`stall_dtlb_pulse`/
`stall_icache_pulse`/`stall_imem_wait_pulse`) wired straight to `hpm_event_pulse[10]`-`[18]`. Every read/write
path touching the field width (`hpm_ev_acc`, the `MHPMEVENT` read case, the reset default, the write mask)
widened from 4 to 5 bits in lockstep. `riscvpipeline.v` threads the 9 already-existing raw wires into the new
`CSR` ports — no new detection logic, these wires already exist for `pc_stall`'s own sake. Reset defaults for
`mhpmcounter3-11` stay wired to events 1-9 (bit-identical existing behavior at reset — nothing observes
events 10-18 unless a program explicitly reprograms `mhpmeventN`).

Each new event is a **level** (true for every cycle that cause is part of the active stall), matching
`stall_cycle_pulse`'s own "count cycles, not occurrences" shape — deliberately NOT the edge-detected
occurrence-pulses events 3/4 already use for I$ hit/miss, which answer a different question ("how many
misses happened" vs. "how many cycles did a miss cost").

Four new directed tests (reusing existing proven scenarios rather than building parallel new ones from
scratch, per this project's own reuse-first discipline):

- `tb_perf_stallcause_k1.v` (default params): `stall`/`div_stall`/`mem_stall`/`fp_stall`/
  `float_load_use_hazard` via a load-use hazard, a `div`, an `fdiv.s`, and `float_forward.s`'s own proven
  flw-then-dependent-`fadd.s` shape. Calibrated by running, not paper-derived — `FDivider.v`'s own 51-cycle
  iterative shape (`QW=24+27`) meant the first attempt's simulation window was far too short, making
  `fp_stall`/`float_load_use_hazard` look like they never fired at all until traced cycle-by-cycle.
- `tb_perf_stallcause_cache_k1.v` (`CACHE_MODE=1`): `icache_miss`, reusing `docs/adr/0025`'s own J5 access
  pattern verbatim.
- `tb_perf_stallcause_mmu_k1.v` (Sv32 enabled): `itlb_miss`/`dtlb_miss`, a fresh minimal page-table program
  mirroring F5's own happy-path shape (this program's own preamble isn't label-driven for the fetch mapping,
  so `u_code`'s VA page-offset is hand-computed to match its real physical byte address, the same technique
  F5 itself used).
- `tb_perf_stallcause_latency_k1.v` (`CACHE_NONE` + `MEM_LATENCY_I=3`): `imem_wait`, reusing I3's own scenario
  verbatim.

### K2: `sim/tb/profiler_template.v`

A new template combining two already-proven techniques rather than inventing a third: `bench_template.v`'s
own generic "program finished" detection, and `dump_regs_template.v`'s own full 32-register dump. Output:
cycle count on line 1, then all 32 registers — whichever ones the profiled program's own `csrrs` epilogue
wrote counter values into, read back the same way every other register-comparison test in this repo already
works.

### K3: `sim/tools/profiler.py`

New tool, sibling to `bench_runner.py` (which stays untouched, per `docs/adr/0025`'s own note) — a different
report shape, not a new `--compare-*` axis. For each `sim/benchmarks/bench_*.s` kernel:

- **Run A** (defaults): the kernel body plus a fixed epilogue — inserted just before the kernel's own
  mandatory `halt:` label (present in every test program, `docs/adr/0011`) — reading `mcycle`/`minstret`/
  `mhpmcounter3-11` (still events 1-9 at reset) via `csrrs xN, CSR_ADDR, x0` into a fixed register
  convention (x19-x29; any free registers work, since the halt loop after them never reads anything, so
  there's no collision risk with whatever the kernel itself used).
- **Run B**: a preamble (`csrrwi`, before the kernel body so the *whole* kernel is observed) reprogramming
  `mhpmevent3-11` to events 10-18, then the same kernel body, then an epilogue reading the now-stall-cause
  counters into x19-x27.
- Compute per kernel: IPC/CPI (from real `minstret`/`mcycle`, not the ISS's own instruction count), branch
  accuracy, I$/D$ hit rate, aggregate stall %, the 9-way stall-cause breakdown, and a static instruction-mix
  histogram (from the kernel's own source text, not asm.py's internals — a lightweight mnemonic-prefix
  classification, since duplicating asm.py's own full decode for a "what kind of instruction" histogram
  would be needless).
- Output: a human-readable table for all 3 kernels to stdout, plus `--json` for a machine-readable report
  (stdlib `json`, no new dependency).

Labels/loop targets in every kernel are already symbolic (`asm.py` resolves them), so prepending the Run B
preamble never disturbs an existing kernel's own control flow — the one program built from scratch for this
phase (the MMU directed test) is the only one that needed hand-recomputed physical addresses, and only
because its own page-table mapping is inherently address-sensitive, not because of anything this phase's
own preamble/epilogue insertion does generically.

## Real bugs found, caught by running, not by hand-tracing

1. **Counter contamination during the Run B reprogramming window.** The first design reprogrammed all 9
   `mhpmeventN` registers, then immediately read all 9 counters back. Every counter kept counting under its
   OLD (reset-default) event for however many cycles its OWN reprogramming `csrrwi` took to reach the write
   stage — `bench_fib` (a kernel with **zero** memory accesses, confirmed by its own header comment and by
   directly tracing `dut.mem_stall`, which never asserts once in a 250-cycle trace of the exact assembled
   program) still reported `mem: 5` under the new stall-cause event, because `mhpmcounter5`'s own reset
   default (event 3, `icache_hit`) kept incrementing — and `icache_hit` is tied to 1 under `CACHE_NONE`,
   pulsing on nearly every fetch — for the few cycles before its own `mhpmevent5` write actually committed.
   Found by directly tracing `dut.mem_stall` against the profiler's own generated program and finding it
   provably always 0, contradicting the counter's own nonzero readback. Fixed by adding a second preamble
   pass, right after all 9 `mhpmeventN` reprogramming writes: `csrrw x0, MHPMCOUNTERn, x0` for each counter
   (an unconditional write, unlike `csrrs`/`csrrc`), zeroing every counter's residual contamination before the
   kernel body's own real execution starts.
2. **`FDivider.v`'s real 51-cycle latency (`QW=24+27`) exceeded every early calibration window**, making
   `fp_stall`/`float_load_use_hazard` look permanently zero until a much longer simulation window (and a
   cycle-by-cycle debug trace confirming `fp_stall` genuinely stays 1 the whole time, not stuck) revealed
   they simply hadn't resolved yet. Same root cause as `stall_div`'s own naive-33-cycle-not-14 miscalibration
   in `tb_perf_stallcause_k1.v` — this project's iterative dividers (`Divider.v`/`FDivider.v`) are
   consistently slower than a first guess assumes; every calibration in this phase was confirmed against an
   actual debug trace before being locked into a `check_val`, not paper-derived.

## Alternatives considered

- **Simulation-only hierarchical testbench tap** (mirroring how `bench_runner.py`'s own I$/D$ hit/miss
  counters are read). Rejected per the user's own scope choice — real `csrrs` reads keep the profiler
  meaningful on real FPGA hardware later.
- **Extending `bench_runner.py`** with a new `--profile` flag instead of a standalone tool. Rejected: a
  single-run many-new-counters report is a different shape than `bench_runner.py`'s own two-config-delta
  comparisons, and `docs/adr/0025` already flagged `bench_runner.py` as staying untouched.
- **Dynamic (loop-aware) instruction mix**, counted via new hardware events per opcode class. Rejected as
  disproportionate scope for one report line among many — static decode already answers "what kind of
  program is this" for these small, hand-written kernels; left as a future improvement if a real use case
  ever needs loop-weighted dynamic counts.
- **A `mem_stall_r`-style external contamination fix** (checking "was this counter's event already active
  last cycle" from the testbench/program side instead of a hard reset). Not seriously pursued once the
  simpler unconditional-zero fix (real bug #1) was found and confirmed sufficient — no evidence a subtler
  fix was needed.

## Validation strategy

- **K1**: 4 new directed tests (`tb_perf_stallcause_k1.v`, `_cache_k1.v`, `_mmu_k1.v`, `_latency_k1.v`),
  each calibrated against a real debug trace before locking in `check_val` expectations. One pre-existing
  test needed a deliberate update, not a regression fix: `tb_perf_csr_probe_j2.v`'s own "mhpmevent3 readback:
  only low 4 bits real (0xf)" check is now correctly 5 bits real (`0x1f`) — updated with a comment explaining
  why, not silently changed.
- **K2/K3**: `profiler.py` run end-to-end against all 3 `sim/benchmarks/bench_*.s` kernels; `bench_fib`'s own
  all-zero stall breakdown (a kernel with zero memory accesses) is itself a real correctness check, not just
  a plausibility read — confirms the tool doesn't manufacture stalls that don't exist.
- **Directed suite**: 77/77 (73 → 77, the 4 new K1 tests), zero-warning `iverilog -Wall -g2005 -I design
  -tnull design/*.v` compile.
- **Constrained-random cross-check**: 100/100 default, 40/40 per individual axis (`HAZARD_STRATEGY`,
  `PIPELINE_PROFILE`, `BRANCH_PREDICTOR`, `CACHE_MODE`, both latency axes, `--interrupt both`), 40/40 combined
  (`HAZARD_STRATEGY=1` × `PIPELINE_PROFILE=1` × `BRANCH_PREDICTOR=1` × `CACHE_MODE=1` × both latency axes),
  60/60 MMU-enabled — all clean, confirming the widened `mhpmevent` field and 9 new always-inert-at-reset
  event-pulse wires introduce zero regression.
- **A pre-existing gap found, NOT caused by this phase** (confirmed via `git stash` back to a clean Phase-J
  checkout, reproducing identically): combining all 6 axes **plus** `--interrupt both` simultaneously fails
  0/40 on unmodified Phase-J `master` too. The same 5-axis combination *without* `--interrupt` passes 40/40
  clean, on both the clean checkout and this phase's own changes. This is a `run_random_tests.py` generator
  gap unrelated to HPC CSRs or the profiler — left unfixed, out of this phase's own scope, worth a follow-up
  note for whoever next touches the random-test generator.

## Future improvements

- **Dynamic (loop-aware) instruction mix** — see Alternatives considered.
- **Formal verification** (Generation 1's own last remaining item, per `docs/ROADMAP_VISION.md`) —
  `docs/adr/0007`'s own already-deferred SVA/`bind`-based assertions are its most likely starting point,
  building on the plain `` `ifdef ASSERT_ON``-guarded procedural assertions that already exist. Not started.
- **The pre-existing `--interrupt` + full-combined-axis random-test gap** (see Validation strategy) — a
  `run_random_tests.py` generator-side issue, not an RTL one, worth its own investigation whenever that tool
  is next touched.

## Closing out Phase K

Phase K (K1-K5) is done. `docs/ROADMAP.md`, `docs/ARCHITECTURE.md`, and `handoff.md` are updated by this same
commit to reflect its status. Generation 1's one remaining item (formal verification) remains to be
sequenced next, per `docs/ROADMAP_VISION.md` — once it closes, all of Generation 1 (branch prediction,
caches, variable-latency memory, HPC CSRs, the profiler, formal verification) is done, closing out "RV32IMAF
Research Processor v1.0."
