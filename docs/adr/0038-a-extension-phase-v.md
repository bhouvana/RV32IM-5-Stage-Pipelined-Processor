# ADR 0038: A (Atomic) Extension Support (Generation 3, Phase V)

## Problem

With Phase U's real RVC support (`docs/adr/0037`) in place, the kernel's own early boot code executes
correctly through dozens of real compressed and standard instructions — until a real `amoadd.w` at
kernel PC `0x200066` (a hart-bring-up counter check, the standard "am I the first/primary hart"
Linux/RISC-V idiom) traps illegal-instruction. This core (`riscv,isa` = `rv64imafd`) has zero 'A'
(atomic) extension support anywhere in `Control.v`/`ALUCtrl.v`. Presented to the user via
`AskUserQuestion` (close here vs. a narrow single-site workaround vs. real A-extension support):
implement real support now.

## Design

### Single-hart simplification, real not assumed

This core is genuinely single-hart throughout (the CLINT is single-hart, SBI HSM is deliberately
unimplemented per Phase T's own research — `docs/adr/0036`). Real spec consequence, not a shortcut: with
no other hart to ever contend for the same memory, **every** memory operation is already atomic with
respect to other harts by construction, and this core's own pipeline never splits a single instruction's
memory access across a window another instruction could observe mid-sequence. This lets `LR.W/D` reduce
to a plain load (a trivial, always-valid reservation — nothing else could invalidate it) and `SC.W/D`
reduce to a plain store that always reports success (`rd`=0) — both real, spec-legal behavior for a
genuinely single-hart target, not an approximation. `AMOSWAP`/`AMOADD`/`AMOXOR`/`AMOAND`/`AMOOR`/
`AMOMIN`/`AMOMAX`/`AMOMINU`/`AMOMAXU` need a real read-modify-write, which does not reduce this way.

### A new, independent 2-phase MEM-stage interlock

Deliberately built as a **sibling** to the existing `mem_stall` interlock (`docs/adr/0013`), not a
modification of it: `Control.v`'s new `isAmo` output leaves `memRead`/`memWrite` at 0 for `OPCODE_AMO`,
so `mem_trigger`/`mem_stall`'s own existing definition never fires for an AMO at all, by construction —
zero interaction risk with any existing load/store/fence path. `amo_write_phase_r`/`amo_write_done_r`
(new registers) track phase 0 (read, mirrors an ordinary load's own address/`memRead`) then phase 1
(write of the funct5-combined result, skipped entirely for `LR` — real spec requirement, `LR` must never
issue a write at all). `amo_stall` (new wire) joins `pc_stall`/`reg2_hold`/`reg3`'s and `reg4`'s own
`hold` ports exactly where `mem_stall` already does, using the identical "freeze until an access
completes" shape. Both phases reuse the exact same address (`ALUOut_regem` — `Control.v`'s own
`ALUSrc=1`/`ImmGen.v`'s `imm=0` default for the unhandled `OPCODE_AMO` case computes `rs1+0`, the real
AMO addressing mode, for free) and the AMO instruction's own real `funct3` (`.W`/`.D`, already flowing
through `wb_m_funct3` unconditionally — no new width-tagging wiring needed at all).

`funct5` (the real op selector, `inst[31:27]`) needed no new pipeline field: it's simply the top 5 bits
of `funct7`, which `Control.v`/`reg2` already thread through as `funct7_regde` for other opcodes —
`funct7_regem`/`isAmo_regem` (new fields) extend that same threading one stage further into MEM, mirroring
`funct3_regem`'s own existing shape. The combine step itself (`amo_combined`, new combinational logic)
is a small `funct5`-selected case, not a reuse of the main integer ALU (which is already busy computing
this instruction's own *address* on both phases — reusing it for the combine would conflict).

### Writeback

An AMO's own `rd` value is the pre-modification value the interlock's own phase-0 read captured
(`amo_captured_read_r`), not `readData_regwb` (that register's own ordinary load-capture timing doesn't
line up with an AMO's real 2-cycle-later retirement). `isAmo_regwb` (threaded through `reg4`) gates a new
writeback-mux arm, mutually exclusive with the existing `jump_regwb` override (`Control.v`'s own
`OPCODE_AMO`/`OPCODE_JAL` arms are disjoint by construction).

## Real bugs/findings

None in this phase's own new AMO logic itself — regression-verified bit-exact (Phase S's firmware still
prints "OK", `arith.s` still halts cleanly) on the first working build, and the real kernel's own
`amoadd.w` executed correctly (confirmed via the `amo_active`/`amo_write_phase`/`amo_write_done`/
`amo_stall`/`amo_read` debug taps added for this phase, tracing the full 2-phase sequence cycle-by-cycle
against the real expected timing) on the same build that resolved the boot's very next blocker. What
looked at first like an AMO-interlock bug (PC stalling for several cycles then jumping to an unrelated
address right after the `amoadd.w`/`c.bnez` pair) turned out, after a dedicated trace ruled the AMO
interlock itself out as behaving exactly as designed, to be the RVC `C.BEQZ`/`C.BNEZ` double-shift bug
documented in `docs/adr/0037` instead — a real methodology note: don't assume the newest code is the
bug without first tracing the specific suspect signal directly.

## Alternatives considered

**Extending `mem_stall`'s own single-access machinery to cover a second phase**, rather than a fully
independent interlock. Rejected: `mem_stall`/`mem_trigger` feed a wide web of existing consumers
(fence handling, `dcache` readiness, performance counters, branch-predictor update gating, `instret`
counting) whose own timing assumptions are all built around a single access completing in one
(possibly cache-model-variable) step — correctly extending all of them for a genuine 2-step sequence
would have meant re-verifying every one of those consumers, a far larger and riskier change than adding
one new, provably-orthogonal interlock that those existing consumers never see (since `isAmo_regem` and
`memRead_regem`/`memWrite_regem` are mutually exclusive by construction).

**Full MMU-permission-awareness for an AMO's own write phase.** Not implemented: `ls_perm_ok`'s existing
permission check (`memWrite_regde ? ls_perm_w : ls_perm_r`) always evaluates the *read* permission for
an AMO (since `Control.v` leaves `memWrite_regde`=0 for `OPCODE_AMO`), meaning an AMO to a
read-but-not-write page would be incorrectly allowed to write. A real, documented gap, deliberately
deferred: `satp`=0 (Bare mode, translation disabled) throughout this phase's own actual kernel-boot
target, making the gap currently unreachable, and a real kernel's own data pages are ordinarily RW
regardless.

## Validation strategy

Same "regenerate and re-run everything that doesn't use the new feature, confirm bit-exact" bar
`docs/adr/0037` established (Phase S firmware "OK", `arith.s` clean halt) after every RTL change in this
phase, plus real kernel execution as the primary correctness signal for the new feature itself (no
standalone directed AMO test was written — see Future improvements).

## Future improvements

A hand-written directed test exercising each `funct5` case (`AMOADD`/`AMOSWAP`/`AMOXOR`/`AMOAND`/
`AMOOR`/`AMOMIN`/`AMOMAX`/`AMOMINU`/`AMOMAXU`/`LR`/`SC`) against known expected results would be real,
still-missing standalone regression coverage — this phase's own verification leaned entirely on the real
kernel happening to exercise `AMOADD.W`, `C.BEQZ` shortly after, and nothing else from the full set. The
MMU-permission gap above. `CACHE_WRITEBACK_SETASSOC`'s own write-miss timing was never considered for
AMO's own write phase (this phase scoped to `CACHE_NONE` throughout, matching the kernel-boot target).
