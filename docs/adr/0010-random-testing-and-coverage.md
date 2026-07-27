# ADR 0010: Constrained-random cross-checking (V-4) and functional coverage (V-5)

## Problem

`docs/ROADMAP.md` V-4/V-5 were the two remaining Phase 3 items: hand-computed
expected values don't scale past directed tests, and there was no way to
answer "does the suite actually exercise every instruction/hazard class" --
`docs/adr/0004` explicitly flagged this as a gap when it noted the
signed-comparison fix wasn't validated by any *existing* test until a new
one was added specifically for it.

## V-4: constrained-random testing

### Reference model

Cross-checking random programs needs an independent oracle. Built
`sim/tools/iss.py`, a from-scratch functional interpreter of this core's
exact ISA (RV32I + RV32M + the custom `ble`/`bgt`/`ctz` ops) -- deliberately
*not* sharing decode logic with `sim/tools/asm.py` or `design/*.v` beyond
opcode constants, since an ISS that reuses the thing it's checking can't
catch disagreements with it.

**Two ISS bugs found and fixed before it could be trusted**, both in
immediate sign-extension: `s32()` (correct for a genuine full 32-bit value)
was applied directly to narrower fields (12-bit I/S-type, 13-bit B-type,
21-bit J-type immediates) that are never large enough to set bit 31, so the
sign-extension branch never fired and every negative immediate silently
came out as a small positive number instead. Added a proper `sext(value,
bits)` helper (sign-extend from the field's *own* top bit) and fixed all
four call sites. Caught by cross-checking the ISS against `arith.s`'s
already-known-correct expected values (`addi x13,x0,-1` should give
`0xFFFFFFFF`; the buggy ISS gave `0xFFF`) *before* trusting it for anything
random -- validated against all 13 pre-existing directed tests (48 checks)
before generating a single random program.

### Generator

`sim/tools/random_gen.py`: constrained to guarantee every generated program
is safe to compare without exception handling (this core has none yet) or a
loop detector doing real work:
- A reserved base-pointer register (`x31`), set once and never overwritten,
  used as `rs1` for every load/store with a small width-aligned offset --
  every generated address stays inside `DataMemory`'s 128 bytes by
  construction.
- Branches/jumps only ever target a strictly *later* instruction --
  guarantees termination trivially (finite forward-only control flow),
  without leaning on a step-count safety net to paper over a real infinite
  loop.
- Division-by-zero and `INT_MIN/-1` overflow are not specially avoided:
  both the RTL and the ISS implement the same spec-mandated results, so
  hitting those cases is free extra coverage, not a hazard to route around.

### Driver and a real bug found

`sim/tools/run_random_tests.py`: per seed, generates a program, computes
expected final register *and memory* state via the ISS, runs the same
program through the real Icarus simulation (`sim/tb/dump_regs_template.v`
dumps all 32 registers + 128 memory bytes at the end), and compares.

**Found a genuine, previously-undocumented RTL bug** on the second batch (50
programs, 20 instructions each): seed 111's `srl x5,x25,x25` gave 0 in RTL,
`0x1fff` (correct) in the ISS. Root cause: `ALU.v`'s `SLL`/`SRL`/`SRA`
used the full 32-bit `B` operand as the shift amount instead of `B[4:0]`.
Per spec, register-register shifts only use the low 5 bits of `rs2` as the
shift count -- Verilog silently discards every bit when shifting by >=32,
so `A >> B` with `B >= 32` (utterly ordinary; `rs2` is just a register,
nothing stops it holding a large value) gave 0 instead of a real shift.
Every hand-written directed test happened to use a shift-amount register
already holding a small value (0-31), so this was invisible to 16 directed
tests and only surfaced once genuinely random operand values hit it. This
is close to the textbook case for why constrained-random testing exists.
Fixed by masking `B[4:0]` in all three shift ops (I-type `slli`/`srli`/
`srai` were already unaffected -- `ImmGen.v` encodes their shamt as an
already-5-bit immediate). Pinned with a new directed regression test
(`sim/programs/shift_mask.s`) in addition to the random infrastructure that
found it, since a bug this easy to reintroduce deserves an explicit,
readable test, not just probabilistic re-discovery.

Verified the fix: the originally-failing seed now passes, plus two fresh
batches (60 + 50 = 110 programs total) all match the ISS with zero
mismatches.

## V-5: functional coverage

No formal statement/branch coverage tool was available in this environment
(Icarus's coverage support is limited; `covered` wasn't installed and
adding a new tool to the chain was judged out of scope for this pass).
Built lightweight functional coverage instead: does the suite exercise
every ALUCtl operation, every branch type in both directions, and every
hazard/stall class -- a different, complementary question from "does it
touch every RTL line," but a real and previously-unanswered one.

Implementation: `` `ifdef COVERAGE``-guarded counters in
`riscvpipeline.v` (compiled out, zero impact, otherwise), a `dump_coverage`
task (not a `final` block -- unavailable under this project's Verilog-2005
language mode, see `docs/ROADMAP.md` CQ-5) called from every directed
testbench just before `$finish`, and `sim/tools/coverage_report.py`
aggregating each run's dump across the whole suite.

**First run found a real gap**: `bne` was never exercised by any directed
test -- every other branch type had one, `bne` didn't, by simple omission.
Closed by adding `bne` taken/not-taken cases to the existing `branch_taken.s`/
`branch_not_taken.s` tests. Re-running coverage confirmed the gap closed.

**Known remaining gap, left open deliberately**: `blt`/`bge`/`ble`/`bgt`/
`bltu`/`bgeu` each currently only have a directed test for *one* direction
(taken or not-taken, not both) -- lower priority than the `bne` gap since
each comparison's correctness is independently verified elsewhere
(`arith.s` and `docs/adr/0004`'s signed-comparison fix, `bltu_bgeu.s`'s
signed-vs-unsigned distinction), and closing all twelve missing cases was
judged lower value than moving on to the CSR/exceptions and FPGA-readiness
work still ahead. Left as an explicit backlog item rather than silently
dropped.

## Validation strategy

Full directed suite (16 tests, 87 checks after the `bne` additions) plus
110 random programs across two batches, all matching the independent ISS
reference with zero mismatches after the shift-mask fix. Coverage report
re-run after the `bne` fix confirms the gap closed.

## Future improvements

- Extend `run_random_tests.py` to feed its own coverage instrumentation
  (random programs currently aren't included in the `coverage_report.py`
  aggregate) -- would likely close several of the remaining branch-
  direction gaps for free, since 110 random programs already incidentally
  exercise many outcomes the directed suite doesn't target specifically.
- A real formal coverage tool (Verible's coverage support, or a
  `covered`/Verilator install) would answer the complementary "every RTL
  line" question this functional-coverage pass doesn't.
