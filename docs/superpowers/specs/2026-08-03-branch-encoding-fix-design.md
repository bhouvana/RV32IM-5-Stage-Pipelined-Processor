# Design: Branch Encoding Fix (Phase N — Generation 3 prerequisite)

## Problem

This core's `blt`/`bge` sit at funct3 `010`/`011`. Real RISC-V spec places `blt`/`bge` at
`100`/`101` (010/011 are reserved). This core's own custom `ble`/`bgt` instructions occupy
`100`/`101` instead — the real spec slots for `blt`/`bge`.

Confirmed and documented in `docs/adr/0029-generation-2-closure.md` as one of two blockers to
riscv-arch-test compliance integration. Now also confirmed (this design's own research pass, see
`handoff.md`/conversation) as a near-certain blocker to Generation 3's "Linux boot" goal: stock
`riscv64-gcc`-compiled code (including a real Linux kernel) emits spec-standard `blt`/`bge`
constantly for ordinary signed comparisons (loop bounds, array indices), and this core would
silently misdecode every one of them as `ble`/`bgt`.

User confirmed (`AskUserQuestion`, presented three options — fix now, rescope the Gen3 boot
target, or attempt Gen3 as literally scoped and accept the risk): **fix the encoding first**, as
its own prerequisite phase, before any Generation 3 MMU/privilege work starts.

`bltu`/`bgeu` (funct3 `110`/`111`) already sit at their real spec positions — not part of this fix.

## Decision: swap, not retire

Two approaches considered:

1. **Swap the two funct3 pairs** (chosen): `blt`/`bge` move to `100`/`101`; `ble`/`bgt` move to
   the now-vacant `010`/`011`. Minimal, symmetric, exactly what `docs/adr/0029` already
   anticipated ("large, invasive... RTL + asm.py/iss.py/disasm.py + every existing directed test
   using ble/bgt").
2. **Retire `ble`/`bgt` as real hardware**, reimplementing them as assembler pseudo-ops (swap
   `rs1`/`rs2`, emit `blt`/`bge`) — matching how real RISC-V toolchains implement these
   comparisons, since the spec has no real `ble`/`bgt` hardware instruction at all. Rejected:
   bigger diff (touches `ALU.v`, needs new pseudo-op expansion in `asm.py`) for no functional gain.
   The reserved-slot deviation is harmless — no real compiler ever emits a `funct3=010/011` branch
   (spec doesn't define one there), so nothing collides with real code. Fixing the swap alone fully
   resolves the actual blocker (real spec `blt`/`bge` misdecoding). YAGNI on the bigger change.

## Scope — one coordinated step

Four files change together, in lockstep (mirrors this project's own precedent for tightly-coupled
encode/decode pairs — F5's TLB+PTW wiring, G6-G7's cache+fence wiring — splitting these across
separate steps would leave an intermediate state where RTL and tooling disagree on encoding):

- **`design/ALUCtrl.v`**: the branch-decode `case` statement (currently ~lines 60-76) swaps which
  `ALUCtl` code each of the 4 funct3 case values (`5'b01010`/`5'b01011`/`5'b01100`/`5'b01101`)
  produces. `5'b01010` (funct3=010) now produces `ALUCTL_BLE` (was `ALUCTL_BLT`); `5'b01011`
  (011) now produces `ALUCTL_BGT` (was `ALUCTL_BGE`); `5'b01100` (100) now produces `ALUCTL_BLT`
  (was `ALUCTL_BLE`); `5'b01101` (101) now produces `ALUCTL_BGE` (was `ALUCTL_BGT`). No change to
  `ALU.v` — the `ALUCTL_*` comparison logic itself is untouched, only which funct3 pattern maps to
  which code moves.
- **`sim/tools/asm.py`**: the `BRANCH` dict (~line 108) swaps values: `"blt": 0b100, "bge": 0b101,
  "ble": 0b010, "bgt": 0b011` (was `blt:010, bge:011, ble:100, bgt:101`).
- **`sim/tools/disasm.py`**: the `names` dict (~line 168) swaps the same 4 entries the same way.
- **`sim/tools/iss.py`**: the `taken` dispatch dict in the branch-opcode handler (~line 1143-1148)
  swaps which comparison each of the 4 keys performs: key `4` (100) becomes `A < B` (blt), key `5`
  (101) becomes `A >= B` (bge), key `2` (010) becomes `A <= B` (ble), key `3` (011) becomes
  `A > B` (bgt).

Nothing else needs touching. `random_gen.py`, `bench_runner.py`, every existing `.s` test program,
and every existing directed testbench reference branch instructions by mnemonic (`blt`, `ble`,
etc.), not raw funct3 bits — the swap is fully transparent to all of them as long as the four
source-of-truth tables above move together.

## Verification

- Full existing directed suite (`sim/run_tests.sh`, currently 83+ tests) must stay 100% green —
  this is a *regression* check, not new coverage: it proves the swap was truly symmetric across
  RTL and all three Python tools, since every mnemonic's assembled/executed/disassembled behavior
  must be bit-identical to before from the outside.
- Zero-warning `iverilog -Wall -g2005 -tnull design/*.v` compile (standing bar every phase uses).
- Full constrained-random cross-check sweep at the usual axis combinations (hazard strategy ×
  pipeline profile × branch predictor × cache mode × MMU × latency), same bar as every prior
  phase — branch resolution is exercised by essentially every random program, so this is the real
  confidence check that nothing subtly regressed.
- **New, targeted**: extend `sim/tb/tb_aluctrl_unit.v` (or a new sibling unit test) with explicit
  funct3→ALUCtl assertions for exactly the 4 changed encodings (100→BLT, 101→BGE, 010→BLE,
  011→BGT) — a bit-level check that doesn't depend on a full pipeline run to catch a
  half-completed swap.
- **New, targeted**: an assemble→disassemble round-trip check for all 4 mnemonics (`asm.py`
  encodes, `disasm.py` decodes, mnemonic must come back unchanged) — catches an `asm.py`/`disasm.py`
  table left out of sync with each other even if both happen to independently disagree with the
  RTL in a way a pure-RTL test wouldn't reveal.

## Documentation

- New `docs/adr/0030-branch-encoding-fix.md` (problem, the swap-vs-retire decision above,
  validation results, pointer back to `docs/adr/0029` and this design doc).
- `docs/ARCHITECTURE.md` §11's branch row: update to reflect real spec positions for `blt`/`bge`,
  and that `ble`/`bgt` now occupy the (harmless, still-custom) reserved slots.
- `docs/ROADMAP_VISION.md`: mark the Generation 3 "likely new MMU design, and this encoding
  question" open-question text as resolved; note in the Generation 3 section that this
  prerequisite is done.
- `handoff.md`: update the Generation 2 closure / ADR 0029 pointer section to note the encoding
  half of the riscv-arch-test blocker is now resolved (the Windows-native reference-model tooling
  half is unchanged and still open), and that Generation 3 itself can now start.

## Out of scope

- riscv-arch-test / Spike/Sail tooling integration itself — still blocked by the separate,
  unrelated Windows-native reference-model problem (`docs/adr/0029`). This phase only removes the
  *encoding* half of that blocker.
- Any Generation 3 MMU/privilege/Linux-boot work itself — this phase is strictly the prerequisite,
  not the start of Generation 3's own scope.
