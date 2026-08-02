# ADR 0021: Branch prediction — BHT + BTB (Phase E of the redesign, the last phase)

## Problem

The user's five-phase redesign (`docs/adr/0018`'s Problem section) named variable pipeline depth
(Phase A, done), a code-quality pass (Phase B, partially done — item 2, signal-naming/port-ordering
conventions, remains deliberately deferred, see `handoff.md`), an F-extension port (Phase C, done,
`docs/adr/0019`), SoC integration (Phase D, done, `docs/adr/0020`), and **performance work (Phase E,
this ADR, the last phase)**. Phase A's own plan deliberately deferred designing Phase E in detail,
since "a predictor's design (misprediction penalty, where recovery squashes) interacts with however
Phase A's fetch-split work ultimately shapes the front end" — this ADR is that deferred design pass,
done once the post-Phase-A/D pipeline shape had settled.

Three parallel research agents confirmed, by direct reading rather than assumption, the actual shape
of the problem:

- **Today's fetch is, in effect, "always predict not-taken," with a fixed 2-cycle bubble penalty on
  every taken branch/jump/trap/mret.** A branch resolves in EX (`zero` from the ALU, `branch_regde`
  latched at the ID/EX boundary); `branch_taken`/`unconditional_redirect` squash both `reg1` and `reg2`
  the same cycle. `PC.v`/`Adder_1` produce `pc_o+4` unconditionally every cycle, with zero prediction
  logic — the PC-input mux only overrode to `redirect_target` after EX discovered a taken branch/jump.
  No branch-target address was computed anywhere before EX.
- **`PIPELINE_PROFILE`'s `reg1a` (Phase A) is a plain unconditional relay with no squash logic of its
  own** — its header documents two designs already tried and rejected by random testing: squashing it
  to a constant causes an infinite re-fetch loop, squashing it to `redirect_target` directly double-
  fetches the target. The actual fix extends `reg1`'s own existing squash window by one more cycle
  (`redirect_squash_extend_r`) rather than inventing a second, independent squash source. **This is the
  single most important lesson carried into this phase's design**: any new fetch-side redirect
  mechanism must extend the existing priority chain (squash > stall-hold > fresh-latch), never invent a
  second one — the same lesson `docs/adr/0020`'s D9 independently re-learned twice for interrupts
  (`!pc_stall`-not-`!reg2_hold` gating, and the `id_bubble_r` fallback for `mepc`).
- **The independent ISS oracle is fully transparent to branch prediction — confirmed, not assumed.**
  `sim/tools/iss.py`'s branch/jal/jalr handling just recomputes `self.pc` once per instruction with no
  stages, bubbles, or timing model at all. `docs/adr/0018` and `docs/adr/0016` had already established
  this exact transparency for `PIPELINE_PROFILE`/`HAZARD_STRATEGY`; a predictor changes *when* a branch
  resolves, never *what* it resolves to, so zero `iss.py` changes were needed — a real simplification
  relative to Phase D's D10/D11, which needed substantial new interrupt-timing machinery precisely
  because interrupts *do* inject new, ISS-unmodeled control flow. Misprediction recovery injects no new
  control flow at all, so `sim/tools/random_gen.py`'s existing forward-only-branch corpus needed no
  analog to D10's opt-in interrupt-injection mode.
- **This project has used the same swappable-subsystem pattern three times already**
  (`HAZARD_STRATEGY` — `docs/adr/0016`; `PIPELINE_PROFILE` — `docs/adr/0018`; the WbDecoder/Uart/Timer
  standalone-module precedent — `docs/adr/0020`): a closed, named enum parameter, a bit-exact default,
  a standalone testbench for every new module before pipeline integration, and the single highest-risk
  live-wiring commit isolated alone. `docs/adr/0016`'s own real bug — a stall silently swallowing a
  `jal`/`jalr` redirect because a new interlock wasn't checked against every existing signal sharing a
  consumer — is the exact bug class this phase's own new redirect logic needed to be checked against,
  since it shares `PC.v`'s input mux and the `unconditional_redirect`/`redirect_target` consumers with
  jal/exception/mret/interrupt.

Three scope decisions were made explicitly with the user before implementation (via a planning-tool
question, not assumed), all toward the more ambitious option — consistent with every prior phase's own
pattern:

1. **BHT + BTB, full speculative redirect** — not direction-only. A branch-history table of 2-bit
   saturating counters (direction) plus a branch-target buffer (predicted target address), covering
   conditional branches *and* `jal`/`jalr`.
2. **A swappable `BRANCH_PREDICTOR` parameter, bit-exact default** — `PREDICTOR_STATIC` (0) reproduces
   today's exact behavior forever; `PREDICTOR_DYNAMIC_BHT_BTB` (1) is the new predictor. Both
   benchmarkable via a new `bench_runner.py --compare-predictors` flag.
3. **Both `PIPELINE_PROFILE` values supported from the start** — not scoped to `PROFILE_5STAGE` only.

This made Phase E smaller than Phase C or D: six independently-verified steps (E1–E6), each ending with
the full suite passing again, per this project's established convention. Two genuine simplifications
relative to Phase D, confirmed by research rather than assumed: the ISS needed zero changes, and
misprediction recovery reuses today's exact 2-bubble squash mechanism, just re-gated on a different
condition, rather than needing a new squash-width design.

## Design

### The core change: from "squash on taken" to "squash on mispredict"

Today, `branch_taken`/`unconditional_redirect` meant "actually taken, so redirect and squash" — correct
only because fetch never speculated, so every actual taken outcome was a surprise to fetch. Once fetch
starts guessing:

- **Query**: combinationally, using whatever PC `PC.v` currently holds (`pc_o` — the same point
  `pc_new`'s own `Adder_1` already consumes), look up `Bht.v` (direction) and `Btb.v` (target). A hit
  requires *both* tables to agree there's something useful: `Bht.v`'s counter predicting taken, *and*
  `Btb.v` actually having a target on file — a direction-only "taken" with nowhere to redirect to is
  useless. This feeds a new, third arm into the PC-input mux (a `Mux2to1` chained in front of the
  pre-existing one): `redirect_target` (top priority, authoritative) > the predicted target (if
  `predict_taken_if`) > `pc_new` (default sequential).
- **Travels with the instruction**: `predict_taken`/`predict_target` are latched through `reg1`→`reg2`
  alongside the instruction (two new fields, mirroring how `readReg3` was threaded through pipeline
  registers in Phase C7), so they're available for comparison once the instruction reaches EX, two
  cycles later. Under `PROFILE_6STAGE_SPLIT_FETCH`, `reg1a` was extended to relay the prediction
  alongside its existing `pc_o` relay — the *query* for the PC-mux decision always uses live `pc_o`
  (matching `pc_new`'s own treatment, profile-independent), but the value *latched for later
  comparison* needs the same profile-aware one-cycle relay `imem_read_addr` itself already uses, so the
  prediction pairs correctly with whichever instruction it was actually made for.
- **Resolution becomes a comparison, not a one-way discovery**: `desired_taken = (branch_regde & zero) |
  jump_regde` and `desired_target = imm_sum` are the exact, unmodified expressions this file always
  used — merely named, not changed. `mispredict = (predict_taken_regde != desired_taken) |
  (desired_taken & (predict_target_regde != desired_target))`. Squash+redirect (`branch_or_jump_redirect`,
  folded into `unconditional_redirect`/`branch_taken` alongside the existing exception/mret/interrupt
  terms) now fires only on `mispredict`, not on every `desired_taken` — a correctly-predicted-taken
  branch costs zero bubbles. A misprediction still costs the same 2-bubble window today's design always
  paid (the same number of wrong-path instructions are in flight regardless of which way the guess went),
  redirected to `desired_taken ? desired_target : (pc_o_regde + 4)` — the fall-through case, reusing the
  already-computed `pc_plus4_regde` (jal's own link-value adder) rather than a second, redundant one.
- **Under `PREDICTOR_STATIC`**: `predict_taken`/`predict_target` are tied to 0 throughout (the
  `Bht.v`/`Btb.v` instances themselves are not even elaborated — the unselected `generate` branch, same
  convention as `HAZARD_STRATEGY`/`PIPELINE_PROFILE`), so `mispredict` collapses to exactly
  `desired_taken`, and `branch_or_jump_redirect`/`branch_or_jump_target` reduce to exactly what
  `unconditional_redirect`/`redirect_target` already computed before this phase. Bit-exact by
  construction, not merely tested to be.
- **`reg1.v`'s own `branch_regde`/`zero` ports are now tied to `1'b0`** at the instantiation site rather
  than fed the real wires, with the branch/jump redirect condition folded entirely into the `jump` port
  instead. Under `PREDICTOR_STATIC` this is bit-exact (idempotent with what `unconditional_redirect`
  already includes); under `PREDICTOR_DYNAMIC_BHT_BTB` it is essential, not just tidy — feeding `reg1`
  the raw, unfiltered-by-prediction condition would squash every actually-taken branch regardless of
  whether it was correctly predicted, defeating the feature entirely. `reg1.v`'s own file was not
  otherwise modified beyond adding the new `predict_taken`/`predict_target` pass-through fields (mirrors
  this project's "wrap, don't touch a verified module" convention, e.g. Phase D2's `DataMemoryBRAM.v`).
- **`HazardNoForward.v`, `other_redirect_taken`, `redirect_squash_extend_r`, `id_bubble_r` needed no
  changes to their own logic** — each of them consumes the top-level `branch_taken`/`unconditional_redirect`
  wires (or, for `other_redirect_taken`, independently recomputes the same underlying condition to avoid
  a combinational self-reference), and this phase preserved those wires' *role* ("a redirect is
  happening this cycle, for any reason") exactly, changing only their internal composition for the
  branch/jump term. Traced by hand before trusting it, not assumed — the same standard `docs/adr/0009`/
  `0013` set.
- **`Bht.v`/`Btb.v` training** fires from EX's ground truth, gated `!reg2_hold` for exactly the same
  reason `csr_write_en`/`trap_taken`/`mret_taken`/`fp_flags_we` already are: an instruction held in EX
  across multiple cycles (e.g. `mem_stall` from an unrelated older load still in MEM) must train the
  tables exactly once, on its real resolution, not once per held cycle. `Btb.v` is trained only when
  `desired_taken` (no target to record for a not-taken resolution); `Bht.v` trains on every resolution,
  taken or not.

### `Bht.v`/`Btb.v` — deliberately untagged

Both tables are small (`BHT_BTB_ENTRIES=32` default), direct-mapped, and untagged: two different PCs
sharing an index simply share one entry. This is safe, not merely convenient — a misprediction from
aliasing (or from a completely unrelated instruction that was never a branch at all) can never produce
a wrong architectural result, since EX's own ground-truth comparison always catches it and recovers
through the same path a genuine misprediction uses. Aliasing costs at most one extra bubble, never a
wrong answer, so a tag isn't needed for correctness — only for prediction *accuracy*, out of scope for
this phase (see Future improvements).

## Real design findings, caught by tracing before writing RTL

Matching this project's own "hand-trace before trusting a first design" precedent (`docs/adr/0009`,
re-invoked by D9 twice in Phase D):

1. **Reusing `Forward.v`/`Hazard.v`'s existing load-use hazard machinery unmodified was correct, not
   something needing new plumbing.** Speculatively-fetched instructions are ordinary instructions to
   every existing interlock — nothing about being on a "predicted path" changes how a load-use hazard,
   a multi-cycle divide, or an FPU op behaves. Misprediction recovery squashes wrong-path instructions
   at the same pipeline depth (`reg1`/`reg2`) they'd need to be squashed at regardless, before they ever
   reach a stage with side effects (MEM's store commit, WB's register write) — the same 2-cycle window
   that already made this safe pre-prediction.
2. **The PC-mux speculative arm had to query at `pc_o` (`PC.v`'s live output), not `imem_read_addr`.**
   Under `PROFILE_6STAGE_SPLIT_FETCH`, `imem_read_addr` is `reg1a`'s one-cycle-*delayed* relay of a past
   `pc_o` — using it for "what should fetch do next" would redirect based on an already-stale PC,
   reintroducing exactly the class of bug `reg1a`'s own header already warns about (its rejected
   "squash to `redirect_target`" design double-fetched for precisely this reason). The query for the PC
   mux and the value latched for later comparison are two different uses of the same underlying
   combinational result, needing two different treatments — mirroring the existing `pc_new`-vs-
   `imem_read_addr` asymmetry already in the file, not inventing a new one.
3. **A squashed pipeline bubble's stale `predict_taken` bit had to be explicitly zeroed, not left
   don't-care.** `mispredict`'s XOR-based comparison (`predict_taken_regde != desired_taken`) means a
   stale `predict_taken_regde=1` surviving into a squashed nop (`desired_taken=0` for it, correctly)
   would spuriously re-trigger a mispredict redirect for an instruction that was never really there.
   Zeroed in both `reg1.v`'s squash arm and `reg2.v`'s `ZERO_CONTROL_FIELDS`-adjacent
   `ZERO_DECODE_CONTEXT` macro, the same place every other per-instruction context field already is.

No bugs were found by *running* the design — the constrained-random cross-check passed clean on the
first attempt at every axis combination tried (see Validation strategy). This is notably different from
every prior phase's own experience (A3, C's FALU/FDivider/FMADDUnit, D9's two findings, D10/D11's five
findings), and is credited to the tracing above happening *before* writing the RTL, not after a failure
— the same discipline `docs/adr/0009` first established and this phase leaned on more heavily than most.

## Alternatives considered

- **Direction-only (BHT, no BTB), leaving `jal`/`jalr` unpredicted.** Rejected by the user's own scope
  decision: `jal`/`jalr` share the identical redirect/squash machinery as conditional branches once
  `unconditional_redirect` is restructured, so covering them costs no extra design complexity — only a
  BTB entry, which the design already needs for conditional-branch targets anyway.
- **A tagged BTB/BHT.** Rejected for this phase: the untagged design's worst case is an extra bubble,
  never a wrong answer (see Design's own correctness note) — a tag improves accuracy, not correctness,
  and this phase's scope is "does prediction work and pay off," not "how accurate can it be made."
  Noted as future work if a larger benchmark ever shows aliasing meaningfully hurting hit rate.
- **A correlating/two-level (gshare-style) predictor, or a return-address stack for `jalr`.** Rejected
  as the same "minimal, not maximal" spirit as Phase D's PLIC-lite decision — a single per-PC 2-bit
  counter and an untagged BTB are the smallest design that actually demonstrates the feature's real
  payoff (see the 11–24% cycle-count reduction in Validation strategy below); more sophisticated
  predictors are real future work, not attempted here without a measured need.
- **Reusing `MuxN.v`** for the 3-way PC-input select (redirect_target / predicted target / sequential),
  considered since the plan's own design notes suggested it as the natural fit. Rejected once actually
  writing the mux: `MuxN.v` is index-selected (a `sel` value chooses among a flattened bus), which would
  require constructing that index from the same priority logic anyway — a second `Mux2to1` instance
  chained in front of the existing one is simpler and more directly mirrors what the file already does
  at every other 2-way selection point, avoiding the "reuse an abstraction because it exists, not
  because it fits" trap this project's own principles warn against.
- **Gating `reg1`'s branch_regde/zero ports by `BRANCH_PREDICTOR` via a ternary**, rather than tying them
  to `1'b0` unconditionally. Rejected once traced through: `unconditional_redirect`'s new composition
  already fully covers the branch/jump redirect condition identically under both predictor settings (an
  OR-idempotent restatement under `PREDICTOR_STATIC`, the actually-needed narrower condition under
  `PREDICTOR_DYNAMIC_BHT_BTB`), so a parameter-conditional wire select would have been dead complexity —
  tying to 0 unconditionally is simpler and exactly as correct.

## Validation strategy

Every step ended with the full suite passing again before moving to the next, the same discipline as
every prior phase:

- **Full directed suite**: grew from Phase D's 47/47 baseline to 50/50 (three new files:
  `tb_bht_unit.v`, `tb_btb_unit.v`, `tb_branch_predictor.v`), all pre-existing tests bit-for-bit
  unchanged (every existing testbench defaults to `BRANCH_PREDICTOR=0`).
- **Zero-warning `iverilog -Wall -g2005` compile** across all of `design/*.v`, for both `generate`
  branches, confirmed after every step.
- **Bit-exact default, confirmed by construction and by running**: the full directed suite and a
  60-seed random cross-check both passed identically at `BRANCH_PREDICTOR=0` after E4's integration —
  the "no possible diff for the default" bar every prior phase's own parameter-introduction step
  established.
- **Constrained-random cross-checking at `BRANCH_PREDICTOR=1`**: 60/60 on the first attempt, then a
  further 200/200 at a fresh seed range, 80/80 combined with `PIPELINE_PROFILE=1`, 40/40 combined with
  `HAZARD_STRATEGY=1`, and 90/90 total combined with all three interrupt-injection modes
  (`timer`/`uart`/`both`, 30 seeds each) — every axis combination clean, confirming the design's
  profile-agnostic core logic and its independence from interrupt-injection's own termination-safety
  machinery, both by direct reasoning (see Design) and by running.
- **A dedicated directed test** (`sim/tb/tb_branch_predictor.v` + `sim/programs/branch_predict.s`, a
  5-iteration backward-branch loop) confirms the exact per-iteration state-transition story a 2-bit
  saturating counter predicts: iterations 1–2 mispredict (cold miss, then still-weakly-not-taken),
  iterations 3–4 correctly predict with **zero** measured mispredicts (the actual point of this phase),
  iteration 5 mispredicts again (the loop genuinely exits while the counter still says taken) — every
  one of the five hand-derived expectations matched on the first run, hierarchically tapping
  `riscvpipeline.v`'s own internal `mispredict` wire the same way this project's own bug hunts
  (Phase D8/D11) already used that technique, turned into a permanent check instead of a one-off
  `$display`.
- **Standalone module verification before pipeline integration** for both new modules (`Bht.v`: 14
  checks — full 2-bit counter FSM transition table in both directions, index aliasing; `Btb.v`: 12
  checks — store/lookup/overwrite round trip, cold-miss default, index aliasing), mirroring
  `tb_divider_unit.v`/Phase C's `tb_fregister_unit.v`/Phase D's `tb_wbdecoder_unit.v` precedent. Also
  extended `tb_reg1a_unit.v` (+4 checks) to cover the new prediction-relay fields under
  `PROFILE_6STAGE_SPLIT_FETCH`, the same unconditional-relay treatment `pc_o` itself already has.
- **Real, measured performance improvement** (`bench_runner.py --compare-predictors`, the actual point
  of this phase): on the three existing branch/loop-heavy kernels —

  | kernel              | cycles (static) | cycles (BHT+BTB) | Δ       | IPC (static → dynamic) |
  |---------------------|-----------------:|------------------:|--------:|-------------------------|
  | `bench_bubble_sort` | 313              | 279               | −10.9%  | 0.668 → 0.749           |
  | `bench_fib`         | 215              | 163               | −24.2%  | 0.716 → 0.945           |
  | `bench_sum_array`   | 263              | 215               | −18.3%  | 0.639 → 0.781           |

  All three kernels' `iss.py`-derived x10 correctness cross-check passed identically at both predictor
  settings — the cycle-count reduction is real, not a symptom of the benchmark computing something
  different or less.

## Future improvements

- **A tagged BTB/BHT** — see Alternatives; future work only if a larger benchmark shows aliasing
  meaningfully hurting hit rate.
- **A correlating/two-level (gshare-style) predictor, or a return-address stack for `jalr`** — see
  Alternatives; future work only if a measured accuracy shortfall on realistic benchmarks motivates it.
- **A `--compare-predictors` × `--compare-profiles` × `--compare-strategies` three-way matrix** in
  `bench_runner.py` — the current tool varies exactly one axis per invocation (now three axes total,
  any two held fixed); a full cross-product report is straightforward given the same `run_bench`
  plumbing, just not built here without a concrete need.
- **A genuinely larger `BHT_BTB_ENTRIES`** validated against a larger benchmark corpus — the current
  default (32) was sized for this project's existing tiny test programs (32-instruction budget per
  `sim/run_tests.sh`), not tuned against any realistic working-set size.

## Closing out the five-phase redesign

This is the last of the five phases the user originally scoped (`docs/adr/0018`'s Problem section):
variable pipeline depth (A) → code-quality (B, item 2 still deliberately deferred) → F-extension
(C) → SoC integration (D) → branch prediction (E, this ADR). `docs/ROADMAP.md` and `handoff.md` are
updated by this same commit to reflect all five phases' status, and `docs/ARCHITECTURE.md`'s §15 row 5
("Caches/branch prediction not started") is corrected to reflect that branch prediction now exists
(caches/MMU/dual-issue remain open, unrelated future work, per that row's own remaining scope).
