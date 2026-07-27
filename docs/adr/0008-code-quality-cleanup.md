# ADR 0008: Code-quality cleanup (CQ-2, CQ-3, CQ-4)

## Problem

`docs/ARCHITECTURE.md` §12 flagged three open items from the Phase 1 audit
that had accumulated no functional urgency but real risk: no
`` `default_nettype none`` anywhere (typos silently become new 1-bit
wires instead of compile errors), dead fields left over in `reg3` from the
`docs/adr/0001`/`0002` work, and `reg1`/`reg2` carrying the most repetitive
code in the repository (three to four nearly-identical field-assignment
arms per pipeline register).

## CQ-4: dead `reg3` fields

`branch_regem`, `zero_regem`, `imm_sum_regem` (and their `reg3` inputs
`branch_regde`/`zero`/`imm_sum`) were latched every cycle but never read by
anything downstream -- confirmed by grep before removal, not assumed.
Removed both the fields and the now-unused `readData1_regem` wire in
`riscvpipeline.v` (declared, never connected, predates this session).

## CQ-2: `` `default_nettype none``

Added to every file in `design/` (`` `default_nettype none`` at the top,
reset to `` `default_nettype wire`` at the end so the strict setting
doesn't leak into whatever a file is `` `include``d alongside). This is not
a hypothetical safety net -- turning it on immediately broke compilation:
**`stall`, `flush`, and `branch_zero` in `riscvpipeline.v` were genuinely
undeclared**, relying on Verilog's implicit net declaration this entire
time. All three happened to be used consistently as 1-bit wires everywhere,
so this was never a live bug -- but it's exactly the class of thing
`` `default_nettype none`` exists to catch: a typo'd signal name in any of
those positions would have silently created a new, always-0 phantom wire
instead of a compile error. Fixed by adding explicit `wire` declarations
for all three.

## CQ-3: `reg1`/`reg2` deduplication

`reg1.v` turned out not to need this -- only 2 fields, already minimal.
`reg2.v` had ~90 lines of near-identical repetition across 4 arms (reset,
branch-taken squash, load-use flush, normal). Verilog-2001 has no
struct/typedef to reach for (the SystemVerilog packed-struct approach
`docs/ROADMAP.md` originally suggested would mean a language-mode change
for the whole toolchain); used text macros instead --
`` `ZERO_CONTROL_FIELDS``, `` `ZERO_DECODE_CONTEXT``, `` `PASS_DECODE_CONTEXT``
-- each defined once, `` `undef``'d at the end of the file so they don't
leak into other `` `include``d files.

**One behavioral difference, judged an improvement**: the original reset
arm never assigned `readReg1_regde`/`readReg2_regde` (an omission -- they'd
sit at simulation-X until the first real cycle). `` `ZERO_DECODE_CONTEXT``
now zeros them like every other decode-context field. Not observable:
`Forward.v`'s use of these fields is always gated by
`regWrite_regem`/`regWrite_regwb`, which are also 0 during/immediately
after reset, so the AND short-circuits regardless of what
`readReg1_regde`/`readReg2_regde` held. Confirmed via the full suite --
zero regressions -- but flagged explicitly here since "the refactor changed
what a reset-state field holds" is exactly the kind of thing that deserves
a sentence of justification, not silent absorption into a larger diff.

## Validation strategy

Full suite after each of the three changes independently (not just at the
end) -- CQ-4 alone, then CQ-2 alone (this is what surfaced the
`stall`/`flush`/`branch_zero` gap), then CQ-3 alone. 13/13 tests, 67/67
checks, all passing after each step and at the end.

## Future improvements

`ImmGen.v`'s per-case literals and `sim/tools/asm.py`'s independent
Python copy of the encoding tables remain as noted in `docs/adr/0005`/
`0006` -- unrelated to this cleanup, still open.
