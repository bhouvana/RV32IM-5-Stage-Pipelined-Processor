# ADR 0004: Fix missing `$signed()` casts on signed ALU operations

## Problem

While re-deriving `bltu`/`bgeu`'s intended semantics (this ADR's sibling
work, ISA completeness) it became clear `ALU.v` had the same class of bug
already fixed once for `sra` (fixed inline during the Phase 1 verification
pass, documented in `docs/ARCHITECTURE.md`'s errata rather than its own ADR
at the time) present in five more places: `slt`, `blt`, `bge`, and the
custom `ble`/`bgt` all used plain `<`/`>`/`<=`/`>=` on `A`/`B`, which are
declared as plain (unsigned) `[31:0]` ports.

## Background

Verilog comparison operators (`<`, `<=`, `>`, `>=`) perform an **unsigned**
comparison unless *both* operands have signed type. `A`/`B` in `ALU.v` are
declared `input [31:0] A,B` -- no `signed` keyword -- so every comparison
using them directly is unsigned regardless of what the operation is
supposed to mean. `sltu`/`bltu`/`bgeu` are unaffected (they're *supposed*
to be unsigned, and already used explicit `$unsigned()` -- so whoever wrote
this file understood the signed/unsigned distinction exists, just didn't
apply it consistently to the signed side). Concretely: `slt` with `A=-1,
B=1` should return 1 (`-1 < 1` is true signed) but was returning 0 (as
unsigned, `0xFFFFFFFF < 1` is false).

## Alternatives considered

- **Declare `A`/`B` as `signed` at the port level.** Rejected: would flip
  the *default* behavior of every use of `A`/`B` in the file, including the
  bitwise/shift/unsigned-comparison operations that must stay
  interpretation-agnostic or explicitly unsigned -- riskier and more
  sweeping than casting only the specific operations that need it.
- **Fix case-by-case as each was discovered** (i.e. leave `slt`/`blt`/`bge`/
  `ble`/`bgt` for a future pass). Rejected: once the pattern was recognized
  from the `sra` fix, auditing the remaining cases in the same file cost
  minutes and closed the whole bug class in one pass rather than leaving
  four more instances to be independently rediscovered later.

## Chosen solution

Add `$signed(...)` at each signed comparison site: `slt`, `blt`, `bge`,
`ble`, `bgt` (custom), matching the style already established for `sra`
and for `sltu`'s existing `$unsigned()` casts. See `design/ALU.v`.

## Expected impact

`slt`/`blt`/`bge`/`ble`/`bgt` now correctly compare as signed for any
operand pair, including negative values. No effect on `sltu`/`bltu`/`bgeu`
(already correctly unsigned) or non-comparison operations.

## Validation strategy

`sim/programs/bltu_bgeu.s` uses `A=0xFFFFFFFF, B=1` -- negative as signed,
large as unsigned -- for both the bltu/bgeu instructions it was originally
written for *and* (extended in the same change) blt/bge/ble/bgt on the
identical bit pattern, checking the opposite outcome from the unsigned
versions. `sim/programs/arith.s`'s existing slt/slti checks only use small
positive values that pass under either interpretation, so they don't
exercise this fix -- the bltu_bgeu.s extension is what actually validates
it.

## Future improvements

This bug class (implicit-unsigned comparisons/shifts on plain-width ports)
is exactly what a lint pass or an SVA assertion comparing `$signed`/
`$unsigned` results would catch mechanically. Worth prioritizing when
`docs/ROADMAP.md` CQ-5 (lint) or V-3 (assertions) is picked up.
