# ADR 0039: AMO/Load-Use Hazard Fix, Closing the Real Kernel-Boot sp/tp Park (Generation 3, Phase W)

## Problem

Generation 3 closed (`docs/adr/0036`-`0038`) with the real kernel parking forever in what looked, from
PC/mcause alone, like a real `ld`/`beqz` polling loop waiting on `sp`/`tp` at kernel PC `0x200152` --
documented as "a real gap in what this project's own SBI/DTB provides... needing Linux kernel source
archaeology, not more hardware-level debugging." This phase did that archaeology and found the real root
cause is RTL, not environment.

## Root cause investigation

Fetched the actual upstream kernel source (`arch/riscv/kernel/head.S`, matching the exact `5.5.0-rc7`
banner string embedded in this project's own `Image` binary) and confirmed the parked loop is
`.Lwait_for_cpu_up` -- exclusively the **secondary**-hart path (`REG_L sp,(a1)` / `REG_L tp,(a2)` /
`beqz sp` / `beqz tp`, looping until the *primary* hart publishes both). This core is genuinely
single-hart and enters as hart 0 (`a0=0`, confirmed in `sim/firmware/boot.S`), so it should never take
that path -- the primary path sets `sp`/`tp` directly via `la`, no memory read, no loop at all.

Added five new debug taps (`debug_x2`/`x4`/`x11`/`x12`/`x13`, same "unconnected changes nothing" shape as
the existing `debug_x10`/`debug_x1`) and a `+pc-trace-min=` gate to the Verilator harness (`sim_main.cpp`)
to watch the hart-lottery region without wading through the firmware's own boot trace. Rebuilt `vboot.exe`
and re-ran a bounded trace (`+max-cycles=3000000 +pc-trace-every=1 +pc-trace-min=0x200000`), then decoded
the captured `debug_inst_final` values with `sim/tools/disasm.py` (reused as-is; its own `imm_sum` tap
already gives branch targets for free, no new decoder needed).

The trace is a bit-exact match to the real kernel source, instruction for instruction: `amoadd.w
a3,a2,(a3)` (the hart-lottery pick) at `0x200066`, `bne x13,x0,+192` (`bnez a3,.Lsecondary_start`) at
`0x20006a` -- **taken** -- landing at `0x20012a` (`csrrw stvec,a3` / `slli a3,a0,3` / two `la`s / two
`add`s / `ld sp,(a1)` / `ld tp,(a2)` / `beq sp,x0,-8` / `beq tp,x0,-12`), an exact instruction-for-
instruction match to `.Lsecondary_start`'s real body. `x13` never changed from its pre-instruction value
(the address of `hart_lottery`, always nonzero) across the entire AMO's multi-cycle window -- the
`amoadd.w`'s own captured-old-value result (`amo_captured_read_r`, itself correctly 0 per the debug tap)
never reached `a3` in time for the very next instruction to see it.

**Root cause**: `Hazard.v`'s load-use hazard detector -- the *early*, decode-stage mechanism that stalls
a dependent instruction *before* it advances into EX, distinct from the *later* `amo_stall`/`reg2_hold`
interlock that only engages once an AMO reaches "regem" (EX) -- gates its stall purely on
`la_memRead(memRead_regde)`. `Control.v`'s own `OPCODE_AMO` arm (docs/adr/0038) deliberately leaves
`memRead`/`memWrite` at 0 (the MEM-stage interlock drives the real bus signals instead, sidestepping
`mem_stall`'s own definition entirely, by design) -- but that same 0 also blinds `Hazard.v`'s *separate*,
earlier check, which has no other way to know an AMO is even in flight. An immediately-following
instruction reading the AMO's own `rd` advances into EX one cycle before `amo_stall` can catch it,
capturing the stale pre-AMO register-file value. `HazardNoForward.v` (the alternate `HAZARD_STRATEGY=1`)
was never affected -- it stalls on any `regWrite_regde` match, not just loads, so it already covered AMO
by construction; the bug is specific to the default strategy's own load-only fast path.

This is exactly the aliased case the real kernel exercises: `amoadd.w a3,a2,(a3)` has `rd==rs1`, and the
very next instruction depends on `rd` -- the tightest possible gap, and the one this project's own
directed-test corpus never had a case for (docs/adr/0038's own flagged gap: no standalone AMO regression
test existed at all before this phase).

## Fix

One-line, root-cause, single shared caller: `riscvpipeline.v`'s `Hazard` instantiation now wires
`.la_memRead(memRead_regde | isAmo_regde)` instead of `memRead_regde` alone -- treating an AMO in
"regde" as a load-use hazard source exactly like a real load, reusing the identical, already-verified
stall/bubble mechanism rather than adding a new one. `isAmo_regde` was already threaded to this exact
pipeline stage (docs/adr/0038); no new wiring needed beyond the OR.

## Real bugs/findings

1. **The actual bug above** -- a real, load-bearing hazard-detection gap that would misfire on
   essentially any AMO with an immediately-dependent consumer, not just this one kernel's own
   hart-lottery idiom. Confirmed fixed by re-running the identical bounded Verilator trace: the `bnez`
   is no longer taken, the primary path's own `clear_bss`/`setup_vm`/`relocate` sequence executes, and
   the kernel now runs ~208,000 further cycles (well past the old park point) before hitting a new,
   different, later fault (Sv39 instruction page fault, `mcause=0xc`, during the kernel's own MMU-enable
   `relocate` sequence) -- a real, later, separate milestone, not chased further in this phase (see Future
   improvements).
2. **A separate, pre-existing infrastructure bug found while trying to run the regression suite at all**:
   73 of 90 `sim/tb/tb_*.v` testbenches (every one written or last touched before Phase U added
   `design/CompressedExpander.v`) never gained the corresponding `` `include "CompressedExpander.v" ``
   line every other design module already gets -- `riscvpipeline.v` instantiates it unconditionally, so
   any testbench compiled as a standalone `` `include ``-based unit (this project's own established
   convention; `riscvpipeline.v` itself only self-includes `riscv_defs.vh`) failed elaboration outright,
   "Unknown module type: CompressedExpander". Confirmed pre-existing (reproduces identically against the
   unmodified `HEAD` `riscvpipeline.v`) -- not something this phase's own RTL edit caused. Fixed
   mechanically across all 73 files (matching the existing per-testbench include-list convention exactly,
   not a new shared-header refactor).
3. **A second, separate environment-only red herring**: this machine has *two* Icarus Verilog installs --
   OSS CAD Suite's bundled `14.0 (devel)` snapshot (used for Verilator/co-tooling) and a standalone
   `/c/iverilog` `12.0` install (`sim/run_tests.sh`'s own usage text already names this exact path). The
   `14.0` snapshot fails real elaboration (not just the `-tnull` syntax check every ADR's "zero-warning
   compile" bar actually exercises) on numerous *pre-existing* `generate`-block port connections
   throughout `riscvpipeline.v` that reference a wire declared later in the file -- "Check for declaration
   after use" -- reproduces identically on the unmodified `HEAD` tree and is unaffected by `-g2005` vs
   `-g2012`. The `12.0` install elaborates and runs the full suite cleanly. Not a regression, not fixed
   here (out of scope, would need reordering wire declarations project-wide) -- just resolved by using the
   right toolchain, which is what `sim/run_tests.sh`'s own docstring already pointed at.

## Validation strategy

`iverilog -Wall -g2005 -I design -tnull design/*.v` (via `/c/iverilog/bin`): zero-warning. Full
`sim/run_tests.sh` (via `/c/iverilog/bin`): **88/90** -- the same two failures as the unmodified `HEAD`
tree (confirmed by re-running against `git show HEAD:design/riscvpipeline.v` directly): `tb_arith`'s own
documented `ctz`-capped-at-31 off-by-one (the test's own comment already calls this out, not a real bug),
and `tb_icache_unit`'s stale byte-order-flip expected values (Phase U's own `InstructionMemory.v`
LSB-first fix, `docs/adr/0037`, was never back-propagated to this one standalone unit test's own hardcoded
expected words -- a real, separate, pre-existing gap, flagged here, not fixed -- out of scope for this
phase). Zero new failures, zero regressions. Primary validation for the actual fix is the real kernel
re-run itself (see Real bugs/findings #1) -- the most direct evidence available for a bug that only a real
multi-million-cycle kernel boot happened to trigger.

## Alternatives considered

**A synthetic directed test** (`sim/programs/*.s` + `tb_*.v`) reproducing the aliased `amoadd.w
rd,rs2,(rd)` / dependent-branch pattern directly, independent of the real kernel. Not built this phase:
`sim/tools/asm.py` has no AMO mnemonic support at all (Phase V's own kernel-boot verification never
needed it, ADR 0038's own "Future improvements" already flags this as missing, still-needed standalone
coverage) -- adding real AMO-family assembler support (a new operand-order, a new `OPCODE_AMO` funct5
table) is itself a real, separate scope item, not a one-line addition, and doing it as a drive-by here
would be exactly the kind of unrequested scope creep this project's own phase discipline avoids. The real
kernel re-run is strong, authentic evidence for this specific fix; the standalone-test gap remains real
and open, now doubly-motivated (ADR 0038 flagged it for coverage completeness, this phase flags it again
because coverage gap is what let this bug ship in the first place).

## Future improvements

The new, later Sv39 instruction-page-fault blocker (`mcause=0xc` during the kernel's own `relocate`
sequence) is the real next frontier -- a different, deeper investigation (what page tables `setup_vm()`
built vs. what this project's own minimal DTB/memory-size describes) than anything this phase covers,
genuinely its own future phase. `sim/tools/asm.py` AMO mnemonic support, and the standalone directed AMO
test it would unlock, remains real, flagged, unclosed backlog (now flagged three times: ADR 0038, this
ADR, and by construction until someone builds it). `tb_icache_unit`'s stale expected-value bug (found
while validating this phase, unrelated to it) is real and unfixed.
