# ADR 0014: Closing verification gaps — and two real CSR/reset bugs found doing it

## Problem

`docs/ARCHITECTURE.md` §15 and the `docs/ROADMAP.md` status log documented
three known, lower-priority verification gaps left over from earlier phases:

1. `blt`/`bge`/`ble`/`bgt`/`bltu`/`bgeu` each had directed coverage of only
   one branch direction (taken *or* not-taken, never both).
2. `ALUCtl == ALUCTL_ILLEGAL` (a *recognized* opcode with an unrecognized
   funct7/funct3, as opposed to `illegalOpcode`'s unrecognized-opcode case)
   had no directed test.
3. `sim/tools/random_gen.py` never generated CSR instructions, so
   constrained-random cross-checking had never touched `design/CSR.v`.

Closing (3) surfaced two real, previously-invisible RTL bugs — the more
interesting part of this ADR.

## Design

### Closing gaps 1 and 2 (directed tests)

- `sim/programs/branch_dir_gaps.s` / `tb_branch_dir_gaps.v`: the same
  `x1=-1(0xFFFFFFFF)`/`x2=1` bit pattern `bltu_bgeu.s` already uses, but with
  every comparison's operands **swapped**. None of these six branches is the
  equality case, so swapping always flips the outcome — this exercises
  exactly the direction `bltu_bgeu.s` doesn't, without needing a new bit
  pattern. Kept as a separate program rather than extended into
  `bltu_bgeu.s` itself: the combined program exceeds the default 128-byte
  (32-instruction) instruction memory every existing test assumes.
- `sim/programs/aluctl_illegal.s` / `tb_aluctl_illegal.v`: `word 0x40001033`
  — an R-type instruction (`asm.py`'s raw-word escape hatch, same one
  `illegal_instr.s` uses for its unrecognized-*opcode* case) with
  `funct7=FUNCT7_ALT` (`0100000`, the block that only defines `sub`/`sra`/
  `ctz`) and `funct3=001` — a combination `ALUCtrl.v`'s case statement has no
  arm for, falling through to its `default: ALUCtl = ALUCTL_ILLEGAL`. Same
  trap-verification shape as `illegal_instr.s` (mtvec/mepc/mcause, redirect
  skips the two following instructions, handler runs).

### Closing gap 3 (random CSR generation) — scoped deliberately

`random_gen.py` now generates `csrrw`/`csrrs`/`csrrc`(+immediate variants)
against all five implemented CSRs, alongside the existing instruction mix.
Deliberately **not** generating `ecall`/`ebreak`/`mret`/deliberately-illegal
instructions: those redirect control flow to `mtvec`/`mepc`, which would
need real safety machinery (a guaranteed-safe `mtvec`, trap-recursion
tracking) to keep generated programs forward-only and guaranteed-
terminating the way the existing generator already guarantees for
branches/`jal`. CSR reads/writes are pure register/CSR data movement with no
such risk, and `ecall`/`ebreak`/`mret`/illegal-instruction control flow is
already covered by five directed tests (`ecall_trap.s`, `ebreak_trap.s`,
`illegal_instr.s`, `aluctl_illegal.s`, `mret_return.s`). Disproportionate
machinery for what's already verified elsewhere.

## Two real bugs found extending random testing to CSR ops

Neither was visible in the directed suite — both needed the specific
adjacency random testing happened to generate (a CSR/trap instruction
immediately preceded by something that stalls the pipeline, or reading a
CSR before any real instruction has executed). Found by actually running
the suite after the generator change, not by reasoning about the design
statically — consistent with this project's verification standard.

### 1. `CSR.v` double-applies its write when `reg2` is held

`docs/adr/0013`'s `mem_stall` interlock holds `reg2` for one cycle whenever
the instruction it's decoding directly follows a load still waiting on
`DataMemoryBRAM`. For `jal`/branch redirects this is provably safe (`reg2`'s
`hold` has priority over its own `branch_taken` squash, and `reg3` only ever
captures `reg2`'s *pre-edge* value at the exact cycle it's finally accepted
— see `docs/adr/0013`'s design section). `CSR.v` is different: it's an
external stateful module whose `csr_write_en`/`trap_taken`/`mret_taken`
inputs were wired directly to combinational signals (`isCsr_regde`,
`exception_taken`, `isMret_regde`) computed live off `reg2`'s *current*
output — which, while `reg2` is held, is the *same* instruction's decode
context for every one of those cycles. `CSR.v` has no notion of "already
applied this instruction's effect" the way `reg3`'s bubbling or `reg2`'s own
hold-priority does; it just sees `csr_write_en` asserted on every held
cycle and writes every time.

Symptom: `csrrwi x1, mcause, 3` immediately after a load returned `x1 = 3`
(the *newly written* value) instead of `0` (the true old value) — the first
held cycle wrote `mcause <- 3`, and the *second* (real, accepted) cycle then
read back `csr_rdata` reflecting that already-applied write instead of the
genuine old value. The same double-application also corrupts `mstatus`
specifically for `trap_taken`/`mret_taken`, since their MIE/MPIE swap is
self-referencing (`mstatus[7] <= mstatus[3]` then, one cycle later with
`mstatus[3]` now zeroed by the first application, `mstatus[7] <= 0`).

Fixed by gating exactly the three side-effecting `CSR.v` inputs with
`&& !reg2_hold` (`reg2_hold`, a new name for `div_stall | mem_stall` —
already `reg2`'s own `.hold` input, just not previously factored into a
named wire). `exception_taken`/`unconditional_redirect`'s *other* uses
(driving `redirect_target`, squashing `reg1`/`reg2`) are deliberately left
untouched — those are already correct, protected by the same mechanisms
that make `jal`/branch safe.

This is the same underlying bug shape `docs/adr/0009` documented for the
divider's `busy`/`done` re-triggering and `docs/adr/0013` hit again for
`DataMemoryBRAM`'s back-to-back-load ambiguity: a bare combinational level
signal, asserted for multiple cycles by an external hold it knows nothing
about, can't distinguish "still the same request" from "apply this again."
Three occurrences now, all fixed the same way (track it locally, or gate by
the holding condition) — worth treating as a standing design rule for any
future module wired to a combinational EX-stage signal, not a one-off.

### 2. Reset primes `inst_regfd` with a value that decodes as a real trap

Independent of (1), and actually the *dominant* cause of failures once
found: `reg1.v`'s reset branch set `inst_regfd <= 0` — literal zero. Opcode
`0000000` has been a genuine illegal-instruction trap since `docs/adr/0011`
(intentionally: it's what instruction memory's zero-filled remainder decodes
as, so running off the end of a program traps instead of silently
NOP-ing). `reg1.v`'s own *squash* path already knew to avoid this
(`inst_regfd <= 32'h00000013`, a real `nop`, on a taken branch/jal) — reset
never got the same treatment, and squash/reset are the only two places
`inst_regfd` is assigned anything other than a genuine fetched instruction.

For the one cycle between reset releasing and the first real fetch reaching
`reg1`'s output, `Control.v` decodes this leftover raw-zero reset value as
opcode `0000000` and correctly (given its input) raises an illegal-
instruction trap — writing `mcause <- 2`, `mepc <- 0`, redirecting to
`mtvec` (which defaults to 0, so the *redirect itself* is an accidental
no-op, since PC is already heading to 0 during this same warm-up window).
The corruption is invisible to PC/control-flow, but very visible to
`mcause`/`mepc`/`mstatus` — and every existing directed CSR/exception test
was structurally blind to it, since each one explicitly sets `mtvec` and
deliberately triggers its *own* real trap before ever reading these CSRs,
overwriting the startup artifact before checking anything. Random testing,
once it started generating early CSR reads, was the first thing ever to
look at `mcause` before a real trap had (deliberately) occurred — 19 of the
first 150 seeds tried (after CSR generation was added, before either fix)
failed on exactly this, all reading back `mcause == 2` where the ISS
(which has no equivalent reset-artifact concept) expected `0`.

Fixed by changing `reg1.v`'s reset value for `inst_regfd` to `32'h00000013`
(the same `nop` the squash path already uses), matching `pc_o_regfd`'s
existing all-zero reset (which was never the problem — a PC value of 0 is a
perfectly valid address). `reg2.v`'s own reset value for `inst_regde` was
*not* changed: it already explicitly zeroes `illegalOpcode_regde` (and every
other control field) on its own reset via `ZERO_CONTROL_FIELDS`, so its raw
`inst_regde <= 0` was already inert — the actual exposure was purely
`Control.v` decoding `reg1`'s leftover value live, before `reg2` ever had a
chance to latch a corrected result.

## Alternatives considered

- **Gate `CSR.v`'s writes with a "first cycle only" pulse derived inside
  `CSR.v` itself**, mirroring `Divider.v`'s internal `busy`/`done` guard.
  Rejected: `CSR.v` has no multi-cycle state of its own to track — the
  ambiguity is entirely about the *caller's* hold behavior, which `CSR.v`
  has no way to observe except through the very signals that are already
  ambiguous. Gating at the call site (where `reg2_hold` is already known)
  is the more local fix, same reasoning `docs/adr/0013` used for preferring
  pipeline-local tracking over a memory-provided valid signal.
- **Zero `inst_regfd` but separately force `illegalOpcode_regde` to a
  "startup grace period" value.** Rejected: adds a new concept (a grace
  period) instead of removing the actual inconsistency (reset and squash
  disagreeing about what a "no real instruction here" value looks like).
  Matching squash's existing `nop` convention is simpler and more locally
  justified.
- **Generate `ecall`/`ebreak`/`mret` in `random_gen.py` too**, for maximal
  coverage. Rejected for now — see Design above; the safety machinery this
  would need is disproportionate to what's already directed-tested, and
  isn't blocking anything else.

## Validation strategy

- Full directed suite: 25/25 tests (23 pre-existing + `branch_dir_gaps.s` +
  `aluctl_illegal.s`), no regressions.
- `sim/tools/coverage_report.py`: confirms both directed-test gaps are
  actually closed — every branch type now shows `taken=1 not-taken=1`
  (previously one side was always 0), and `ALUCtl 31 ILLEGAL` now shows
  1 cycle of real coverage (previously absent from the report entirely).
- Constrained-random cross-check, extended generator: 200/200 at default
  program length plus 150/150 at 24 instructions/program across a disjoint
  seed range, both post-fix. Pre-fix, the same extended generator reliably
  failed ~13% of programs (19/150) on the reset-artifact bug alone, plus a
  narrower set on the `reg2_hold` double-write bug specifically (isolated
  by bisecting: fixing (1) alone changed the observed wrong value from the
  written data itself to `mcause`'s stale-2 poison, which is what led to
  finding (2)).
- `iverilog -Wall -g2005 -I design -tnull design/*.v`: clean, zero warnings.

## Future improvements

- The "combinational EX-stage signal driving an external stateful module
  needs explicit hold-awareness" lesson (bug 1) is now a three-time pattern
  (`docs/adr/0009`, `docs/adr/0013`, this ADR) — worth a grep across
  `design/*.v` for any other module wired the same way before the next
  multi-cycle or external-hazard mechanism is added, rather than
  discovering each instance via random testing one at a time.
- `random_gen.py` still doesn't generate `ecall`/`ebreak`/`mret`/
  deliberately-illegal instructions (see Alternatives). If trap-heavy
  random programs are ever wanted, the needed safety machinery (safe
  `mtvec`, recursion tracking) is a real, scoped follow-on, not a small
  addition to the current generator shape.
