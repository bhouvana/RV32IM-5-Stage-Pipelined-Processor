# ADR 0025: Hardware performance-monitoring CSRs (Phase J)

## Problem

Phase I (variable-latency memory) closed out at I8 (`docs/adr/0024-variable-latency-memory.md`). Per the
Generation 1 scope decision (`docs/ROADMAP_VISION.md`), the remaining Generation-1 items — HPC
performance-monitoring CSRs, a performance profiler, formal verification — are real, sequenced work. This
is the next of them: hardware CSRs for cycle count, instructions retired, branches retired, branch
mispredicts, I$/D$ hits/misses, pipeline stall cycles, interrupt count, and exception count
(`docs/ROADMAP_VISION.md`'s own exact event list; IPC/CPI are derived software ratios of mcycle/minstret,
not separate hardware — real cores never build a hardware divider for this). The **profiler** (automated
reports consuming these counters) is a separate, later Generation-1 item, explicitly out of scope here.

Two scope decisions confirmed with the user (`AskUserQuestion`, both the more-ambitious option, consistent
with every phase before this one): **full `mhpmevent`-configurable counters** (a fixed set of countable
hardware events, each of 9 generic counters independently selects which event it tracks via its own
`mhpmeventN` register — not 9 single-purpose hardwired counters), and **read-write counters** (real
privileged-spec `csrrw`/`csrrs`/`csrrc` can set arbitrary values, matching how a real OS uses these for
context-switch save/restore — not pure read-only hardware counters).

Research (three parallel Explore agents plus direct reads of `CSR.v`/`reg1.v`/`reg2.v`/`reg3.v`/`reg4.v`/
`riscvpipeline.v`/`DCache.v`/`ICache.v`) found:

- **Verification is safe by construction.** The constrained-random cross-check
  (`sim/tools/run_random_tests.py`'s `run_one()`) compares a fixed positional dump — 32 int regs,
  `mem_size` memory bytes, 32 float regs, `fflags`, `frm` — never a CSR-address walk. `sim/tools/iss.py`
  has no cycle-count notion at all and only models a fixed, named CSR subset never compared against RTL
  by the random harness. New performance CSRs need **zero ISS changes** and are provably safe to exclude
  from `dump_regs_template.v` — the same "RTL-only, not ISS-modeled" precedent `docs/adr/0023` already
  established for cache-miss counters.
- **Register-array shape.** `CSR.v` was, until this phase, 100%-hand-named registers, not because arrays
  are unwelcome here but because no two CSRs had ever been structurally identical (each has unique
  masking/trap-interaction logic — literally why `docs/adr/0020` D11 split the always-block per-register).
  The 9 new counters genuinely *are* identical (same 64-bit up-counter, same event-select mux, zero
  trap-entry coupling) — exactly the shape `Tlb.v`'s real indexed array and `DCache.v`/`ICache.v`'s
  `generate for` per-way blocks already reach for elsewhere in this project.
- **Instruction-retirement counting is the hardest part.** No pipeline register carried a "this is a real
  retiring instruction, not a squash-bubble" bit — control fields squashed by `branch_taken`/`flush`/
  `reg3_bubble` are zeroed to the same bit pattern a legitimate real instruction (e.g. a not-taken branch,
  or a store) can also produce, indistinguishable after the fact. `riscvpipeline.v`'s own `id_bubble_r`
  (declared near `interrupt_taken`) already tracks exactly the needed upstream validity — reused directly.

## Design

### New CSR addresses (`design/riscv_defs.vh`)

Spec-standard where one exists: `MCYCLE`=0xB00, `MCYCLEH`=0xB80, `MINSTRET`=0xB02, `MINSTRETH`=0xB82,
`MCOUNTINHIBIT`=0x320 (bit0=CY inhibits mcycle, bit2=IR inhibits minstret, bits 3-11 inhibit each
`mhpmcounter`; bit1 and every bit past what this core implements are hardwired 0). `MHPMEVENT3`-
`MHPMEVENT11`=0x323-0x32B, `MHPMCOUNTER3`-`MHPMCOUNTER11`=0xB03-0xB0B, `MHPMCOUNTER3H`-
`MHPMCOUNTER11H`=0xB83-0xB8B — 9 counters for 9 events, sized to exactly what Generation 1 asked to
observe rather than the real spec's up-to-29. Each `mhpmeventN` stores its event index in the low 4 bits
only (0=off, 1-9 select one of the 9 events below; the real spec leaves event encoding fully
implementation-defined) — reset default `N-2` (`mhpmcounter3` defaults to event 1, ... `mhpmcounter11`
defaults to event 9), so a fresh boot already has all 9 events observable with zero configuration while
remaining fully software-reconfigurable.

### `design/CSR.v`: a genuine indexed array, not 9 hand-unrolled registers

```verilog
reg [XLEN-1:0] mhpmcounter_lo [0:8];
reg [XLEN-1:0] mhpmcounter_hi [0:8];
reg [3:0]      mhpmevent      [0:8];
```

A `generate for` OR-accumulator (mirroring `DCache.v`'s own `hit_data_acc` pattern) resolves a read at a
variable index without Icarus flagging "sensitive to all N words" (the same warning `DCache.v`/`ICache.v`'s
own header comments already document dodging via `generate`+`assign` instead of a procedural `always @*`
loop). The write side uses a plain `integer`-indexed `for` loop *inside* the module's single
`always @(posedge clk)` block — safe here, unlike the read side, because a `posedge clk`-sensitive block's
sensitivity list is just `posedge clk`, not `*`; the specific warning class only applies to combinational
blocks.

`mcycle`/`minstret` are separate 64-bit register pairs (not part of the array — they're architecturally
fixed, not reconfigurable, matching the real spec). `mcycle` increments unconditionally each cycle unless
`mcountinhibit[0]`; `minstret` increments on `instret_pulse` unless `mcountinhibit[2]`. A same-cycle
software write to either takes priority over the hardware auto-increment (spec-silent on this exact race;
the simpler, common real-hardware choice).

### Event pulse sources (9 events, index 1-9 into `mhpmevent`, 0=off)

1. **Branches/jumps retired** = `bp_update_valid` (already exactly-once-per-real-branch/jump reaching EX,
   gated `!reg2_hold` — reused verbatim, no new gating needed).
2. **Branch/jump mispredicts** = `mispredict & !reg2_hold` (same gate as #1, applied consistently).
3. **I$ hit** / 4. **I$ miss** — new gating needed. The existing `icache_miss` is a *level* held for the
   whole fill (`bench_template.v` needs an edge-detector to count it once) and would double-count a hit
   reused every cycle of an unrelated stall (PC frozen on the same address, `icache_hit` stays 1 the whole
   time). New `reg pc_stall_r <= pc_stall;` gives "was fetch already stalled last cycle";
   `icache_access_new = !pc_stall_r && (!translate_enable||itlb_hit) && !branch_taken &&
   !redirect_squash_extend_r` (the same qualifying conditions `icache_miss` already uses) then
   `icache_hit_pulse = icache_access_new && icache_hit`, `icache_miss_pulse = icache_access_new &&
   !icache_hit`.
5. **D$ hit** / 6. **D$ miss** — new output ports on `DCache.v` (see Real bugs found below — the naive
   first design double-counted read-hits).
7. **Pipeline stall cycles** = `pc_stall` itself, sampled every cycle it's 1 — the one event that counts
   duration, not discrete occurrences (matches how "cycles lost to stalling" is normally reported; `pc_stall`
   has no branch-redirect component, so a spinning `jal` loop contributes nothing further to it once
   steady-state).
8. **Interrupts taken** = `interrupt_taken` (already `!pc_stall`-gated, no extra gating needed).
9. **Exceptions taken** = `exception_taken & !reg2_hold` (the same reused pattern `CSR.v`'s own
   `trap_taken` already relies on for exactly-once firing).

### Instruction-retirement counting: the `valid` bit

`design/reg2.v` gained a `valid` input / `valid_regde` output, folded into the existing
`` `ZERO_CONTROL_FIELDS`` macro (covers reset/`branch_taken`/`flush` for free) with one explicit
`valid_regde <= valid;` in the normal (else) arm. Wired `.valid(!id_bubble_r)` at the call site.
`design/reg3.v` gained a plain `valid_regde`-in/`valid_regem`-out pair (no internal logic of its own,
matching every other field there — `reg3.v` is a plain latch-or-hold register, all bubbling happens at the
riscvpipeline.v call site). Wired `.valid_regde(valid_regde && !reg3_bubble)`, reusing the exact `_to_reg3`
naming convention `regWrite_to_reg3` etc. already use.

**`reg4.v` needed no changes.** `mem_stall` already gates reg3 and reg4 in lockstep — so
`instret_pulse = valid_regem && !mem_stall` (sampled the same cycle reg3→reg4 actually latches) is already
exactly-once-per-retirement. This mirrors the existing `bp_update_valid = (branch_regde | jump_regde) &
!reg2_hold` shape precisely: gate on the *producer's* own hold signal at the point of transition, not on
the consumer's already-latched, possibly-stale level. Using `valid_regwb` instead would have double-counted
every instruction that rides out a multi-cycle `mem_stall` sitting in reg4.

## Real bugs found, caught by running a calibration trace, not by hand-tracing

Consistent with every phase since F: the design above was hand-traced carefully before writing RTL
(same discipline `docs/adr/0009` established), and it still shipped with real bugs only *running* actual
simulation found.

1. **D$ read-hit double-counting.** The first `access_hit`/`access_miss` design was symmetric:
   `state==S_IDLE && (req_read||req_write) && hit/!hit`. This is correct for a write-hit (resolves
   combinationally, same cycle, never leaves `S_IDLE`) and for a miss (state leaves `S_IDLE` for
   `S_WB`/`S_FILL` immediately and doesn't return until the whole fill completes, by which point the caller
   has long since advanced — confirmed clean by the calibration trace). It is **wrong for a read-hit**:
   `DCache.v` transitions `S_IDLE`→`S_HIT_RD`→`S_IDLE` over 2 cycles, with `mem_stall` held for both — but
   the caller (`riscvpipeline.v`) doesn't actually advance `reg3` until the cycle *after* `mem_stall` drops.
   By the time the FSM returns to `S_IDLE`, the same still-stale `req_read`/`req_addr` is still being
   presented, and `state==S_IDLE && req_read && hit` fires a second time for the identical access. Found by
   a cycle-by-cycle debug trace of a small directed program (`sim/programs/perf_cache_j5.s`): a naive design
   produced 4 D$ "hit" pulses for 3 real reads. An external fix (an additional "was mem_stall already
   asserted last cycle" gate, mirroring `pc_stall_r`) was tried first and **rejected** — it conflated "this
   same request repeating" with "a different, unrelated instruction's own preceding stall," causing a
   genuine new miss immediately following a hit to be incorrectly suppressed (confirmed by running: total
   count *dropped below* the real 5, not just failed to double-count). The actual fix lives entirely inside
   `DCache.v`: count a read-hit at its own `S_HIT_RD` completion cycle instead of the `S_IDLE` request
   cycle, `state==S_HIT_RD && req_read && req_addr==served_addr_r` — mirroring `resp_ready`'s own read arm
   exactly, gated on the same latched-address-match `docs/adr/0023`'s own G7 bugfix already established for
   the identical "a bare level/state can't distinguish still-the-same-request from a new one" reason. This
   fires exactly once per read-hit since `state` can't re-enter `S_HIT_RD` without a fresh `S_IDLE` request
   first.
2. **Branch/mispredict/I$/D$ counters keep counting through the mandatory halt spin-loop.** Not a bug —
   architecturally correct behavior (every real spin-loop `jal` iteration genuinely retires and genuinely
   mispredicts, since this core's static predictor always guesses "not taken" and an unconditional backward
   jump is architecturally always taken) — but it meant every directed test in this phase needed its
   checkpoint chosen *before* the spin loop begins, not at whatever delay an existing test already used for
   unrelated architectural checks. `tb_branch_predictor.v` needed a second, earlier checkpoint added
   specifically for this reason (its own original `#400` checkpoint remains for `x11`'s own writeback,
   which — confirmed by the same debug trace — doesn't land until *after* the spin loop's own first
   iteration).

## Alternatives considered

- **Fixed-purpose, single-event hardwired counters** (one dedicated CSR per event, no `mhpmevent`
  selection at all). Rejected per the user's own scope choice — the full `mhpmevent`-configurable design
  was picked as the more-ambitious option, consistent with this project's established pattern.
- **Read-only hardware counters** (no software write path, mirroring `mip`'s hardware-driven bits).
  Rejected per the user's own scope choice — full read-write, matching the real privileged spec's OS
  save/restore use case, was picked instead.
- **9 hand-unrolled named registers in `CSR.v`**, matching every other CSR's own style. Rejected: these 9
  counters are the first genuinely structurally-identical CSR group in this file, and a real indexed array
  is both less code and matches this project's own established idiom for "N identical things" (`Tlb.v`,
  `DCache.v`/`ICache.v`'s per-way `generate` blocks).
- **Gating D$'s read-hit pulse externally** (a `mem_stall_r`-style register in `riscvpipeline.v`, mirroring
  `pc_stall_r`). Rejected after being built and found wrong by running (see Real bugs found #1) — it
  conflated two different reasons `mem_stall` could have been high the previous cycle.

## Validation strategy

Every step ended with the full suite passing again before moving to the next:

- **J1**: address declarations only, no consumers — compiles clean, zero behavior change.
- **J2**: `CSR.v` storage + read/write, event inputs tied to 0. `tb_perf_mcycle_j2.v` (mcycle's exact
  wall-clock cycle count, hand-derived and confirmed against this project's clock/reset timing) +
  `tb_perf_csr_probe_j2.v` (read/write/masking round-trip for every new address, mirroring
  `tb_mmu_csr_f1.v`'s own "probe raw storage before any live consumer exists" precedent).
- **J3** (isolated, highest-risk step): the `valid`-bit threading + `instret_pulse`. `tb_perf_instret_j3.v`
  on a 10-instruction hazard-free straight-line program, hand-derived and confirmed exact expected
  `minstret_lo`.
- **J4**: branches-retired + mispredict pulses, extending the existing `tb_branch_predictor.v` (its own
  already-validated 5-branch/3-mispredict ground truth doubles as this pulse pair's expected values).
- **J5**: I$/D$ hit/miss pulses. New `sim/programs/perf_cache_j5.s` + `tb_perf_cache_j5.v`; this is where
  the read-hit double-counting bug (above) was found and fixed.
- **J6**: stall-cycle/interrupt/exception counters, extending `tb_ecall_trap.v`, `tb_timer_interrupt.v`,
  and `tb_load_use_stall.v` with one counter check each (reusing each program's own already-established
  ground truth).
- **J7**: `mcountinhibit` gating (`tb_perf_countinhibit_j7.v`), confirmed via relative before/after
  snapshots rather than exact absolute values — inhibit mcycle/minstret/mhpmcounter3 together, confirm all
  three frozen (mhpmcounter3's own first branch-retirement pulse genuinely fires during the inhibited
  window but is correctly blocked, not just "hasn't happened yet"), re-enable, confirm all three resume.
- **J8**: full cross-product constrained-random re-verification (`HAZARD_STRATEGY` × `PIPELINE_PROFILE` ×
  `BRANCH_PREDICTOR` × `CACHE_MODE` × MMU × both latency axes, including interrupt-injection modes and the
  combined "everything at once" configuration) — confirming the new `valid`-bit plumbing (which touches
  `reg2`/`reg3`'s shared always-blocks broadly) introduced zero regression, and confirming by construction
  that the fixed-shape dump comparison genuinely can't see any of the new CSRs (per the Problem section's
  own research finding).
- **Zero-warning compile throughout**: `iverilog -Wall -g2005 -I design -tnull design/*.v` stayed clean
  across every step.
- Directed suite grew from 68/68 (end of Phase I) to 73/73.

## Future improvements

- **The performance profiler** (Generation 1's own next item, per `docs/ROADMAP_VISION.md`) is what
  actually *consumes* these counters for automated reports (pipeline utilization, stall breakdown, branch
  accuracy, cache statistics, IPC, CPI, instruction mix) — deliberately not built in this phase.
  `bench_runner.py` is untouched.
- **Per-cause stall breakdown.** `mhpmcounter9`'s own "pipeline stall cycles" event is a single aggregate
  (any `pc_stall` source) — splitting by cause (load-use, div, mem, fp, itlb, dtlb, icache, imem_wait)
  would need either more events or a wider `mhpmevent` encoding. Left to the profiler phase, which can
  derive this via its own instrumentation if a real use case needs it; Generation 1's own event list never
  asked for a per-cause breakdown.
- **`sscofpmf`-style overflow interrupts.** The real privileged spec optionally lets an `mhpmcounter`
  overflow raise an interrupt (Sscofpmf extension). Out of scope — no real use case on this core today, and
  64-bit counters overflow astronomically rarely for any test this project runs.

## Closing out Phase J

Phase J (J1-J9) is done. `docs/ROADMAP.md`, `docs/ARCHITECTURE.md`, and `handoff.md` are updated by this
same commit to reflect its status. Generation 1's remaining new items (a profiler, formal verification)
remain to be sequenced next, per `docs/ROADMAP_VISION.md`.
