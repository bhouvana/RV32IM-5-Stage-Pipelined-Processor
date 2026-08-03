# ADR 0030: Branch encoding fix — blt/bge moved to real spec funct3 positions

## Problem

This core's `blt`/`bge` sat at funct3 `010`/`011`. Real RISC-V spec places them at `100`/`101`
(010/011 reserved). This core's own custom `ble`/`bgt` occupied `100`/`101` instead. Documented
as one of two blockers to riscv-arch-test compliance in `docs/adr/0029-generation-2-closure.md`;
also confirmed (this ADR's own research, done as part of scoping Generation 3) as a near-certain
blocker to Generation 3's real Linux-boot goal — stock `riscv64-gcc`-compiled code emits
spec-standard `blt`/`bge` constantly (ordinary signed comparisons), and this core would silently
misdecode every one as `ble`/`bgt`.

`bltu`/`bgeu` (funct3 `110`/`111`) already matched spec and were untouched by this fix.

## Decision

Confirmed with the user (`AskUserQuestion`, presented alongside "rescope the Gen3 boot target"
and "attempt Gen3 as literally scoped anyway"): fix the encoding first, as its own prerequisite
phase (Phase N), before starting any Generation 3 MMU/privilege work.

Swapped the two funct3 pairs rather than retiring `ble`/`bgt` as real hardware (the spec-purist
alternative — reimplementing them as assembler pseudo-ops that swap operands and emit
`blt`/`bge`, matching real RISC-V toolchains, since the spec has no real `ble`/`bgt` hardware
instruction at all). Rejected: bigger diff (would touch `ALU.v`, need new pseudo-op expansion in
`asm.py`) for no functional gain — the reserved-slot deviation is harmless, since no real
compiler emits a `funct3=010/011` branch (spec doesn't define one there), so nothing collides
with real code either way. The smaller swap fully resolves the actual blocker.

## Scope

Four files, two commits (`c03690c` for RTL, `9836daa` for tooling — deliberately sequential, not
squashed, matching this project's discipline of new commits over amends, though the full suite
only passes again once both land):

- `design/ALUCtrl.v` — branch-decode case statement, 4 arms swapped.
- `sim/tools/asm.py` — `BRANCH` encoder dict, 4 entries swapped.
- `sim/tools/disasm.py` — `names` decoder dict, 4 entries swapped.
- `sim/tools/iss.py` — `taken` dispatch dict in the branch handler, 4 entries swapped.

No change to `ALU.v` or any `ALUCTL_*` macro value — only which funct3 pattern maps to which
existing code moved. No change to any `.s` test program, `random_gen.py`, or `bench_runner.py` —
all reference branch mnemonics, never raw funct3 bits.

**A real bug turned up mid-implementation, unrelated to the encoding logic itself**: both commits
were initially staged and committed together with unrelated pre-existing uncommitted Generation 2
(Phase M) work that happened to live in the same files (`ALUCtrl.v`'s SRL/SRA discriminator fix,
and the Python tooling's XLEN-awareness). Caught during post-commit review before moving on;
fixed by resetting both commits and re-isolating each file's Phase N diff from its pre-existing
Phase M diff via `git stash` (stash the Phase M portion, commit the clean Phase N portion alone,
pop the stash back on top) — the two phases' own work stays properly separated in history, Phase M
remains exactly as uncommitted as it was before this phase started. `sim/tools/iss.py` needed a
manual (not auto-mergeable) conflict resolution on stash-pop, since Phase M had independently
renamed the same branch-dispatch dict's helper calls (`s32`/`u32` to `self.sxlen`/`self.uxlen`)
that Phase N's own comparison-order swap also touched — resolved by keeping Phase M's renamed
calls with Phase N's corrected comparison order.

## Validation strategy

New bit-level unit test (`sim/tb/tb_aluctrl_unit.v`, 6 new checks: all 4 changed encodings plus
`bltu`/`bgeu` confirmed unchanged) and a new assemble-disassemble round-trip test
(`sim/tools/test_branch_encoding_roundtrip.py`, 8 checks, one per branch mnemonic) — both confirm
the fix at the bit level independent of a full pipeline run.

Full regression: 83/83 directed tests (matching the pre-existing baseline exactly, zero
regressions), zero-warning `iverilog -Wall -g2005 -tnull design/*.v` compile, and 180 constrained-
random seeds clean across every axis this project's harness supports — 30 at default settings,
20 each at `--hazard-strategy 1`, `--pipeline-profile 1`, `--branch-predictor 1`,
`--cache-mode 1`, `--mmu`, `--mem-latency-i 3 --mem-latency-d 3`, one combined run (hazard=1,
profile=1, predictor=1, cache=1, latency=2/2), and 30 at `--xlen 64`.

## Alternatives considered

See Decision above — retiring `ble`/`bgt` as real hardware in favor of assembler pseudo-ops was
the only real alternative considered, rejected for being a larger change with no functional
benefit over the simpler swap.

## Future improvements

riscv-arch-test / Spike/Sail tooling integration itself remains blocked by the separate,
unrelated Windows-native reference-model problem (`docs/adr/0029`) — this phase only removed the
*encoding* half of that blocker. Generation 3 (MMU/privilege/Linux boot) can now proceed; its own
Sv39 MMU work is still a from-scratch design, not a port of Phase F's Sv32 `Tlb.v`/`Ptw.v`
(`docs/ROADMAP_VISION.md`).
