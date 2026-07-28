# ADR 0016: Swappable hazard strategy — "compare hazard strategies" (Phase 6)

## Problem

`docs/ROADMAP.md` Phase 6 (research platform) names two concrete goals:
"compare hazard strategies" and "compare pipeline depths." `docs/adr/0015`
delivered the prerequisite parameterization cleanup those goals need to even
be mechanically possible, but didn't deliver either goal itself.

Of the two, "compare pipeline depths" is explicitly **not** attempted here:
the current `Forward.v`/`Hazard.v` design is tightly coupled to the exact
5-stage structure (forwarding sources hardcoded to EX/MEM and MEM/WB,
load-use detection hardcoded to a 1-stage lookahead) — genuinely supporting
variable depth means redesigning that from scratch, a much larger,
higher-risk undertaking against a core whose main asset is being fully
verified. This ADR delivers "compare hazard strategies" only, and documents
pipeline-depth variability as still-open future work rather than silently
skipping it.

## Design

### The alternate strategy

`design/HazardNoForward.v`: a conservative hazard unit that stalls on
*every* RAW hazard instead of forwarding around any of them. Selected via a
new `riscvpipeline.v` parameter, `HAZARD_STRATEGY` (0 = the original
`Hazard.v` + `Forward.v` pair, the default; 1 = `HazardNoForward.v`, with
`Forward.v` not instantiated and `forwardA`/`forwardB` tied to "no forward"
directly). Both branches are selected via `generate`/`if` at elaboration
time — the unselected branch isn't even instantiated, so `HAZARD_STRATEGY=0`
(every existing test/benchmark's assumption) costs nothing and needs no
changes to any of the ~25 existing `tb_*.v` files, none of which override
the parameter.

`Hazard.v` only ever needs to catch the *load-use* case (gap=1, producer is
a load) because `Forward.v` already covers every other gap=1/2 RAW hazard
via combinational forwarding, and `Register.v`'s write-first bypass
(`docs/adr/0002`) covers gap=3 for free regardless of strategy. With
forwarding removed entirely, `HazardNoForward.v` has to catch what
`Forward.v` used to:
- gap=1 (producer is `reg2`'s *current* output, about to enter EX): its
  result won't reach the register file for 2 more cycles (EX, then MEM,
  then WB) — stall.
- gap=2 (producer is `reg3`'s output, currently in MEM): one more cycle to
  WB — stall.
- gap=3 (producer is in WB this exact cycle): the write-first bypass
  already returns the correct value combinationally — no stall needed,
  identical to the forwarding strategy.

Re-evaluated live every cycle, same as `Hazard.v`'s existing check (no
countdown counter) — stall naturally clears once the producer has moved far
enough down the pipe. This composes correctly with `docs/adr/0013`'s
`mem_stall` load-latency interlock for free: `HazardNoForward.v` doesn't
need to know *why* `reg3` might be held for an extra cycle, only that it
still shows a matching producer for as long as it's held.

### Verification infrastructure

`sim/tb/dump_regs_template.v` and `sim/tools/run_random_tests.py` gained a
`__HAZARD_STRATEGY__`/`--hazard-strategy` override (default 0, fully
backward compatible) — the ISS itself needs no changes at all, since it
models architectural state, not pipeline microarchitecture, so it's equally
valid as a reference for either strategy. `sim/tb/bench_template.v` and
`sim/tools/bench_runner.py` gained the same override plus a
`--compare-strategies` mode that runs every `sim/benchmarks/bench_*.s`
kernel under both strategies and reports the cycle-count delta — this is
the actual "compare hazard strategies" deliverable, not just a correctness
toggle.

## Two real bugs found during verification

Both found by constrained-random cross-checking at `HAZARD_STRATEGY=1`
(not by directed tests or by reasoning about the design statically) —
consistent with this project's verification standard, and a useful
reminder that genuinely new hazard-detection logic needs the same
adversarial testing the original design got.

### A stall can silently swallow a jal/jalr's redirect

Symptom: `seed=54`'s random program executed a store
(`sb x13,31(x31)`) that should have been squashed by an unconditional
`jal x13,__L14` two instructions earlier redirecting past it. Traced with a
throwaway cycle-by-cycle debug testbench (watching `pc_o`/`inst_regde`/
`stall`/`unconditional_redirect`/`redirect_target` directly): on the exact
cycle the `jal` resolved (`unconditional_redirect=1`), `HazardNoForward.v`
also asserted `stall=1` — and `PC.v` gives `stall` priority over accepting
a new `pc_i`, so the redirect target was silently dropped and PC continued
sequentially instead of jumping.

Root cause, first layer: `jal`/`jalr` write a register (their link value)
*and* redirect the same cycle. The ID-stage instruction sitting behind the
`jal` happened to read that same link register (`x13`), so `hazard_ex`
fired for it — but that ID-stage instruction is one of the two squashed by
the redirect anyway (`reg1.v`/`reg2.v` already give `branch_taken` priority
over their own squash-vs-flush choice), so stalling for it was not just
unnecessary, it actively broke the redirect at the PC level.

First fix attempt: gate `hazard_ex` alone by `!branch_taken`. Re-running the
exact same seed still failed identically — **second layer**: an entirely
unrelated instruction can independently be sitting in `reg3` (whatever
`hazard_mem` is checking) with no connection to what's redirecting in
`reg2`. Any `stall` this module raises, from *either* condition, freezes
`PC.v` on whatever cycle `branch_taken` happens to be 1, regardless of
which hazard caused it. Fixed by gating the *entire* `stall`/`flush` output
— `assign stall = (hazard_ex | hazard_mem) & !branch_taken;` — confirmed
against the same seed after each attempt rather than assumed fixed.

This is the fourth occurrence of a related lesson this project keeps
relearning (`docs/adr/0009`, `0013`, `0014`): a new interlock/hazard signal
has to be checked against *every* other signal that shares a consumer
(here, `PC.v`'s single `stall` input), not just the specific producer that
motivated adding it.

## Alternatives considered

- **A counter-based stall duration** (compute "stall for exactly N cycles"
  up front) instead of a live, re-evaluated condition. Rejected: the live
  condition already self-clears correctly (including composing with
  `mem_stall`'s variable extra cycle, see Design), and a counter would
  duplicate that logic for no benefit while adding a new failure mode
  (wrong N).
- **Attempting "compare pipeline depths" in the same pass.** Rejected, see
  Problem — disproportionate risk for this pass, real future work.
- **Fixing only the specific `hazard_ex`/`jal` collision**, leaving
  `hazard_mem` ungated on the theory that its producer is never the
  redirecting instruction. Rejected once random testing demonstrated this
  reasoning was incomplete (see the bug writeup above) — the collision is
  about `PC.v`'s single `stall` input, not about which specific hazard
  check shares an instruction with the redirect.

## Validation strategy

- Full directed suite: 25/25 tests unchanged at `HAZARD_STRATEGY=0`
  (default, unaffected by this change at all).
- Constrained-random cross-check: 100/100 at strategy 0 (regression,
  confirms the harness changes didn't alter default behavior), then at
  strategy 1: 100 (found bug 1) → 100 again (found bug 2, same seed) → 150
  clean → 200 more clean → 100 more at a fresh seed range, all against the
  independent ISS.
- Targeted spot-check: every historically-significant hazard-pattern
  directed test (`forward_exmem.s`, `forward_memwb.s`, `load_use_stall.s`,
  `mem_stall_forward.s`, `div_forward.s`, `arith.s`'s full 22-register
  battery) re-run at `HAZARD_STRATEGY=1` via `dump_regs_template.v`,
  checked against the exact expected values their own `tb_*.v` files use at
  strategy 0 — all pass, directly confirming the specific scenarios that
  originally motivated `Forward.v`'s design (EX/MEM chain, MEM/WB forward,
  load-use, an unrelated load's stall not disturbing an unrelated
  forward, multi-cycle divide forwarding, and the gap=3 write-first-bypass
  case) are still handled correctly under the alternate strategy.
- `iverilog -Wall -g2005 -I design -tnull design/*.v`: clean, zero
  warnings, for both strategies (confirms `generate`/`if` correctly
  elaborates either branch).
- `bench_runner.py --compare-strategies`: all three benchmarks run cleanly
  under both strategies with sensible, consistent results (stall-only costs
  30–43% more cycles across the board) — see Future improvements for the
  actual numbers' significance.

## Future improvements

- "Compare pipeline depths," Phase 6's other named goal, remains
  unattempted (see Problem) — a real, substantially larger redesign.
- Current benchmark comparison (`make benchmark` with
  `--compare-strategies`): `HAZARD_STRATEGY=1` costs 43.3% more cycles on
  `bench_fib` (ALU/branch-heavy, most exposed to every RAW hazard being a
  full stall), 30.8% more on `bench_sum_array` (memory-heavy, partially
  masked by the load-use stall both strategies already pay), 36.1% more on
  `bench_bubble_sort` (mixed). Quantifies forwarding's actual value on this
  specific core rather than leaving it as a textbook assertion.
- A third strategy (e.g. forward from EX/MEM only, stall for MEM/WB-gap
  hazards) would be a natural next comparison point if useful — the
  `generate`/`if` pattern established here extends directly.
