# ADR 0011: CSR registers and M-mode synchronous exceptions

## Problem

`docs/ROADMAP.md` (Phase 5) named "CSR + machine mode + exceptions/
interrupts" as the last major ISA-completeness gap: this core had no way to
detect or react to an unimplemented/malformed instruction (it would silently
execute *something* -- whatever ALUCtrl's default case happened to select --
rather than trap), no `ecall`/`ebreak` (the standard mechanisms a program
uses to request a service or a debugger breakpoint), and no CSR instructions
at all, which real firmware/OS code depends on even outside interrupt
handling (e.g. reading `mhartid`-style identification, or -- as this design
uses `mscratch`/`mepc`/`mtvec` for -- implementing a trap handler in
software).

## Scope

Machine-mode only: no S-mode/U-mode, no PMP, no real interrupts (this
design has no interrupt lines -- no timer, no external IRQ pins). Three
synchronous exception sources (illegal instruction, `ecall`, `ebreak`) and
five CSRs (`mstatus`, `mtvec`, `mscratch`, `mepc`, `mcause`) -- enough to
write and test a real trap handler in software (save/restore, inspect
`mcause`, adjust `mepc`, return with `mret`), not a full privileged-spec
implementation.

## Design

### New module: `CSR.v`

A small register file, deliberately separate from `Register.v` (the
architectural `x0`-`x31` file) rather than folded into it -- CSRs have
per-address side effects (`mstatus`'s trap-entry/return bit shuffling,
read-modify-write semantics) that don't fit the uniform "one write port,
plain overwrite" shape `Register.v` already has, and mixing the two would
have meant special-casing `Register.v` for a handful of addresses instead of
keeping it the simple, `` `default_nettype none``-clean module the header
comment says not to touch.

`csr_op` intentionally reuses `funct3[1:0]` directly as its encoding
(`01`=write, `10`=set, `11`=clear) instead of a separate remapped opcode --
those two bits already *are* RISC-V's write/set/clear distinction for every
`csrrw`/`csrrs`/`csrrc` (and `+i`) variant, so remapping them at the call
site would have been a translation layer with no informational value.

`mstatus` only ever stores two real bits: `MIE` (bit 3, "are traps currently
enabled") and `MPIE` (bit 7, "what MIE was before the trap being handled
right now"). Every other `mstatus` bit real RISC-V defines (privilege-mode
fields, `MPRV`, floating-point/vector state, ...) doesn't apply to an M-mode-
only, no-FP, no-interrupt core, so `csr_write_en`'s `mstatus` case masks the
write down to just those two bits rather than storing (and later reading
back) 32 bits of always-zero filler that would only be misleading in a
waveform.

### Decoding: `Control.v` and `ImmGen.v`

`OPCODE_SYSTEM` (`1110011`) covers four unrelated things distinguished by
`funct3`/`inst[31:20]`: real CSR ops (`funct3 != 0`), and `ecall`/`ebreak`/
`mret` (`funct3 == 0`, distinguished from each other by the `funct12` field
sitting where a CSR address would otherwise be). `Control.v` decodes both
layers: `funct3 == CSR_F3_NONE` selects among `ecall`/`ebreak`/`mret` (or
sets `illegalOpcode` for the fourth, reserved case), anything else sets
`isCsr` and `regWrite` (a real CSR instruction's `rd` always receives the
CSR's *old* value, even for `csrrw` with `rd = x0` -- there is no encoding-
level way to know in advance the result will be discarded).

`illegalOpcode` also now covers the *outer* `default:` case -- any opcode
this core doesn't implement at all. Before this ADR that case just zeroed
every control signal (a silent, undefined no-op); now it's a real trap. This
turned out to be more consequential than it sounds -- see "A real bug found
during verification" below.

`ImmGen.v` gained a case for `OPCODE_SYSTEM`: `inst[31:20]` zero-extended
into `imm`, doing double duty as the CSR address for real `csrrX` ops and as
`funct12` for `ecall`/`ebreak`/`mret` (the latter never reads it back, so
the shared path costs nothing).

### Exception resolution and the trap-redirect path

Both exception sources resolve in EX, the same stage taken/not-taken
branches, `jal`, and `jalr` already resolve in:

- `illegalOpcode_regde` -- known at decode time (`Control.v`).
- `ALUCtl == ALUCTL_ILLEGAL` -- only known now, in EX, since it requires
  `ALUCtrl` to have already decoded a *recognized* opcode's `funct7`/
  `funct3` and found no valid operation (e.g. a reserved R-type funct7).

`isEcall_regde`/`isEbreak_regde` complete the `exception_taken` OR, and
`mcause` is selected by priority-encoding the same four conditions into one
of `MCAUSE_ILLEGAL_INSTRUCTION` (2, shared by both illegal-instruction
sources), `MCAUSE_BREAKPOINT` (3), or `MCAUSE_ECALL_FROM_M` (11).

The existing `jump_regde`-driven redirect/squash path (`docs/adr/0001`)
generalizes directly: `unconditional_redirect = jump_regde |
exception_taken | isMret_regde` feeds the same `branch_taken` signal that
already squashes the two younger in-flight instructions on any taken
control transfer, and `redirect_target` muxes between the ordinary branch/
jump target, `mtvec` (trap entry), and `mepc` (trap return) by the same
priority. No new squash logic was needed -- exceptions and `mret` are just
two more reasons an unconditional redirect can happen, not a structurally
different kind of control transfer.

### `ex_result` and forwarding

`ex_result = isCsr_regde ? csr_old_val : (isDivRem ? div_result : ALUOut)`
extends the pattern `docs/adr/0009` established for div/rem: whatever EX
"produces" this cycle for a non-ALU instruction overrides `ALUOut` on the
way into `reg3`, and (per that ADR's reasoning, reconfirmed here rather than
assumed) needs no separate EX/MEM-forwarding correction -- `Forward.v`'s
existing `exmem_fwd_val` path reads `reg3`'s output, which already holds the
correct value by the time anything downstream could observe it.

## A real bug found during verification: `funct3_regde`'s declared range

Every directed CSR/exception test failed on first run, but not identically:
`csr_ops.s`'s very *first* CSR instruction (`csrrw x2, mscratch, x1`) passed,
every one after it corrupted `mscratch` with X (unknown) bits; the trap
tests never reached their handlers at all and settled into what looked like
an infinite restart loop.

Root cause: `riscvpipeline.v` already declared a wire for the registered
`funct3` field as `wire [14:12] funct3_regde;` -- a preexisting declaration
that happened to work for every prior use, because every prior use
(`ALUCtrl`'s `.funct3_c(funct3_regde)` port connection, the coverage
counters' `cov_branch_taken[funct3_regde]` array index) passes or indexes
the *whole* 3-bit vector, and Verilog connects/uses a vector by position and
value, not by its declared index labels. `[14:12]` and `[2:0]` are both
"some 3-bit vector" as far as those call sites are concerned.

This ADR's CSR wiring was the first code anywhere in the design to bit-
select *into* `funct3_regde` -- `csr_wdata = funct3_regde[2] ? ... : ...`
and `.csr_op(funct3_regde[1:0])` -- and indices `2`, `1`, and `0` all fall
outside a vector whose valid index range is `[12:14]`. Verilog's answer to
an out-of-range bit-select is not an error, and not index-12-relative
wraparound: it's `x` (unknown), silently. `csr_op` therefore evaluated to
`2'bxx` on every single CSR instruction; `new_val`'s ternary on an unknown
condition blends the two branches bit-by-bit (agreeing bits pass through,
disagreeing bits go X), which is exactly the "only the low nibble is X, and
only sometimes" pattern the failing checks showed -- and explains why the
very first CSR write looked fine: `rd` receives the CSR's *old* value
(clean, pre-corruption), so the corruption only became visible on the next
instruction that read the now-poisoned CSR state.

The trap tests' apparent "infinite restart" was a second-order consequence
of the same root cause: `mtvec_val` never latched a good value either (the
`csrrw x0, mtvec, x5` setup instruction was itself corrupted the same way),
so the eventual real exception redirected `pc` to whatever `mtvec` actually
held -- effectively address 0 -- restarting the whole program from the top
on a loop, rather than reaching the intended handler.

Fixed by correcting the declaration to `wire [2:0] funct3_regde;`. No other
signal in the file used a source-bit-position-shaped range (`[14:12]`-style)
the way this one accidentally did -- worth a second pass (not done as part
of this ADR) to grep for the same pattern elsewhere, since it is exactly the
kind of bug that stays invisible until new code finally bit-selects into a
signal that had only ever been passed around whole.

## Alternatives considered

- **Fold CSRs into `Register.v`** (e.g. a second write port keyed by a
  "this is a CSR" flag). Rejected: `Register.v`'s header says not to modify
  it, and CSR read-modify-write/trap-entry semantics don't fit its existing
  "one write port, plain overwrite" shape without complicating the one file
  this project has deliberately kept simple and stable since `docs/adr/
  0002`.
- **Interrupts alongside exceptions**, since real `mstatus`/`mcause`
  machinery is now in place. Rejected for this pass: this design has no
  interrupt source (no timer, no external IRQ line) to drive one with, so
  the plumbing would be untestable dead code. `MIE`/`MPIE` are implemented
  now because `mret`'s save/restore behavior needs *something* real to
  save/restore, not because an interrupt will use them soon.
- **`mepc`-adjustment-on-trap** (auto-incrementing `mepc` past `ecall` at
  trap time, so software wouldn't need to do it before `mret`). Rejected:
  not how real RISC-V hardware behaves (`mepc` is defined as the trapping
  instruction's own address; the +4 adjustment for a synchronous trap like
  `ecall` is conventionally the handler's job), and diverging here would
  make this core's trap semantics actively misleading to anyone using it to
  learn real RISC-V trap handling.

## Validation strategy

- `sim/programs/csr_ops.s` / `tb_csr_ops.v`: all six `csrrw`/`csrrs`/
  `csrrc`(`+i`) forms against `mscratch`, chained back-to-back (no
  intervening ALU ops) specifically to exercise consecutive-cycle CSR
  read-after-write -- this is the sequence that caught the `funct3_regde`
  bug above.
- `sim/programs/illegal_instr.s` / `tb_illegal_instr.v`: a raw unimplemented
  opcode (via a new `word` directive in `sim/tools/asm.py`, for encodings no
  mnemonic exists for) traps with `mcause=2`, `mepc` = the trapping
  instruction's own address, and control reaches a handler installed via
  `mtvec` -- with an explicit check that the two instructions immediately
  after the trap are never executed (the redirect must squash them).
- `sim/programs/ecall_trap.s`, `ebreak_trap.s`: identical shape, `mcause=11`
  and `mcause=3` respectively.
- `sim/programs/mret_return.s` / `tb_mret_return.v`: the full round trip --
  set `MIE`, trap via `ecall`, handler reads `mepc`, advances it past the
  `ecall` (standard practice), writes it back, and `mret`s. Checks that
  execution actually resumes at the adjusted address (not a re-trap loop)
  and that `mstatus`'s `MIE`/`MPIE` stack round-trips correctly.
- `sim/tools/asm.py` and `sim/tools/iss.py` both gained CSR/`ecall`/
  `ebreak`/`mret` support (encoding and, respectively, an independent
  execution model) so this instruction class is covered by the constrained-
  random cross-check (`docs/adr/0010`) infrastructure too, not just the five
  directed tests above -- though `sim/tools/random_gen.py` does not yet
  *generate* CSR/exception instructions (see Future improvements).
- Full suite: 21/21 directed tests passing (87 checks), 60/60 random
  programs cross-checked against the ISS with zero mismatches, zero
  regressions in the pre-existing 16 tests.

## Future improvements

- `sim/tools/random_gen.py` doesn't generate CSR ops, `ecall`, `ebreak`, or
  `mret` -- extending it would need either a reserved "safe" CSR (like the
  existing reserved base-pointer register, `x31`) to avoid the generator
  accidentally reconfiguring `mtvec` mid-program and jumping the model off
  into the weeds, or teaching the ISS to fully emulate trap redirection
  under random control flow. Left out of this pass as a scope decision, not
  an oversight.
- No interrupt support (see Alternatives). If this core ever gains a timer
  or external IRQ line, `mstatus.MIE`/`mie`/`mip` are the natural next CSRs
  to add, and the trap-entry path already generalizes (interrupts are
  "another exception_taken source" in the same OR this ADR already
  restructured for ecall/ebreak/illegal).
- `funct3_regde`'s declaration bug (see above) suggests auditing the rest of
  `riscvpipeline.v` for other source-bit-position-shaped wire ranges that
  happen to work today only because nothing yet bit-selects into them.
