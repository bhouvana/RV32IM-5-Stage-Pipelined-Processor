# ADR 0007: Embedded invariant assertions (V-3)

## Problem

`docs/ROADMAP.md` V-3 identified four invariants worth checking explicitly
rather than trusting by inspection, one of them named directly:
`docs/adr/0003`'s store-forwarding bug ("a forwarded value is computed
correctly but wired to the wrong consumer") is exactly the shape of defect
a structural assertion catches on the first cycle it's violated, instead of
needing a directed test to happen to exercise that specific data path.

## Alternatives considered

- **SystemVerilog `assert property` / `bind`-based external assertion
  modules.** This is the more "industrial" pattern (assertions live outside
  the DUT files entirely, RTL stays assertion-free for synthesis without
  any macro-guarding). Rejected for now: requires confirming Icarus's
  `-g2012` SystemVerilog subset support for `bind` and immediate assertions
  in this environment, on top of everything else in this session -- a
  reasonable thing to revisit (`docs/ROADMAP.md` notes it), not a decision
  to make under time pressure that touches the toolchain's language mode
  for every file.
- **A separate scoreboard/checker testbench module using hierarchical
  references** (`dut.m_Forward.forwardA`, etc.), similar in spirit to
  `sim/tb/check_tasks.vh`'s existing register checks. Rejected: works for
  end-of-run assertions but is awkward for "flag the exact cycle an
  invariant breaks" -- which is the main value of these four checks (the
  store-data one especially needs to fire the instant a mismatch appears,
  not be reconstructed after the fact from a trace).
- **Plain Verilog-2001 `` `ifdef ASSERT_ON``-guarded procedural checks
  embedded directly in the RTL files**, compiled out entirely unless the
  macro is defined. Chosen: no SystemVerilog toolchain risk, no new files
  to keep in sync with what they're checking (the assertion lives next to
  the logic it's checking), and completely inert for synthesis (the guard
  means an unmodified synthesis flow never sees this code at all).

## Chosen solution

Four assertions, each `` `ifdef ASSERT_ON``-guarded:

1. **`Forward.v`**: `forwardA`/`forwardB` never equal `2'b11` (the
  `Mux4to1` consumers only implement `s0`/`s1`/`s2` -- `ARCHITECTURE.md` §7
  flagged this as a "dead code, not a live bug" case; the assertion makes
  that a checked invariant instead of an assumption).
2. **`Hazard.v`**: `stall === flush` always (currently true by construction
  -- `docs/ARCHITECTURE.md` §6 already noted they're assigned identically;
  this catches a future edit that makes them diverge without updating every
  caller that assumes they're interchangeable).
3. **`Register.v`**: `regs[0] === 0`, checked every cycle post-reset. `x0`
  is hardwired to 0 in two independent places (the write path and the
  write-first bypass reads) -- this checks the invariant the whole ISA
  depends on rather than trusting those two sites never drift apart.
4. **`riscvpipeline.v`**: `readData2_regem` (reg3's registered output) must
  equal `readData2_final` as it was one cycle earlier, whenever
  `memWrite_regem` is set. Implemented with a one-cycle shadow register
  (Verilog-2001 has no `$past`) rather than SVA's `$past`/`|->` operators.

## Expected impact

No functional or synthesis impact (compiled out by default). With
`-DASSERT_ON` (now the default in `sim/run_tests.sh`), any future change
that reintroduces the ADR 0003 bug shape, breaks the stall/flush identity,
lets a non-`s0`/`s1`/`s2` forward code appear, or lets `x0` become writable
will fail immediately with a specific message and cycle number, rather than
surfacing as a wrong register value in some unrelated directed test's
output.

## Validation strategy

Ran the full suite with `-DASSERT_ON`: 13/13 tests, zero false positives on
current (correct) RTL. Then verified the assertions actually catch what
they're meant to, not just that they compile: temporarily rewired reg3's
store-data input back to the raw `readData2_regde` (reproducing
`docs/adr/0003`'s exact bug) and reran `tb_store_load` --
`ASSERTION FAILED @t=65: reg3 store-data mismatch: readData2_regem=0,
expected...=1234`, firing on the very first affected cycle. Reverted
immediately after confirming.

## Future improvements

- Coverage collection (V-5) and constrained-random testing (V-4) remain
  open; assertions are complementary to both (constrained-random testing
  specifically benefits from having invariants to check against instead of
  only hand-computed expected values, which don't scale to random inputs).
- Revisit SystemVerilog `bind`-based assertions if/when the toolchain
  already needs `-g2012` for another reason (e.g. if a future contributor
  wants proper `assert property`/`cover property` with a real formal tool
  behind it) -- rebuilding these four as `bind`-based modules at that point
  is a small, mechanical follow-up, not a redesign.
