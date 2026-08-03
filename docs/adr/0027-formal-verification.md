# ADR 0027: Formal verification (Phase L)

## Problem

Phase K (`docs/adr/0026-performance-profiler.md`) closed out the performance profiler. Per the
Generation 1 scope decision (`docs/ROADMAP_VISION.md`), formal verification is the one remaining item:
"prove register correctness, hazard correctness, forwarding correctness, pipeline correctness, CSR
correctness, via a formal tool (none set up in this project yet)."

No formal toolchain existed in this environment before this phase. Yosys + SymbiYosys (`sby`) were
installed for the first time this phase — OSS CAD Suite, Windows x64 release `2026-06-29`, extracted to
`C:\oss-cad-suite\oss-cad-suite\` (`bin` + `lib` both needed on `PATH`; `lib` for shared DLLs like
`libreadline8.dll`). The release's own Windows launcher stubs had a real naming defect (confirmed by
running): `yosys-smtbmc`/`yosys-witness` ship only as `<name>.exe.exe` + `<name>.exe-script.py`, which
Windows's own bare-name `.exe`-suffix PATH resolution can't find (it looks for `<name>.exe` and
`<name>-script.py`) — fixed locally by copying each to the name its own launcher stub expects.

Research (direct Yosys runs on this codebase, not assumed) found:
- Yosys's default Verilog-2005 `read_verilog` (no `-sv`) ingests this project's existing plain-Verilog RTL
  cleanly, including the full 2808-line `riscvpipeline.v` — confirming no wholesale RTL rewrite is needed.
- The 4 existing `docs/adr/0007` procedural assertions do **not** parse under Yosys with `-DASSERT_ON`
  (`$finish` inside an `always` block is rejected outright) — real formal work needs genuine SVA, written
  fresh.
- `CSR.v` is fully self-contained (zero submodule instantiations) — directly tractable, no blackboxing
  needed.
- `Divider.v`/`FDivider.v` (many-cycle iteration), the cache/MMU modules (multi-way arrays + multi-cycle
  FSMs), and the full `riscvpipeline.v` are not tractable first-pass whole-module BMC targets.

Three scope decisions confirmed via `AskUserQuestion` (all three the more-ambitious option, consistent with
every phase before this one):
1. **5 real BMC-proved modules**: `Register.v`, `Forward.v`, `Hazard.v`, `HazardNoForward.v`, plus a `CSR.v`
   subset (trap-entry/exit privilege swap).
2. **Rewrite the 4 existing `docs/adr/0007` procedural assertions as real SVA** — attempted; see Design and
   Real bugs/findings below for what this actually turned out to mean once the toolchain's real limits were
   discovered by running, not assumed.
3. **Attempt one abstracted whole-pipeline safety property**, flagged going in as real, possibly-incomplete
   stretch work.

## Design

### The toolchain's actual SVA subset (discovered by running, not from documentation)

Every one of the following was confirmed by writing a minimal reproduction and running it, not inferred:
- **No `bind`.** Icarus Verilog 12.0-devel (`iverilog -g2012`) raises a plain syntax error on a module-scope
  `bind` statement. This rules out sharing one SVA source between the simulation (`iverilog`) and formal
  (Yosys) flows via `docs/adr/0007`'s own originally-anticipated `bind`-based rewrite. Resolution: the 4
  existing procedural assertions in `design/*.v` are **left untouched** (they still work fine for
  simulation-time checking, zero regression risk), and this phase's new formal properties for the same 4
  invariants live entirely in `sim/formal/*.sv` as separate, standalone wrapper modules — strictly *stronger*
  (an unbounded k-induction proof vs. a bounded simulation check that only fires on whatever cycles a test
  happens to reach) even though the two don't share literal syntax.
- **No `default clocking`/`default disable iff`, no module-level named `property ... endproperty`, no
  `|=>`/`|->` implication operators.** All confirmed via minimal isolated reproductions before touching the
  real harness files — Yosys's open-source SVA subset here supports only **immediate assertions**
  (`assert (expr);` inside a procedural block) using `$past()` and ordinary boolean operators. Every formal
  property in this phase is written this way: `if (rst && $past(rst) && past_valid) assert (...);` — `rst &&
  $past(rst)` (reset held stable across both the triggering cycle and the checked cycle) stands in for what
  `disable iff` would otherwise express.
- **Hierarchical dot-references to a submodule's internal signals don't resolve.** `dut.regs[0]` (an array)
  and even `dut.mstatus` (a plain scalar reg) both come back as "implicitly declared... Range select out of
  bounds... Setting result bit to undef" — Yosys's `read_verilog` can't do what `iverilog`'s simulator does
  natively. Fixed by adding real output ports wherever a property needed to observe internal state:
  `mstatus_mpie`/`mstatus_sie`/`mstatus_spie`/`mstatus_spp`/`mstatus_mpp` on `CSR.v` (mirroring the exact
  `mstatus_mie = mstatus[3]` idiom already there) and `debug_regwrite_commit`/`debug_valid_commit` on
  `riscvpipeline.v` (mirroring `docs/adr/0012`'s existing `debug_x10` "unconnected changes nothing" shape).

### Register.v / Forward.v / Hazard.v / HazardNoForward.v (BMC, k-induction, all pass)

Each gets its own small wrapper module (`sim/formal/*_formal.sv`) instantiating the real module directly
(no blackboxing needed — all four are small, self-contained, mostly-combinational) plus properties restating
docs/adr/0007's own 4 invariants **and** the real semantic correctness each one was only ever a proxy for:
- **Register.v**: x0 reads 0 (via the read ports, not a broken hierarchical peek — see above), and the
  write-first bypass returns exactly the write data on a same-cycle write/read of the same register.
- **Forward.v**: `forwardA`/`forwardB` never select out of range (the original invariant), and select
  exactly the nearest valid source whose destination matches (the real priority-encoder correctness).
- **Hazard.v**: `stall === flush` (original), and stall asserts iff a real load-use hazard against a nonzero
  destination — including confirming, by running, that this module does *not* exclude `la_dest==0` (a
  load-use hazard against x0 still stalls in the real RTL, a harmless imprecision, not a bug, and the
  property is written to match the real RTL rather than an idealized "should").
- **HazardNoForward.v**: `stall === flush`, full stall-condition correctness, **and** `docs/adr/0016`'s own
  real historical bug restated directly as a formal property (`branch_taken` must never coexist with a
  stall this module raises) — proven true, not just spot-checked by the directed test that originally caught
  it.

### CSR.v trap-entry/exit privilege swap (BMC, k-induction, passes — with two real
environmental assumptions)

Properties: M-mode trap entry swaps MIE→MPIE and clears MIE, records the previous privilege into MPP, moves
`priv_mode` to M; a delegated S-mode trap does the identical SIE/SPIE/SPP swap, moving `priv_mode` to S;
`mret`/`sret` restore the mirrored pair (spec-default re-enable bit set); and `priv_mode` never drifts on any
other cycle. Getting a first honest counterexample here was expected (this is real hardware correctness
checking, not paperwork) — see Real bugs/findings below for the two genuinely necessary environmental
assumptions that turned out to be needed, and why they're additions to the *test harness*, not RTL changes.

### `design/reg4.v` gains `valid_regwb` (Phase L2, small additive RTL change)

A trivial passthrough of `valid_regem`, identical shape to `regWrite_regwb`'s own (including the `hold`
freeze semantics) — closes the loop `reg2`/`reg3` already opened (`docs/adr/0025` Phase J3's
`valid_regde`/`valid_regem`), giving a WB-stage "this is a real, non-squashed instruction" signal for the
whole-pipeline property. Wired at `m_reg4`'s instantiation in `riscvpipeline.v`. Zero behavior change to
anything existing.

### Whole-pipeline abstracted property — attempted, real toolchain blocker found, not closed

Property (built directly on `valid_regwb`): **a committing register write is always from a real,
non-squashed instruction** — `debug_regwrite_commit -> debug_valid_commit`, checked same-cycle (no `$past`
needed, both are the same WB-stage cycle's combinational reflections). Two new `riscvpipeline.v`
observability ports expose it (see above). `sim/formal/pipeline_formal.sby` blackboxes every submodule this
property doesn't need (`FRegister`/`FForward` via Yosys's `blackbox` command; `Bht`/`Btb`/`ICache`/`DCache`/
`MemoryLatencyModel` are never even elaborated at this harness's `CACHE_NONE`/`PREDICTOR_STATIC` defaults,
confirmed by Yosys's own "Selection did not match any module" warnings) and gives `FALU`/`FDivider`/`FSqrt`/
`FMADDUnit` **dummy concrete (non-blackbox) implementations** instead of blackboxing them, for two real,
separately-discovered reasons documented below.

## Real bugs/findings, all caught by running, not by hand-tracing

1. **A harness bug that looked like a real bug**: `dut.regs[0]`/`dut.mstatus`/`dut.priv_mode` hierarchical
   peeks silently became implicitly-declared, permanently-undefined stand-in signals in Yosys, producing
   spurious counterexamples with no relationship to real RTL behavior. Root-caused by cross-referencing
   Yosys's own compile warnings ("implicitly declared... Setting result bit to undef") rather than trusting
   the first counterexample. Fixed structurally (real output ports), not by suppressing the symptom.
2. **A second harness bug, in the same family**: shadow "previous cycle" registers with no explicit
   `initial` value are entirely unconstrained to a BMC solver at step 0 — confirmed directly in a
   counterexample trace where `reset_done_prev` came back `1` despite `reset_done` itself correctly starting
   at `0`, letting step 0 check fabricated "previous" state that never occurred. Fixed by explicitly
   initializing every shadow register, the formal-harness analog of a real reset.
3. **A same-time-step read/settle-ordering trap, found by cross-checking SBY's own generated counterexample
   testbench directly through `iverilog -g2012`**: an early version of the CSR harness used hand-rolled
   "shadow register in one `always` block, compared in a separate `always` block the same edge" logic (the
   same general shape `riscvpipeline.v`'s own pre-existing store-forward assertion uses) and got a spurious
   mismatch between a shadow register and a continuous `assign` output driven from a *different* `always`
   block's reg the same edge. Resolved by abandoning the hand-rolled shadow-register approach entirely in
   favor of `$past()` — Yosys's own primitive for exactly this "compare against last cycle" relationship,
   which doesn't have this class of self-inflicted ordering ambiguity.
4. **Two real environmental gaps in the CSR harness, found as genuine counterexamples, not toolchain
   confusion**: (a) the harness initially allowed `csr_write_en` targeting `MSTATUS` to fire the *same*
   cycle as `trap_taken`, and `CSR.v`'s own trap-wins priority chain doesn't defend bit-by-bit against a
   literal simultaneous raw overwrite of the same register the same cycle — but `riscvpipeline.v` never
   actually issues a CSR write the same cycle it also raises `trap_taken`/`mret_taken`/`sret_taken` (a trap
   preempts whatever instruction was in flight), so this is a real environmental assumption to add, not an
   RTL defect: `assume (!csr_write_en)` whenever any of the three fire. (b) the harness also allowed
   `trap_taken`/`mret_taken`/`sret_taken` to be simultaneously true, an impossible combination in the real
   integrated pipeline (exactly one EX-stage instruction exists per cycle) — fixed with
   `assume ($onehot0({trap_taken, mret_taken, sret_taken}))`. Both are standard formal practice — constrain
   the environment to the module's real operating contract, don't fuzz combinations its actual caller
   structurally prevents.
5. **`fp_round.vh`'s `shift_right_sticky` function has a genuinely non-synthesizable for-loop** (`for (k = 0;
   k < amt; k = k + 1)` where `amt` is a runtime function argument, not an elaboration-time constant) —
   confirmed as a real, structural Yosys `read_verilog` limitation (a variable-bound loop isn't
   representable as static hardware in general), not a parser bug. This is why `FALU.v`/`FDivider.v`/
   `FSqrt.v`/`FMADDUnit.v` need stand-in files for the formal flow at all — `iverilog` runs this fine because
   simulation just executes it as software each time, with no synthesizability requirement.
6. **Blackboxing those same 4 modules (rather than giving them dummy concrete bodies) hit a second, separate
   Yosys issue**: `ERROR: Module 'FALU' ... is a blackbox/whitebox module`, surfacing specifically while
   Yosys's own structural loop-detection pass was tracing a completely unrelated apparent combinational
   cycle (see finding 7) through the design — Yosys's loop detector cannot trace *through* an opaque
   blackbox to determine signal direction, and hard-errors rather than treating it as opaque-but-harmless.
   Fixed by giving the 4 F-extension units trivial *concrete* (non-blackbox) always-0 (or `done`-tied-high,
   to avoid an unrelated dummy-induced permanent `fp_stall`) bodies instead — exactly as valid for this
   property, since their real output only ever feeds `fflags`/`FRegister.v`, never the integer
   `regWrite`/`valid` commit path this property checks.
7. **A genuine, unresolved finding, not closed out this phase**: once the FALU-family blackbox issue was
   worked around, Yosys's `write_smt2` backend hard-refuses with `ERROR: Found logic loop in module
   PIPELINED` — a real apparent combinational cycle in the naive gate-level dependency graph:
   `dtlb_miss` → `branch_taken` → `interrupt_taken` → `pc_stall` → `dtlb_miss` (`dtlb_miss` is gated on
   `!branch_taken` per the stall-vs-redirect priority fix `docs/adr/0016`/`0022`/`0023`/`0024` each
   independently established; `interrupt_taken` is gated on `!pc_stall` per `docs/adr/0020` D9; `pc_stall`
   itself includes `dtlb_miss` in its own aggregate OR). SMT-based BMC via `write_smt2` requires a
   combinational DAG and cannot proceed past this. **This is very likely a false positive from Yosys's
   simple structural loop detector, not a real timing hazard** — this exact interrupt/MMU/stall interaction
   has been extensively constrained-random tested (`docs/adr/0020` D9's own 100-seed sweep, `docs/adr/0024`
   I5's full cross-product, `docs/adr/0025` J8's "everything at once" configuration, this project's own
   K4/L5 re-verification) with zero anomalies across every phase that touches any of these three signals —
   but not conclusively *proven* benign by this phase, which is exactly the honest distinction formal
   verification is supposed to draw and simulation alone cannot. Left as a genuine, real, actionable finding
   for a future investigation (see Future improvements), not silently dropped or force-fit.

## Alternatives considered

- **Sharing one SVA source between simulation (`iverilog -g2012`) and formal (Yosys) via `bind`**, matching
  `docs/adr/0007`'s own originally-anticipated follow-up. Ruled out by directly testing `bind` support in
  this `iverilog` version and getting a hard syntax error — not a design choice, a toolchain fact.
- **Blackboxing `FALU`/`FDivider`/`FSqrt`/`FMADDUnit`** for the whole-pipeline property (the originally
  planned approach). Rejected after being built and hitting the loop-detection/blackbox interaction (finding
  6) — a concrete dummy implementation was simpler and equally valid for this specific property.
- **Forcing the whole-pipeline property through by manually breaking the apparent combinational loop**
  (e.g., restructuring `dtlb_miss`/`interrupt_taken`/`pc_stall`'s own gating order). Rejected as out of this
  phase's own scope — that's a real RTL-timing question deserving its own dedicated investigation (is the
  loop real or a false positive?), not a quick edit made to force a formal tool through under time pressure.

## Validation strategy

- **5 formal proofs, all `PASS` via k-induction** (an unbounded correctness guarantee, not a bounded-depth
  check): `register_formal.sby`, `forward_formal.sby`, `hazard_formal.sby`, `hazard_noforward_formal.sby`,
  `csr_formal.sby`.
- **1 formal proof attempted, real toolchain blocker found and honestly documented, not closed**:
  `pipeline_formal.sby` (see Real bugs/findings #7).
- **Directed suite**: 77/77 unaffected (this phase's only simulation-visible RTL changes are the additive
  `valid_regwb`/`debug_regwrite_commit`/`debug_valid_commit`/`mstatus_*` ports/wires — zero behavior change).
- **Zero-warning `iverilog -Wall -g2005 -I design -tnull design/*.v` compile**, confirmed after every RTL
  edit in this phase.
- **80/80 fresh constrained-random cross-check** at default config, confirming the new ports introduce zero
  regression.

## Future improvements

- **The whole-pipeline logic-loop finding** (Real bugs/findings #7) — determine whether
  `dtlb_miss`/`branch_taken`/`interrupt_taken`/`pc_stall`'s mutual gating is a genuine combinational hazard
  or (far more likely, given this project's own extensive cross-product random testing of every phase that
  touches these signals) a Yosys structural-loop-detector false positive, then either restructure the
  gating to break the apparent cycle or find a formal flow that tolerates it, and finish the whole-pipeline
  proof.
- **A real `bind`-based rewrite of the 4 `docs/adr/0007` procedural assertions**, if a future toolchain
  choice (a different Verilog simulator, or Icarus eventually adding `bind` support) makes it possible to
  share one SVA source between simulation and formal — not possible with this environment's `iverilog`
  today, confirmed by running, not assumed.
- **CSR.v's own environmental assumptions** (Real bugs/findings #4) are specific to the trap-entry/exit
  property proved this phase; a future CSR.v property (e.g. covering `mideleg`/`medeleg` masking, or
  `mcountinhibit` gating) would need its own review of what's a genuine RTL invariant vs. an environmental
  assumption to add.

## Closing out Phase L — and Generation 1

Phase L (L1-L6) is done — 5 real, unbounded formal proofs (Register/Forward/Hazard/HazardNoForward/CSR
trap-entry-exit correctness), one honestly-documented incomplete stretch attempt (the whole-pipeline
property), and a genuine, actionable RTL-topology finding surfaced along the way. `docs/ROADMAP.md`,
`docs/ARCHITECTURE.md`, and `handoff.md` are updated by this same commit to reflect its status.

**This closes out Generation 1** (`docs/ROADMAP_VISION.md`): branch prediction (Phase E), caches (Phase G),
variable-latency memory (Phase I), HPC performance CSRs (Phase J), the performance profiler (Phase K), and
formal verification (Phase L, this ADR) are all done. "RV32IMAF Research Processor v1.0" is complete;
Generation 2 (RV64 migration) is next, per `docs/ROADMAP_VISION.md`'s own numbering.
