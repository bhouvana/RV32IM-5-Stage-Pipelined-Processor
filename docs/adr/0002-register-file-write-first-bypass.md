# ADR 0002: Register-file write-first bypass

## Problem

Discovered by `sim/programs/arith.s` (a directed ISA-coverage test, not a
hazard-focused one -- it just happened to space `addi x2,x0,3` three
instructions before an instruction that reads `x2`) during construction of
the verification harness (`docs/ROADMAP.md` V-1/V-2): `add x3,x1,x2`
computed `x3 = 133` instead of `8`. Instrumented trace (`sim/tb/tb_debug.v`)
showed the consuming instruction's ID-stage read of `x2` captured `128`
(`x2`'s *reset* value, before `addi x2,x0,3` had written anything) --
neither the stale value nor its correction via forwarding ever reached the
ALU.

## Background

`Register.v` reads combinationally (`assign readData2 = regs[readReg2]`)
and writes synchronously (`always @(posedge clk) regs[writeReg] <= ...`).
When a producer instruction's WB-stage cycle exactly coincides with a
different (later) instruction's ID-stage cycle, the combinational read
samples `regs[]` *before* that cycle's synchronous write commits, so it
captures the pre-write value.

This is a distinct hazard from the ones `Forward.v` and `Hazard.v` already
handle. Working through the pipeline timing concretely (producer P at
instruction index p, consumer C at index c, gap = c-p):

- gap=1: P is in EX/MEM exactly when C is in EX -> caught by EX/MEM
  forwarding.
- gap=2: P is in MEM/WB exactly when C is in EX -> caught by MEM/WB
  forwarding.
- **gap=3: P is in WB exactly when C is in ID.** By the time C reaches EX
  (the next cycle), P has already fully retired past both the EX/MEM and
  MEM/WB pipeline registers -- neither one contains P's data anymore. This
  gap has no covering mechanism anywhere in the existing design.
- gap>=4: P's WB write commits a full cycle before C's ID read even begins;
  the plain register file already returns the correct, already-committed
  value with no assistance needed.

So specifically **RAW dependencies exactly 3 instructions apart** (with no
intervening load -- that case is separately, correctly handled by
`Hazard.v`'s stall) were silently broken. This is a common, unremarkable
code distance -- not a contrived edge case -- which is why it surfaced from
an ordinary ISA-coverage test rather than a hazard-stress test.

## Alternatives considered

- **Extend `Forward.v` with a third source** comparing against the WB
  stage's *inputs* (i.e. `regem`'s current values, one stage earlier than
  `regwb`) at the ID stage instead of EX. Rejected: this pushes forwarding
  logic into the ID stage in a way that doesn't fit this design's existing
  "resolve everything at EX" structure, and would need a new mux ahead of
  `reg2`'s input latching rather than reusing `Mux4to1`'s existing EX-stage
  operand muxes -- more invasive for the same result.
- **Split the register file write to the first half of the clock cycle**
  (e.g. write on `negedge`, read still combinational) so the write commits
  before the same cycle's ID-stage read samples it. Rejected: mixing
  negedge-triggered and posedge-triggered synchronous logic in the same
  design is a common source of confusion and CDC-style timing bugs, and is
  unusual/non-idiomatic for a synchronous-reset, single-clock-edge design
  like the rest of this pipeline.
- **Write-first bypass inside the register file itself** (if reading the
  same register a same-cycle write targets, return the new data instead of
  the stored value). This is the standard, textbook approach (equivalent to
  a `(* ram_style = "..." *)` write-first RAM in FPGA terms) and is a
  three-line, purely local change.

## Chosen solution

Write-first bypass in `Register.v`:
```verilog
assign readData1 = (readReg1 == 0) ? 32'b0 :
                    (regWrite && writeReg == readReg1) ? writeData :
                    regs[readReg1];
```
(symmetric for `readData2`). This is architecturally a third forwarding
source -- complementary to, not a replacement for, `Forward.v`'s EX/MEM and
MEM/WB paths, which remain necessary for gap=1 and gap=2.

## Expected impact

Closes the gap=3 hole for all non-memory producers. Does not change
`Hazard.v`'s load-use stall (gap=1 load producer) or `Forward.v`'s coverage
(gap=1/2) -- both still needed, this is additive.

## Validation strategy

`sim/programs/arith.s` (already exercises this via its existing 2-nop
spacing, now documented) plus every other directed test that transitively
depends on any register written 3 instructions earlier. Re-ran the full
directed suite after this fix (see `sim/run_tests.sh` output) to confirm no
regressions in the EX/MEM (gap=1) and MEM/WB (gap=2) forwarding tests --
this fix must not change behavior for gaps already covered by `Forward.v`.

## Future improvements

`Register.v` carried a `// Do not modify this file!` comment inherited from
whatever earlier assignment template this project started from (see
`docs/ARCHITECTURE.md` §10 for a similar stale-comment finding on `rst`
naming). That constraint no longer applies -- this project is not a
graded submission -- but it's worth flagging here explicitly since a future
contributor skimming the file history might otherwise assume the comment
still means something.
