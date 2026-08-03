# Branch Encoding Fix (Phase N) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `blt`/`bge` to real RISC-V spec funct3 positions (100/101) and this core's
custom `ble`/`bgt` to the vacated reserved positions (010/011), across RTL and all three Python
tools, so a real GCC-compiled program's `blt`/`bge` decodes correctly on this core.

**Architecture:** A pure encoding swap, no new modules, no semantic change to any comparison.
Four tables move together in one commit: `design/ALUCtrl.v`'s branch-decode case statement,
`sim/tools/asm.py`'s `BRANCH` encoder dict, `sim/tools/disasm.py`'s `names` decoder dict, and
`sim/tools/iss.py`'s `taken` dispatch dict in the reference-model branch handler.

**Tech Stack:** Verilog (Icarus Verilog / `iverilog`), Python 3 (no external deps — this
project's own `sim/tools/` scripts).

## Global Constraints

- `bltu`/`bgeu` (funct3 110/111) are unchanged — already spec-correct.
- No change to `ALU.v` or any `ALUCTL_*` macro value in `design/riscv_defs.vh` — only which
  funct3 pattern maps to which existing `ALUCtl` code moves.
- Every existing directed test, every `.s` program, and `random_gen.py`/`bench_runner.py` must
  keep working unmodified — they reference branch mnemonics, never raw funct3 bits.
- Full spec: `docs/superpowers/specs/2026-08-03-branch-encoding-fix-design.md`.

---

### Task 1: RTL — swap `ALUCtrl.v`'s branch funct3→ALUCtl mapping

**Files:**
- Modify: `design/ALUCtrl.v:60-76`
- Test: `sim/tb/tb_aluctrl_unit.v` (extend existing file — do not create a new one; it already
  instantiates `ALUCtrl` standalone and has a `check_ctl` task ready to reuse)

**Interfaces:**
- Consumes: `design/riscv_defs.vh`'s existing `ALUCTL_BEQ`/`ALUCTL_BNE`/`ALUCTL_BLT`/
  `ALUCTL_BGE`/`ALUCTL_BLE`/`ALUCTL_BGT`/`ALUCTL_BLTU`/`ALUCTL_BGEU` macros (values: `5'b01010`,
  `5'b01011`, `5'b01100`, `5'b01101`, `5'b01110`, `5'b10000`, `5'b10001`, `5'b10010`
  respectively — unchanged by this task).
- Produces: `ALUCtrl` module's `ALUCtl` output now reflects the corrected funct3 mapping — Task
  2 (Python tooling) and Task 3 (verification) depend on this being done first so the full-suite
  regression run in Task 3 exercises the real fix.

- [ ] **Step 1: Read current state to confirm line numbers haven't drifted**

Run: `sed -n '58,80p' design/ALUCtrl.v` (or open the file) and confirm it still reads:

```verilog
else if(ALUOp == `ALUOP_BRANCH)
    begin
    case(concat2)
        5'b01000: //beq
        ALUCtl = `ALUCTL_BEQ;
        5'b01001: //bne
        ALUCtl = `ALUCTL_BNE;
        5'b01010: //blt
        ALUCtl = `ALUCTL_BLT;
        5'b01011: //bge
        ALUCtl = `ALUCTL_BGE;
        5'b01100: //ble (custom)
        ALUCtl = `ALUCTL_BLE;
        5'b01101: // bgt (custom)
        ALUCtl = `ALUCTL_BGT;
        5'b01110: //bltu
        ALUCtl = `ALUCTL_BLTU;
        5'b01111: //bgeu
        ALUCtl = `ALUCTL_BGEU;
        default:
        ALUCtl = `ALUCTL_ILLEGAL;  // unrecognized funct7/funct3 combination for this ALUOp
    endcase
    end
```

If it doesn't match, stop and re-locate the block before proceeding (something else changed
this file first).

- [ ] **Step 2: Swap the four case arms**

Replace the block from Step 1 with:

```verilog
else if(ALUOp == `ALUOP_BRANCH)
    begin
    // Generation 3 prerequisite (Phase N, docs/adr/0030-branch-encoding-fix.md): blt/bge
    // moved to their real RISC-V spec funct3 positions (100/101); this core's own custom
    // ble/bgt moved to the now-vacant reserved positions (010/011). A real GCC-compiled
    // program's blt/bge previously misdecoded as this core's custom ble/bgt.
    case(concat2)
        5'b01000: //beq
        ALUCtl = `ALUCTL_BEQ;
        5'b01001: //bne
        ALUCtl = `ALUCTL_BNE;
        5'b01010: //ble (custom, moved here from 100)
        ALUCtl = `ALUCTL_BLE;
        5'b01011: //bgt (custom, moved here from 101)
        ALUCtl = `ALUCTL_BGT;
        5'b01100: //blt (real spec position, moved here from 010)
        ALUCtl = `ALUCTL_BLT;
        5'b01101: //bge (real spec position, moved here from 011)
        ALUCtl = `ALUCTL_BGE;
        5'b01110: //bltu
        ALUCtl = `ALUCTL_BLTU;
        5'b01111: //bgeu
        ALUCtl = `ALUCTL_BGEU;
        default:
        ALUCtl = `ALUCTL_ILLEGAL;  // unrecognized funct7/funct3 combination for this ALUOp
    endcase
    end
```

- [ ] **Step 3: Write the new bit-level unit test**

Open `sim/tb/tb_aluctrl_unit.v`. It already has `ALUOp`, `funct7_c`, `funct3_c` regs, the `dut`
instance, and a `check_ctl` task. Add a second `initial begin ... end` block (Verilog allows
multiple `initial` blocks; keep this separate from the existing SRL/SRA one so either can be
read independently) right after the existing one, before `endmodule`:

```verilog
initial begin
    #2; // let the first initial block's checks finish before this one starts driving DUT inputs
    ALUOp = `ALUOP_BRANCH;
    funct7_c = 0; // branches don't use funct7

    funct3_c = 3'b100;
    #1 check_ctl(`ALUCTL_BLT, "funct3=100 -> BLT (real spec position)");
    funct3_c = 3'b101;
    #1 check_ctl(`ALUCTL_BGE, "funct3=101 -> BGE (real spec position)");
    funct3_c = 3'b010;
    #1 check_ctl(`ALUCTL_BLE, "funct3=010 -> BLE (custom, moved to reserved slot)");
    funct3_c = 3'b011;
    #1 check_ctl(`ALUCTL_BGT, "funct3=011 -> BGT (custom, moved to reserved slot)");
    funct3_c = 3'b110;
    #1 check_ctl(`ALUCTL_BLTU, "funct3=110 -> BLTU (unchanged)");
    funct3_c = 3'b111;
    #1 check_ctl(`ALUCTL_BGEU, "funct3=111 -> BGEU (unchanged)");

    if (fails == 0)
        $display("PASS  aluctrl_branch_encoding (%0d checks)", checks);
    else
        $display("FAIL  aluctrl_branch_encoding (%0d/%0d checks failed)", fails, checks);
end
```

Note: the existing `initial begin` block already ends with `$finish;` — `$finish` terminates the
whole simulation immediately, so this new block's checks would never run if it stays there.
Remove the `$finish;` call from the *first* `initial` block's end (keep its two `$display` summary
lines) and add a single `$finish;` as the very last line of the *new* second `initial` block
instead, so both blocks' checks complete before the simulation ends.

- [ ] **Step 4: Run the unit test to confirm it currently fails**

Run: `iverilog -g2005 -o /tmp/tb_aluctrl sim/tb/tb_aluctrl_unit.v && vvp /tmp/tb_aluctrl`

Expected: the four new checks (`funct3=100 -> BLT`, `funct3=101 -> BGE`, `funct3=010 -> BLE`,
`funct3=011 -> BGT`) currently exist only if Step 2 already ran — if you run this test *before*
Step 2, expect these four specifically to FAIL (old mapping still in place). If you're running
Step 4 after Step 2 (recommended order — RTL first), skip the "confirm it fails" framing and go
straight to Step 5's "confirm it passes" instead.

- [ ] **Step 5: Confirm the test passes with the Step 2 fix in place**

Run: `iverilog -g2005 -o /tmp/tb_aluctrl sim/tb/tb_aluctrl_unit.v && vvp /tmp/tb_aluctrl`

Expected: `PASS  aluctrl_unit (4 checks)` (existing SRL/SRA block) and
`PASS  aluctrl_branch_encoding (6 checks)` (new block), zero `FAIL` lines.

- [ ] **Step 6: Zero-warning compile check across the whole design tree**

Run: `iverilog -Wall -g2005 -tnull design/*.v`

Expected: no output at all (this project's standing zero-warning bar). If any warning appears
that wasn't there before this change, stop and investigate before continuing — do not proceed to
Task 2 with a new warning unexplained.

- [ ] **Step 7: Commit**

```bash
git add design/ALUCtrl.v sim/tb/tb_aluctrl_unit.v
git commit -m "$(cat <<'EOF'
Phase N: swap blt/bge and ble/bgt funct3 encoding in ALUCtrl.v

blt/bge move to real RISC-V spec positions (100/101); this core's custom
ble/bgt move to the vacated reserved positions (010/011). RTL half of the
fix -- Python tooling (asm.py/disasm.py/iss.py) is a separate task, must
land before any full-suite run will pass again.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

Note: the full test suite (`sim/run_tests.sh`) will NOT pass after this commit alone — the
Python assembler/ISS still encode the old mapping. That's expected; Task 2 fixes it. Do not run
`sim/run_tests.sh` as a gate until Task 2 is done.

---

### Task 2: Python tooling — swap `asm.py`/`disasm.py`/`iss.py` in lockstep

**Files:**
- Modify: `sim/tools/asm.py:107-110`
- Modify: `sim/tools/disasm.py:168`
- Modify: `sim/tools/iss.py:1143-1148`
- Test: new `sim/tools/test_branch_encoding_roundtrip.py`

**Interfaces:**
- Consumes: Task 1's corrected RTL mapping (this task must match it exactly, or the full-suite
  regression in Task 3 will fail on every branch instruction).
- Produces: `asm.py`'s `BRANCH` dict, `disasm.py`'s branch `names` dict, and `iss.py`'s branch
  `taken` dispatch — all three now encode blt=100/bge=101/ble=010/bgt=011, matching
  `design/ALUCtrl.v`. Task 3 depends on all three being updated before running the full suite.

- [ ] **Step 1: Update `asm.py`'s `BRANCH` dict**

In `sim/tools/asm.py`, replace lines 107-110:

```python
BRANCH = {  # mnemonic: funct3 -- beq/bne/blt/bge/ble/bgt/bltu/bgeu (ble/bgt custom, see docs/ARCHITECTURE.md sec 5)
    "beq": 0b000, "bne": 0b001, "blt": 0b010, "bge": 0b011,
    "ble": 0b100, "bgt": 0b101, "bltu": 0b110, "bgeu": 0b111,
}
```

with:

```python
BRANCH = {  # mnemonic: funct3 -- beq/bne/blt/bge/ble/bgt/bltu/bgeu. blt/bge at real RISC-V
    # spec positions (100/101); ble/bgt are this core's own custom ops, at the reserved
    # positions (010/011) real spec leaves unused (docs/adr/0030-branch-encoding-fix.md).
    "beq": 0b000, "bne": 0b001, "blt": 0b100, "bge": 0b101,
    "ble": 0b010, "bgt": 0b011, "bltu": 0b110, "bgeu": 0b111,
}
```

- [ ] **Step 2: Update `disasm.py`'s branch `names` dict**

In `sim/tools/disasm.py`, replace line 168:

```python
        names = {0: "beq", 1: "bne", 2: "blt", 3: "bge", 4: "ble", 5: "bgt", 6: "bltu", 7: "bgeu"}
```

with:

```python
        names = {0: "beq", 1: "bne", 2: "ble", 3: "bgt", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}
```

- [ ] **Step 3: Update `iss.py`'s branch dispatch**

In `sim/tools/iss.py`, replace lines 1143-1148:

```python
            taken = {
                0: self.sxlen(A) == self.sxlen(B), 1: self.sxlen(A) != self.sxlen(B),
                2: self.sxlen(A) < self.sxlen(B), 3: self.sxlen(A) >= self.sxlen(B),
                4: self.sxlen(A) <= self.sxlen(B), 5: self.sxlen(A) > self.sxlen(B),
                6: self.uxlen(A) < self.uxlen(B), 7: self.uxlen(A) >= self.uxlen(B),
            }[f3]
```

with:

```python
            taken = {
                0: self.sxlen(A) == self.sxlen(B), 1: self.sxlen(A) != self.sxlen(B),
                2: self.sxlen(A) <= self.sxlen(B), 3: self.sxlen(A) > self.sxlen(B),
                4: self.sxlen(A) < self.sxlen(B), 5: self.sxlen(A) >= self.sxlen(B),
                6: self.uxlen(A) < self.uxlen(B), 7: self.uxlen(A) >= self.uxlen(B),
            }[f3]
```

- [ ] **Step 4: Write the assemble→disassemble round-trip test**

Create `sim/tools/test_branch_encoding_roundtrip.py`:

```python
"""Phase N (docs/adr/0030-branch-encoding-fix.md): confirms asm.py and disasm.py agree on
the post-swap branch funct3 encoding, and that it matches the real RISC-V spec positions for
blt/bge. Run directly: python sim/tools/test_branch_encoding_roundtrip.py
"""
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from asm import assemble
from disasm import disasm

EXPECTED_FUNCT3 = {"beq": 0b000, "bne": 0b001, "blt": 0b100, "bge": 0b101,
                   "ble": 0b010, "bgt": 0b011, "bltu": 0b110, "bgeu": 0b111}


def check_roundtrip(mnemonic):
    asm_line = f"{mnemonic} x1, x2, 0"
    words = assemble([asm_line])
    assert len(words) == 1, f"{mnemonic}: expected 1 assembled word, got {len(words)}"
    word = words[0]
    funct3 = (word >> 12) & 0x7
    expected = EXPECTED_FUNCT3[mnemonic]
    assert funct3 == expected, (
        f"{mnemonic}: asm.py encoded funct3={funct3:03b}, expected {expected:03b}"
    )
    text = disasm(word)
    assert text.startswith(mnemonic + " "), (
        f"{mnemonic}: round-trip disassembled as '{text}', expected it to start with "
        f"'{mnemonic} '"
    )


def main():
    fails = 0
    for mnemonic in EXPECTED_FUNCT3:
        try:
            check_roundtrip(mnemonic)
            print(f"pass  {mnemonic}")
        except AssertionError as e:
            fails += 1
            print(f"FAIL  {mnemonic}: {e}")
    if fails == 0:
        print(f"PASS  branch_encoding_roundtrip ({len(EXPECTED_FUNCT3)} checks)")
        return 0
    else:
        print(f"FAIL  branch_encoding_roundtrip ({fails}/{len(EXPECTED_FUNCT3)} checks failed)")
        return 1


if __name__ == "__main__":
    sys.exit(main())
```

Confirmed real signatures (checked directly, not guessed): `assemble(lines, xlen=32)` in
`sim/tools/asm.py:375`, returns a list of assembled words; `disasm(word, xlen=32)` in
`sim/tools/disasm.py:78` (not `disassemble` — note the name above matches this already).

- [ ] **Step 5: Run the round-trip test, confirm it passes**

Run: `python sim/tools/test_branch_encoding_roundtrip.py`

Expected: 8 `pass` lines, then `PASS  branch_encoding_roundtrip (8 checks)`, exit code 0.

- [ ] **Step 6: Commit**

```bash
git add sim/tools/asm.py sim/tools/disasm.py sim/tools/iss.py sim/tools/test_branch_encoding_roundtrip.py
git commit -m "$(cat <<'EOF'
Phase N: swap blt/bge and ble/bgt funct3 encoding in asm.py/disasm.py/iss.py

Matches the design/ALUCtrl.v swap from the previous commit -- blt/bge now
at real spec positions (100/101), custom ble/bgt at the vacated reserved
positions (010/011). New assemble-disassemble round-trip test catches any
future asm.py/disasm.py table drift independent of a full pipeline run.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Full regression + constrained-random verification

**Files:**
- None modified (verification only) — unless a regression is found, in which case stop and fix
  it in the file it's found in before continuing, then re-run this task's steps from the start.

**Interfaces:**
- Consumes: Task 1 (RTL swap) and Task 2 (Python tooling swap), both already committed.
- Produces: verification evidence for `docs/adr/0030-branch-encoding-fix.md` (Task 4 quotes
  these exact results).

- [ ] **Step 1: Zero-warning full compile**

Run: `iverilog -Wall -g2005 -tnull design/*.v`

Expected: no output.

- [ ] **Step 2: Full directed suite**

Run: `bash sim/run_tests.sh` (or the project's equivalent existing entry point — check
`sim/run_tests.sh` itself if the exact invocation has changed since this plan was written).

Expected: 100% pass, same total test/check count as the last known-good run before this phase
(check `handoff.md`'s most recent verification count to compare — currently 83/83 directed
tests as of Phase M). If any test newly fails, it almost certainly means Task 1 and Task 2's
swaps aren't bit-identical to each other — recheck both against this plan's exact code blocks
before assuming a pre-existing bug.

- [ ] **Step 3: Constrained-random cross-check, default settings**

Run: `python sim/tools/run_random_tests.py` (default flags — check the script's own `--help` for
the current default seed count if unsure).

Expected: 100% clean (no register/memory/CSR mismatch between RTL and `iss.py`).

- [ ] **Step 4: Constrained-random cross-check, full axis sweep**

Run the same random-test runner across each axis this project's harness supports individually,
matching the bar every prior phase used (see `handoff.md`'s Phase M/I/G sections for the exact
flag names currently supported: `--hazard-strategy`, `--pipeline-profile`, `--branch-predictor`,
`--cache-mode`, `--mmu`, `--mem-latency-i`/`--mem-latency-d`, and one combined "everything at
once" run). Confirm the exact current flag names against `python sim/tools/run_random_tests.py
--help` first — don't assume the names above are still current without checking.

Expected: 100% clean on every individual axis and the combined run.

- [ ] **Step 5: If everything above passed, there's no code change in this task — proceed to Task 4.**

If anything failed, fix it in Task 1 or Task 2's files, re-commit as a new commit (not an amend,
per this project's own git discipline), and re-run this task's Steps 1-4 from the start before
proceeding.

---

### Task 4: Documentation — new ADR + update existing docs

**Files:**
- Create: `docs/adr/0030-branch-encoding-fix.md`
- Modify: `docs/ARCHITECTURE.md` (§11 branch row)
- Modify: `docs/ROADMAP_VISION.md` (Generation 3 section + the two spots referencing the old
  encoding, found via `grep -n "Generation 3" docs/ROADMAP_VISION.md` — re-locate exact line
  numbers at implementation time since this plan doesn't hardcode them, to avoid stale line
  references if the file changes before this task runs)
- Modify: `handoff.md` (Generation 2 closure / ADR 0029 pointer section)

**Interfaces:**
- Consumes: Task 3's verification results (exact pass counts) and Task 1/Task 2's commit SHAs
  (`git log --oneline -5` to get them).

- [ ] **Step 1: Get the two commit SHAs from Task 1 and Task 2**

Run: `git log --oneline -5`

Note the two SHAs for "Phase N: swap blt/bge and ble/bgt funct3 encoding in ALUCtrl.v" and
"...in asm.py/disasm.py/iss.py" — use them in the ADR's own references below (replace
`<ALUCTRL_SHA>`/`<TOOLING_SHA>` with the real short hashes).

- [ ] **Step 2: Write `docs/adr/0030-branch-encoding-fix.md`**

```markdown
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

Four files, two commits (`<ALUCTRL_SHA>` for RTL, `<TOOLING_SHA>` for tooling — deliberately
sequential, not squashed, matching this project's discipline of new commits over amends, though
the full suite only passes again once both land):

- `design/ALUCtrl.v` — branch-decode case statement, 4 arms swapped.
- `sim/tools/asm.py` — `BRANCH` encoder dict, 4 entries swapped.
- `sim/tools/disasm.py` — `names` decoder dict, 4 entries swapped.
- `sim/tools/iss.py` — `taken` dispatch dict in the branch handler, 4 entries swapped.

No change to `ALU.v` or any `ALUCTL_*` macro value — only which funct3 pattern maps to which
existing code moved. No change to any `.s` test program, `random_gen.py`, or `bench_runner.py` —
all reference branch mnemonics, never raw funct3 bits.

## Validation strategy

New bit-level unit test (`sim/tb/tb_aluctrl_unit.v`, 6 new checks: all 4 changed encodings plus
`bltu`/`bgeu` confirmed unchanged) and a new assemble-disassemble round-trip test
(`sim/tools/test_branch_encoding_roundtrip.py`, 8 checks, one per branch mnemonic) — both confirm
the fix at the bit level independent of a full pipeline run. Full regression: [fill in the exact
directed-test pass count, zero-warning compile result, and random cross-check pass counts from
Task 3's actual run output before finalizing this ADR — do not leave these as placeholders in the
committed version].

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
```

**Before committing this file**, replace the `[fill in the exact...]` bracket with Task 3's real
output (this is the one placeholder in this plan that's *intentional* — it depends on Task 3's
live results, which don't exist until that task runs; it must not remain a placeholder in the
version actually committed).

- [ ] **Step 3: Update `docs/ARCHITECTURE.md` §11's branch row**

Find the row (currently):

```
| Branches | `beq bne blt bge bltu bgeu` (6/6 standard) plus custom `ble bgt` (funct3=100/101, using the two funct3 codes standard RV32I leaves for `bltu`/`bgeu` — those got the two *other* free codes, funct3=110/111; see `docs/adr/0005`) | — |
```

Replace with:

```
| Branches | `beq bne blt bge bltu bgeu` (6/6 standard, all at real spec funct3 positions) plus custom `ble bgt` (funct3=010/011, the two funct3 codes real RV32I spec reserves and leaves undefined; moved here from the real `blt`/`bge` spec positions by `docs/adr/0030-branch-encoding-fix.md` — see that ADR and `docs/adr/0005` for the historical positions) | — |
```

- [ ] **Step 4: Update `docs/ROADMAP_VISION.md`**

Run: `grep -n "Generation 3\|blt\|bge\|encoding" docs/ROADMAP_VISION.md` to find the current
exact line numbers (this plan deliberately doesn't hardcode them — re-check at implementation
time). Update the Generation 3 section's own text and the "open question" section that discusses
this core's branch-encoding deviation, adding a note that the encoding fix is done
(`docs/adr/0030`) and Generation 3 itself can now start.

- [ ] **Step 5: Update `handoff.md`**

In the "COMPLETE: Generation 2 is CLOSED" section (near the top of the file, the part discussing
the two riscv-arch-test blockers), add a note directly after the branch-encoding blocker
paragraph: the encoding half is now resolved (`docs/adr/0030-branch-encoding-fix.md`, Phase N) —
`blt`/`bge` now sit at real spec positions. The Windows-native reference-model tooling blocker
(the *other* half) is unchanged and still open. Generation 3 can now start; it's no longer
gated on this.

- [ ] **Step 6: Commit the docs**

```bash
git add docs/adr/0030-branch-encoding-fix.md docs/ARCHITECTURE.md docs/ROADMAP_VISION.md handoff.md
git commit -m "$(cat <<'EOF'
Phase N: docs for branch encoding fix, closing out the Gen3 prerequisite

docs/adr/0030 written; ARCHITECTURE.md/ROADMAP_VISION.md/handoff.md
updated to reflect blt/bge now at real spec funct3 positions. Generation
3 (OS support) is unblocked to start next.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes (for whoever executes this plan)

- **Spec coverage:** every section of `docs/superpowers/specs/2026-08-03-branch-encoding-fix-design.md`
  maps to a task here — RTL (Task 1), tooling (Task 2), verification (Task 3), docs (Task 4).
  Nothing in the spec's scope is unaddressed.
- **The one deliberate placeholder** is Task 4 Step 2's bracketed verification-numbers note —
  it depends on Task 3's live output and cannot be filled in before Task 3 actually runs. Do not
  leave it as a placeholder in the committed ADR; fill it with Task 3's real results first.
- **Task 2 Step 4's function names were verified directly** (`assemble` in `asm.py:375`, `disasm`
  in `disasm.py:78` — not the initially-assumed `disassemble`) rather than guessed, so the test
  code in this plan is final, not provisional.
