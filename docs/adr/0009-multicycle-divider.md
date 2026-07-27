# ADR 0009: Real multi-cycle iterative divider + pipeline interlock

## Problem

`docs/adr/0006` deliberately implemented `div`/`divu`/`rem`/`remu` as
single-cycle (Verilog's native `/`/`%`), explicitly flagged as a
simplification to revisit: real hardware can't divide in one cycle the way
it can add or even multiply. `docs/ROADMAP.md` named this the natural next
step -- "the project's first real excuse to design a stall/multi-cycle-
execute mechanism generically instead of ad hoc."

## Design

### The divider itself (`Divider.v`)

32-cycle shift-subtract restoring division on unsigned magnitudes, with
sign correction wrapped around it per RV32I's `div`/`rem` rules (quotient
sign = XOR of operand signs, remainder sign = dividend's sign) and the
spec-mandated shortcuts for divide-by-zero and signed overflow
(`INT_MIN / -1`), both resolved immediately (1 cycle) without iterating.
Multiplication stays single-cycle in `ALU.v`, unchanged from `docs/adr/
0006` -- a 32x32 multiplier is cheap enough in real FPGA/ASIC flows that
there's no equivalent motivation to move it off the critical single-cycle
path the way there is for division.

### The pipeline interlock

Three pipeline registers need *different* behavior while a division is in
flight, not the same "stall" applied uniformly:

- **PC / `reg1` (IF/ID)**: freeze, via a new `pc_stall = stall | div_stall`
  wire (`stall` is `Hazard.v`'s existing 1-cycle load-use signal; `div_stall`
  is the new one, held for however long the division takes). Mechanically
  identical to what `Hazard.v` already does for load-use -- both PC.v and
  reg1.v already had a `stall` input built for exactly this "freeze, don't
  advance" behavior.
- **`reg2` (ID/EX)**: needs a *new* behavior, not stall or the existing
  flush. The div/rem instruction itself is sitting in `reg2`'s output,
  feeding the divider -- `flush` (bubble: zero the control fields) would
  rip its operands out from under the divider mid-computation. Added a
  `hold` input, checked with the highest priority in `reg2`'s if-else
  chain, implemented as an *empty* branch: assigning nothing to a `reg` in
  one branch of a clocked if-else means it keeps its value (a synthesizable
  enable-gated flip-flop), so `hold` needed no new field-assignment logic
  at all.
- **`reg3` (EX/MEM)**: needs a bubble inserted on every intermediate cycle
  (`div_stall` true), then the real result latched exactly once, on the
  cycle it becomes valid. Without this, `reg3` would latch the *same*
  div/rem instruction's control signals (`regWrite=1` for any R-type op,
  set by `Control.v` regardless of which R-type op it is) on every one of
  the ~32 intermediate cycles -- not incorrect in final effect (last write
  wins, and nothing else can observe the intermediate garbage since
  everything upstream is frozen) but architecturally sloppy: 32 spurious
  register-file writes per division, and a pipeline-viewer trace that would
  show 32 fake "instruction completions" instead of one real one plus a
  visible stall. Implemented as a mux (`reg3_bubble = div_stall`) ahead of
  `reg3`'s control-signal inputs only -- the data signals (`ALUOut`/
  `pc_plus4`/`funct3`) don't need bubbling, since they're harmless whenever
  their gating control bit is 0.

`ALUOut` feeding `reg3` is replaced by `ex_result = isDivRem ? div_result :
ALUOut` -- the same "override what flows into reg3" pattern used for
`jal`'s `pc_plus4` (`docs/adr/0001`), except div/rem needs no *separate*
EX/MEM-forwarding correction the way `jal` did: `ex_result` is already the
correct final value by the time `reg3` latches it, so `Forward.v`'s
existing `exmem_fwd_val` path (which reads `ALUOut_regem`, i.e. `reg3`'s
output) sees the right thing automatically. Verified this directly rather
than assuming it (see Validation strategy).

## A real bug found during verification: re-triggering on the done cycle

Initial integration passed the standalone `Divider.v` unit test (`sim/tb/
tb_divider_unit.v`, 10/10) but failed 9 of 17 `muldiv.s` checks in the full
pipeline -- specifically, every division *after* the first one in the
program came back wrong or zero.

Root cause: `Divider.v`'s re-trigger guard was `start && !busy`. `start` is
tied to `isDivRem` -- a *level*, true for the entire time a div/rem
instruction occupies `reg2`'s output, not a one-shot pulse (it can't be a
pulse: the caller doesn't know in advance how many cycles the division will
take). On the exact cycle `done` pulses, `busy` has already dropped back to
0 (they clear on the same edge) -- but the *same* div/rem instruction is
still sitting in `reg2` (it only advances the cycle after `done`, since
`reg3` needs it that one more cycle to latch the result). `start` is
therefore still asserted, `busy` reads 0, and the guard sees exactly what
it would see for a genuine new request: `start && !busy` fires, silently
starting a *second* division on the same stale operands, one cycle before
the pipeline had a chance to replace them with the next instruction's.

Fixed by adding `&& !done` to the guard. `done` still holds its just-set
value (from the previous edge) at the moment this check evaluates, so it
correctly blocks re-triggering on the exact done cycle without needing any
change to how `start` itself is driven from `riscvpipeline.v`.

This is exactly the shape of bug multi-cycle interlocks are notorious for
(an edge case at the boundary between "still busy" and "idle again," missed
because `busy` alone doesn't capture it) -- worth calling out explicitly
since it's a specific, learnable failure mode for the next multi-cycle unit
this project adds, not a one-off typo.

## Alternatives considered

- **Pulse `start` explicitly** (a one-cycle-wide request signal, edge-
  detected from `isDivRem`) instead of tying it to a level and fixing the
  guard. Rejected: requires an extra register in `riscvpipeline.v` to track
  "was this div/rem already seen" and reconstructs, awkwardly, exactly the
  same information `busy`/`done` already carry inside `Divider.v` -- fixing
  the guard inside the divider (which is the module that actually needs to
  distinguish "new request" from "same request, already handled") is more
  local and doesn't push state-tracking onto every caller.
- **Bubble `reg3`'s `ALUOut` too, not just the control signals.** Rejected:
  unnecessary once the control signals are correctly gated -- a bubbled
  `regWrite=0` already makes the data value irrelevant, so bubbling it too
  would be redundant defensive coding with no observable effect, at the
  cost of another mux.

## Validation strategy

- `sim/tb/tb_divider_unit.v`: standalone unit test, 10 cases (unsigned/
  signed division and remainder, both operand-sign combinations, divide by
  zero both signed/unsigned, signed overflow, edge values). Caught and fixed
  an unrelated testbench race (blocking assignment immediately after
  `@(posedge clk)` racing the DUT's own posedge-triggered read) before this
  test could even validate the DUT -- switched to nonblocking assignment
  for driving stimulus, the standard fix.
- `sim/programs/muldiv.s` / `tb_muldiv.v`: full pipeline integration,
  including back-to-back `div`+`rem` sharing the same operands (instr N and
  N+1) -- this is exactly the adjacency that exposed the re-trigger bug.
  Needed its wait window extended from 900 to 5000 time units: 6 real
  (non-shortcut) divisions at ~33 cycles each is a much longer program now
  than when division was single-cycle.
- `sim/programs/div_forward.s` (new): a division immediately followed by an
  instruction that depends on its result, specifically to verify the "no
  special forwarding correction needed" claim above by test rather than
  leaving it as an assumption.
- Full suite: 15 tests (14 pipeline + 1 standalone unit test), 84 checks,
  all passing, zero regressions in the pre-existing 13 tests.

## Future improvements

- The restoring-division algorithm is a reasonable simulation-speed/
  clarity tradeoff but not the fastest hardware approach (SRT division,
  Newton-Raphson-style approximation, or a radix-4 divider would all
  complete in fewer cycles at the cost of more complex control logic) --
  worth revisiting once real Fmax/area numbers exist (`docs/ROADMAP.md`
  Phase 7/10).
- The bubble/hold/stall three-way split introduced here for div/rem is the
  first instance of a "multi-cycle EX" pattern in this codebase. Any future
  multi-cycle unit (a real iterative multiplier if `mul` is ever revisited,
  a cache-miss stall once caches exist) should be able to reuse this same
  `pc_stall`/`reg2.hold`/`reg3_bubble` shape rather than re-deriving it.
