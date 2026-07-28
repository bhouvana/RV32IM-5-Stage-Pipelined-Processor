# ADR 0018: Variable pipeline depth — "compare pipeline depths" (Phase 6, Phase A of the redesign)

## Problem

`docs/adr/0016` delivered "compare hazard strategies," the first of Phase 6's
two named research-platform goals, and explicitly deferred the second,
"compare pipeline depths," as disproportionate risk against a fully-verified
core: `Forward.v`/`Hazard.v` were tightly coupled to the exact 5-stage
structure (forwarding sources hardcoded to EX/MEM and MEM/WB, load-use
detection hardcoded to a 1-stage lookahead), so genuinely supporting variable
depth meant a redesign from scratch.

The user later asked for a larger, explicit five-phase redesign of this core
(variable pipeline depth, a code-quality pass, an F-extension port, SoC
integration, and performance work), sequenced so the currently-verified core
is never left broken mid-flight. This ADR covers Phase A of that redesign —
variable pipeline depth — landed as six separate, independently-verified
commits (A1–A6), each ending with the full suite passing again, per this
project's own established convention.

**What "variable" honestly means here** (matching `docs/adr/0015`'s "named,
not truly variable" honesty convention): a closed, named `PIPELINE_PROFILE`
enum on `PIPELINED` — `PROFILE_5STAGE` (0, default, today's exact structure,
bit-exact forever) and `PROFILE_6STAGE_SPLIT_FETCH` (1, new) — not a free
integer implying arbitrary depths. Splitting fetch (IF1/IF2) was chosen as
the first alternate depth specifically because it is structurally cheap and
honestly verifiable: it needs **zero** changes to `Forward.v`, `Hazard.v`,
`reg2`/`reg3`/`reg4`, the divider interlock, the BRAM interlock, or CSR
gating, because all of those anchor at the ID/EX/MEM/WB boundaries, which a
fetch-side split never touches. Splitting EX/MEM (branch-resolve-early,
cache-miss stalls) is the genuinely hard half of "compare pipeline depths"
and remains **explicitly out of scope** here, staying deferred exactly as
`docs/adr/0016` already documented — see Future improvements.

## Design

### A1 — the parameter, no behavior change

`PIPELINE_PROFILE` declared on `PIPELINED` (`design/riscvpipeline.v`),
default `PROFILE_5STAGE=0`, not yet consumed anywhere — a pure documentation
commit mirroring `docs/adr/0015`'s parameter-declared-before-consumers
staging. No possible diff: zero consumers.

### A2 — `reg1a`, standalone

`design/reg1a.v`: a new IF1/IF2 relay register mirroring `reg1.v`'s shape (a
single registered PC field), verified standalone first
(`sim/tb/tb_reg1a_unit.v`, mirroring `tb_divider_unit.v`'s
verify-before-integration pattern) before touching the live pipeline. Wired
into `riscvpipeline.v` via `generate if (PIPELINE_PROFILE == 0) ... else
... endgenerate` — the exact template `docs/adr/0016` established for
`HAZARD_STRATEGY` — but not yet consumed by anything downstream; this step
only proves the module elaborates and behaves correctly under both profiles
in isolation.

### A3 — wiring profile 1 live (the highest-risk single commit)

`InstructionMemory`'s read address moves from `PC.v`'s combinational `pc_o`
to `reg1a`'s registered output (`imem_read_addr`) under
`PROFILE_6STAGE_SPLIT_FETCH` — still a combinational memory read;
retiming `InstructionMemory.v` to a synchronous BRAM (mirroring
`docs/adr/0013`'s `DataMemoryBRAM.v`) is its own future item, not attempted
here. `pc_stall` fans out to `reg1a` in addition to `PC.v`/`reg1` (same
wire, one more consumer). This step found and fixed three real bugs, none
assumed away — all found by actually running constrained-random programs at
profile 1, not reasoned out in advance:

1. **PC/instruction pairing bug.** `reg1` (IF2/ID) was still paired with
   `PC.v`'s live `pc_o` instead of the PC that actually fetched its
   instruction (`imem_read_addr`) — under the split-fetch profile these
   differ by one cycle, silently corrupting every PC-relative computation
   downstream (branch/jal targets, `auipc`, `jal`'s link address). Fixed by
   pairing `reg1`'s `pc_o` input with `imem_read_addr` instead of `pc_o`
   directly.

2. **Squash-to-0 infinite loop.** `reg1a`'s squash-to-0 was copied from
   `reg1.v`'s own squash pattern without re-deriving whether it actually
   applied. It doesn't: `reg1.v`'s squashed output feeds a decode stage
   whose own control signals make a zeroed PC irrelevant downstream — safe.
   `reg1a`'s output, unlike `reg1`'s, is unconditionally used as a real
   `InstructionMemory` read address every single cycle. Zeroing it on a
   redirect re-fetches whatever is really stored at address 0 (typically the
   program's own first instruction) forever — a genuine infinite loop, not a
   transient glitch.

3. **Duplicate-fetch bug (from the first fix attempt).** Squashing `reg1a`
   to `redirect_target` instead (fixing the loop) turned out to duplicate
   the target fetch: `reg1a` reaches `redirect_target` once via the explicit
   squash, then reaches it *again* one cycle later via its own normal relay
   of `PC.v`'s already-corrected `pc_o` — fetching the redirect target
   twice. **The actual fix**: `reg1a` is a plain, unconditional relay with no
   squash notion at all; instead, `reg1`'s own squash window is extended by
   exactly one cycle under this profile
   (`redirect_squash_extend_r` in `riscvpipeline.v`, provably 0 — a genuine
   no-op — under `PROFILE_5STAGE`). This is an honest architectural cost, not
   a workaround: a redirect legitimately costs one more cycle through a
   deeper fetch pipe, the same as real hardware would pay.

The squash condition (`(branch_regde & zero) | unconditional_redirect`)
zeros `reg1` under both profiles as before; under profile 1 it additionally
drives `redirect_squash_extend_r`, which extends `reg1`'s own squash for one
more cycle — `reg1a` itself never squashes.

### A4 — pipeline viewer guard

`sim/tb/gen_trace.v`, `sim/tools/gen_trace.py`, and
`sim/tools/viewer_template.html` hardcode exactly 5 named stages end-to-end
(the CSV schema, `viewer_template.html`'s `STAGE_LABELS` map and
`repeat(5, ...)` CSS grid) — confirmed by direct reading, not assumed.
Tracing `PROFILE_6STAGE_SPLIT_FETCH` through this pipeline would silently
produce a trace that looks complete but has no column for the real `reg1a`
stage. `gen_trace.v` now takes its own `PIPELINE_PROFILE` parameter
(mirroring `PIPELINED`'s, forwarded to the `dut` instantiation and
overridable via `iverilog -Pgen_trace.PIPELINE_PROFILE=1 ...` instead of
hand-editing the file) and includes `reg1a.v` so profile 1 actually
elaborates instead of failing on a generic "unknown module" error — but an
explicit `initial`-block guard `$fatal`s with a clear, specific message
before `trace.csv` is even opened if `PIPELINE_PROFILE != 0`. `$fatal`
(confirmed to work under `-g2005`) gives a nonzero exit code, so `make
viewer` actually stops instead of limping on to build a bogus empty viewer.
Full viewer rework for variable stage counts stays out of scope.

### A5 — generalizing `Forward.v`/`Hazard.v` (infrastructure only)

Landed as its own commit, decoupled from any shipping profile, defaults
reproducing today's exact behavior bit-for-bit — mirroring the
ADR-0015-then-0016 precedent of landing a mechanism separately from a
feature that uses it above its default. Neither module is exercised above
its default by `PROFILE_6STAGE_SPLIT_FETCH`, which is fetch-side only.

`Forward.v` gains a `NUM_FWD_SRC` parameter (default 2). Its two discrete
producer inputs collapse into one flattened `fwd_valid`/`fwd_dest` bus,
ordered farthest-producer-first (index 0 = MEM/WB, index 1 = EX/MEM). A
procedural priority-encode loop overwrites unconditionally in that order, so
the nearest match always wins ties — reproducing the original explicit
"check EX/MEM before MEM/WB" priority exactly at the default. A new
`design/MuxN.v` replaces the two forwarding `Mux4to1` instances in
`riscvpipeline.v` (`Mux4to1` itself is untouched, still used for the
unrelated lui/auipc select mux).

`Hazard.v` gains a `NUM_LOOKAHEAD` parameter (default 1). Its single
load-use check becomes a `generate for` OR-reduction over
`la_memRead`/`la_dest` bus slots, reducing to today's exact single-term
expression at the default. `HazardNoForward.v` is deliberately left
untouched — the shipped profile needs no `Hazard.v` changes at all, so
generalizing its alternate-strategy sibling would be speculative work with
nothing exercising it.

Mechanical follow-on: every one of the ~29 `sim/tb/*.v` files that already
`` `include``d `Mux4to1.v` (the full transitive dependency set each
testbench hand-maintains — confirmed no file relies on a wildcard/glob
include) needed `` `include "MuxN.v"`` added alongside it.

### A6 — quantifying the result

`sim/tb/bench_template.v` threads `PIPELINE_PROFILE` through (a new
`__PIPELINE_PROFILE__` substitution, plus `` `include "reg1a.v"``, the same
requirement A4 found for `gen_trace.v`). `sim/tools/bench_runner.py` gains a
`--pipeline-profile` flag and a `--compare-profiles` flag (mutually
exclusive with `--compare-strategies` — two independent axes, not a full
2x2 cross-product, matching this step's actual scope) mirroring
`--compare-strategies`' shape exactly. This makes "compare pipeline depths"
a real, reportable deliverable rather than just an internal-consistency
check — see Validation strategy for the numbers.

## Alternatives considered

- **A free-form integer stage-count parameter** instead of a closed,
  named enum. Rejected for the same reason `docs/adr/0015` rejected it for
  `XLEN`/`NUM_REGS`: this core does not actually support arbitrary depths,
  and pretending otherwise would be dishonest about what's really verified.
- **Splitting EX/MEM instead of, or in addition to, IF/ID** for the first
  alternate profile. Rejected: EX/MEM-splitting is where `Forward.v`/
  `Hazard.v`/the divider and MEM-stage interlocks all anchor, making it the
  genuinely hard, higher-risk half of this problem — exactly what
  `docs/adr/0016` deferred. A fetch-side split is honestly the cheap,
  structurally isolated first step; taking the hard step first would have
  meant a much larger, harder-to-verify single commit.
- **Retiming `InstructionMemory.v` to a synchronous BRAM in the same pass**
  as the fetch split (mirroring `docs/adr/0013`'s MEM-stage retiming).
  Rejected: `reg1a` already gives profile 1 its own real, honestly-earned
  extra pipeline stage without needing a synchronous-read memory to justify
  it; bundling an unrelated memory-timing change would have doubled this
  phase's risk surface for no requirement driving it.
- **Squashing `reg1a` itself** on a redirect (the first fix attempt for bug
  2). Rejected once random testing showed it duplicates the target fetch
  (bug 3) — the actual fix (extending `reg1`'s squash window instead) is
  simpler and correctly attributes the extra cycle to redirect *recovery*,
  not to fetch-stage squashing that doesn't actually need to exist.
- **Generalizing `HazardNoForward.v` alongside `Hazard.v`/`Forward.v` in
  A5.** Rejected: no profile shipped in this phase exercises it above its
  default, so generalizing it now would be speculative infrastructure with
  zero verification coverage — the same "don't add for hypothetical future
  requirements" reasoning applied to `Forward.v`/`Hazard.v`'s own generalized
  interfaces, just applied one module further.
- **A full 2x2 `--compare-strategies` × `--compare-profiles` sweep** in
  `bench_runner.py`. Rejected as scope creep beyond "mirror
  `--compare-strategies`' shape" — two independent axes cover the actual
  ask; a cross-product can be added later if a real question needs it.

## Validation strategy

Every step ended with the full suite passing again before moving to the
next:

- **Full directed suite**: 26/26 tests (one more than `docs/adr/0016`'s
  25 — `tb_reg1a_unit.v`, added in A2, picked up by `sim/run_tests.sh`'s
  plain glob the same as every other standalone unit test) at
  `PROFILE_5STAGE`, unchanged bit-for-bit throughout A1–A6. At
  `PROFILE_6STAGE_SPLIT_FETCH` (A3 onward): every directed program's own
  assertions confirmed passing via an ad hoc profile-1 harness (sed-patching
  a temp copy of a `tb_*.v` file's `PIPELINED` instantiation to add
  `.PIPELINE_PROFILE(1)` and `` `include "reg1a.v"``) — one pre-existing,
  profile-*independent* blind spot in the ISS-comparison proxy
  (`aluctl_illegal.s`, a hand-crafted illegal-encoding test that fails the
  same way at profile 0 too, not a regression).
- **Constrained-random cross-checking** (`sim/tools/run_random_tests.py`,
  confirmed pipeline-depth-agnostic — it only ever compares final
  architectural state, so it needed zero changes for this phase): 200/200
  and 150/150 at profile 1 across two disjoint seed ranges (A3); a further
  150/150 at profile 1 after the A5 generalization, confirming the
  generalized `Forward.v`/`Hazard.v` still compose correctly with the
  fetch-split wiring; 30/30 at `HAZARD_STRATEGY=1` after A5, confirming the
  untouched `HazardNoForward.v` path still elaborates and runs correctly
  alongside the new `MuxN`/bus-based `Forward.v`/`Hazard.v` interfaces.
  `PROFILE_5STAGE` reconfirmed bit-exact (200/200, 150/150) at every step.
- **Cycle-level bit-exactness** (a random cross-check gap: it only compares
  *final* architectural state, not timing): `sim/tools/bench_runner.py`'s
  cycle counts/IPC for all three benchmark kernels were confirmed
  bit-identical before and after the A5 refactor (`bench_fib` 0.716,
  `bench_bubble_sort` 0.668, `bench_sum_array` 0.639) and a
  `gen_trace.v`/`build_viewer.py` trace was confirmed byte-identical
  (50 cycles, 38953-byte HTML) before and after.
- **Zero-warning compile**: `iverilog -Wall -g2005 -I design -tnull
  design/*.v` clean throughout A1–A6 (confirms both `generate` branches at
  every parameter this phase touched elaborate without warnings).
- **The A4 guard itself**, directly exercised: `PIPELINE_PROFILE=0` compiles
  and runs identically to before; `-Pgen_trace.PIPELINE_PROFILE=1` hits the
  `$fatal` cleanly with a nonzero exit and no `trace.csv` written at all
  (confirmed by direct invocation, not assumed from reading the guard code).
- **`bench_runner.py --compare-profiles`** (A6): `PROFILE_6STAGE_SPLIT_FETCH`
  costs 9.3–14.0% more cycles across the three kernels — `bench_fib`
  215→245 cycles (+14.0%), `bench_bubble_sort` 313→342 (+9.3%),
  `bench_sum_array` 263→294 (+11.8%). Every kernel's expected `x10` result
  (the same hand-computed correctness check `--compare-strategies` already
  used) still matched at profile 1, an independent correctness signal
  alongside the ISS cross-check.

## Future improvements

- **Splitting EX/MEM** (branch-resolve-early, cache-miss stalls) remains
  the genuinely hard, unattempted half of "compare pipeline depths" — a
  real redesign of where `Forward.v`/`Hazard.v`/the divider and MEM-stage
  interlocks anchor, deliberately out of scope here exactly as
  `docs/adr/0016` already deferred it.
- **Retiming `InstructionMemory.v`** to a synchronous-read BRAM (mirroring
  `docs/adr/0013`'s `DataMemoryBRAM.v`) remains open — `reg1a`'s registered
  output feeds a still-combinational instruction memory read today.
- **Full pipeline-viewer rework** for a variable stage count (a real
  6-column trace/viewer for `PROFILE_6STAGE_SPLIT_FETCH`, not just the A4
  guard refusing to produce a wrong one) remains open.
- **A third pipeline profile** (e.g. a genuinely deeper fetch split, or a
  first EX/MEM-splitting attempt once justified) would be a natural next
  comparison point — the `generate`/`if` + closed-enum pattern established
  here extends directly, the way `docs/adr/0016`'s pattern extended into
  this phase.
- **Generalizing `HazardNoForward.v`** with `Forward.v`/`Hazard.v`'s own
  `NUM_FWD_SRC`/`NUM_LOOKAHEAD`-style parameters remains open, deliberately
  not done here since nothing shipped exercises it above its default (see
  Alternatives considered).
- `NUM_FWD_SRC`/`NUM_LOOKAHEAD` themselves remain unexercised above their
  defaults by any profile shipped in this phase — real future work if a
  pipeline shape ever needs more than two forwarding sources or more than
  one lookahead slot (e.g. a genuinely deeper split with an extra ID-stage
  boundary).
