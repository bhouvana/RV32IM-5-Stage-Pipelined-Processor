# ADR 0003: Forward store data, not just ALU operands

## Problem

`sim/programs/store_load.s` and `sim/programs/load_use_stall.s` both failed
identically: `sw` followed later by `lw` from the same address read back
`0` instead of the stored value. Instrumented trace (`sim/tb/trace_debug.v`)
showed the `sw` instruction correctly computed address `16` in EX, and
`readData2_final` (the forwarding mux's output) correctly held the store
data (`1234`) in the same cycle -- but by the time that instruction reached
MEM, `ALUOut_regem`/`memWrite_regem` were right while the value actually
written to `DataMemory` was `0`.

## Background

`riscvpipeline.v`'s `reg3` (EX/MEM register) instantiation wired its
store-data input directly to `readData2_regde` -- the **raw, unforwarded**
decode-stage register read -- instead of `readData2_final`, the output of
the EX-stage forwarding mux (`Mux4to1 m_Mux_ALU_B`) that `Forward.v` drives.

The forwarding mux exists and is correctly computed; it's just wired to the
wrong destination for this one path. The ALU's own B operand
(`imm_reg_val`, via `Mux2to1 m_Mux_ALU`) correctly receives the forwarded
value when `ALUSrc=0` (R-type instructions) -- but for a store, `ALUSrc=1`,
so the ALU's B input is the store *offset immediate*, not `readData2`. The
forwarded `readData2_final` is only otherwise consumed by that now-discarded
ALU-B mux input, meaning **it was computed and then thrown away** on every
store, while the actual store-data path downstream used the stale value
instead. This is a pre-existing bug (confirmed present before any change in
this working session, not introduced by the `jal` or register-file work),
undetected until directed testing exercised a store whose data register was
written 1-2 instructions earlier.

## Alternatives considered

- **Add a separate forwarding mux dedicated to store data.** Rejected:
  `readData2_final` already *is* exactly the correct value (Forward.v's
  `forwardB` logic makes no distinction between "rs2 as ALU operand" and
  "rs2 as store data" -- both are the same architectural register read,
  needing the same RAW-hazard resolution). A second mux would duplicate
  logic that already exists and already computes the right answer.
- **Move forwarding to the MEM stage instead of EX.** Rejected: far more
  invasive, and unnecessary -- the EX-stage forwarded value is already
  available in time; the bug was purely which wire fed it into `reg3`.

## Chosen solution

Rewire `reg3`'s store-data input from `readData2_regde` to `readData2_final`
in `riscvpipeline.v`. One-line change; no new logic.

## Expected impact

`sw` instructions whose data register was written 1 or 2 instructions
earlier now store the correct, forwarded value. No effect on loads
(`memRead` path is unaffected) or on stores whose data register was written
long enough ago that the register file already held the correct value.

## Validation strategy

`sim/programs/store_load.s` (`sw` immediately followed by `lw`, data
register written 1 instruction earlier -- EX/MEM forwarding case) and
`sim/programs/load_use_stall.s` (same shape, plus a load-use stall) both
went from failing to passing with this one change and no other change.
Re-ran the full directed suite (`sim/run_tests.sh`) to confirm no
regressions elsewhere.

## Future improvements

This bug's shape -- "a forwarded value is computed correctly but wired to
the wrong consumer" -- is exactly the kind of thing an assertion would catch
structurally rather than requiring a directed test to stumble into it (e.g.
an assertion that `readData2_regem === (expected forwarded value)` whenever
`memWrite_regem` is set). Worth prioritizing when `docs/ROADMAP.md` V-3
(assertions) is picked up.
