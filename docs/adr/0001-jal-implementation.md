# ADR 0001: Implement `jal` (target, link value, forwarding)

## Problem

`docs/ARCHITECTURE.md` §11 identified that `jal` was decoded by `Control.v`
(setting `ALUSrc=1, regWrite=1`) but never functionally wired: nothing routed
its target to the fetch-stage PC mux, and nothing computed the `rd = PC+4`
link value. Running a `jal` would silently fall through to sequential
execution while writing `rs1 OP imm` (whatever the ALU happened to compute
from `jal`'s scattered immediate bits misread as register fields) into `rd`.

## Background

The rest of the control-flow-redirect machinery already existed for
branches: EX-stage resolution (`branch_regde & zero`), a target adder
(`Adder_2`, reusing `pc_o_regde + (imm << 1)`), and squash logic in
`reg1`/`reg2` keyed off that resolution signal. `jal`'s target computation
needs the identical adder (same `pc_o_regde + imm` pattern, and `ImmGen.v`
already extracts a correctly-encoded J-type immediate in this design's
established "pre-shifted-right-by-1, `ShiftLeftOne` restores it" convention
-- verified by hand against the real RV32I J-immediate bit scatter). The gap
was specifically: (a) no `jump` control signal to trigger the redirect and
squash unconditionally, (b) no PC+4 link value computed or threaded to
writeback, (c) no accounting for the link value in EX/MEM forwarding.

## Alternatives considered

- **Route jal through the existing branch datapath** (treat it as an
  always-taken branch by forcing `zero=1`). Rejected: `zero` is the ALU's
  comparator output, already meaningful for real branches in the same cycle
  a `jal` could be in EX; overloading it would make the ALU's behavior
  opcode-dependent in a way that's harder to read and would still need a
  separate signal for "this needs its own encoding" edge cases.
- **Reuse `Adder_1`'s existing PC+4 computation** (fetch-stage) instead of a
  new adder, by carrying it through `reg1`/`reg2`. Rejected: that PC+4 is
  the *next* instruction's address at fetch time, not `jal`'s own PC+4 by
  the time `jal` reaches EX three stages later; carrying it through would
  require widening `reg1`/`reg2` (already flagged in `docs/ROADMAP.md` CQ-3
  as needing a duplication cleanup) rather than removing complexity.

## Chosen solution

- `Control.v` gets a `jump` output, set for opcode `1101111`.
- A dedicated `Adder` instance (`m_Adder_3`, reusing the same generic
  `Adder` module `Adder_1`/`Adder_2` already use) computes `pc_o_regde + 4`
  in EX and threads it through `reg2`/`reg3`/`reg4` as `pc_plus4_*` fields,
  alongside a `jump_*` control bit through the same three registers.
- The fetch-stage redirect condition becomes `branch_taken = (branch_regde &
  zero) | jump_regde`, driving both the PC-select mux and (via `reg1`'s new
  `jump` input / `reg2`'s existing `branch_taken` input) the same squash
  path branches already use -- no new squash logic, just an additional
  unconditional trigger.
- Writeback gets a second-stage mux: the existing ALU/memory writeback mux
  result is overridden by `pc_plus4_regwb` whenever `jump_regwb` is set.
- EX/MEM forwarding (`Mux4to1 .s2`) is corrected to hand out
  `jump_regem ? pc_plus4_regem : ALUOut_regem` instead of raw `ALUOut_regem`
  -- without this, an instruction immediately after a `jal` that reads the
  link register would forward `jal`'s meaningless raw ALU result instead of
  PC+4. MEM/WB forwarding needed no change: `writeData_regwb` is already
  computed downstream of the WB-stage override mux.

## Expected impact

`jal` becomes functionally correct: target reached, two-instruction squash
matches the existing branch penalty, link value correct, and correct under
both EX/MEM and MEM/WB forwarding to an immediately-dependent consumer.

## Validation strategy

`sim/programs/jal_test.s` / `sim/tb/tb_jal.v`: verifies link value, that the
two poison instructions after `jal` never execute (squash), and that an
instruction immediately after the target that depends on the link register
gets the correct EX/MEM-forwarded value (this specifically regression-tests
the forwarding correction -- it was the one part of this change that white-box
reasoning alone would not have obviously caught without simulating it).

## Future improvements

`jalr` and `lui`/`auipc` remain unimplemented (`docs/ROADMAP.md` Phase 5.1).
`jalr` in particular will need its own target-computation path (`rs1 + imm`,
not `PC + imm`), so it cannot simply reuse `jal`'s adder wiring as-is.
