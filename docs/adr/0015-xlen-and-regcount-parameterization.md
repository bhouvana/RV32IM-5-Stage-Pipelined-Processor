# ADR 0015: XLEN/NUM_REGS parameterization (Phase 6 entry point)

## Problem

`docs/ROADMAP.md` Phase 6 (research platform / pluggable subsystems) names
its concrete entry point: "the architectural register file and pipeline
register widths are still fixed literals." `docs/adr/0012` parameterized
memory *sizes* (`SIZE_BYTES`) but explicitly left this out of scope. Every
`design/*.v` file still spells the data width as a literal `32`/`[31:0]`
and the register count as `32`/`[4:0]`, scattered across ~15 files.

## Design

### What actually gets parameterized, and what deliberately doesn't

Two new parameters, threaded from `PIPELINED` down through every submodule
that needs them:

- **`XLEN`** (default 32): applies to every genuinely word-sized value --
  register file entries, ALU operands/results, PC, immediates, memory
  read/write data, CSR contents. Also applied to the instruction word
  itself (`inst`/`inst_regfd`/`inst_regde`) and `ImmGen.v`'s `inst` input,
  matching a simplification `ImmGen.v` already made before this ADR (it's
  had a `Width` parameter since `docs/adr/0012`, applied to both its
  instruction input and immediate output identically). This is not fully
  rigorous -- RV32I's instruction word is 32 bits by the "I" extension's own
  definition, independent of XLEN (a hypothetical RV64I core keeps the same
  32-bit instruction encoding, just a wider XLEN) -- but introducing a
  *second* width parameter to separate them would be new complexity this
  codebase doesn't currently need, since XLEN only ever equals 32 here
  anyway. Documented as a known simplification, not silently glossed over.
- **`NUM_REGS`** (default 32): the architectural register file's depth,
  and (via a derived `REG_ADDR_WIDTH = $clog2(NUM_REGS)`) every register-
  address field's width -- `Register.v`'s ports, `reg2`/`reg3`/`reg4`'s
  `readReg*`/`write_to_Reg*` fields, `Forward.v`, `Hazard.v`.
- **Deliberately left as literals**: instruction-encoding bit *positions*
  and field widths -- `opcode[6:0]`, `funct3[2:0]`, `funct7[6:0]`, the
  fixed `inst[19:15]`/`[24:20]`/`[11:7]` rs1/rs2/rd slice positions,
  `ALUCtl[4:0]`/`ALUOp[1:0]` (internal control encodings, not data),
  `csr_addr[11:0]` (the CSR address space width is set by the privileged
  spec, not XLEN), and `DataMemoryBRAM.v`'s byte/halfword/word access-width
  logic (`lb`/`lh`/`lw`/`sb`/`sh`/`sw` are a fixed set in RV32I's own
  encoding, independent of XLEN -- RV64I adds a separate `ld`/`sd` rather
  than widening these). All of these are ISA-*behavior* axes, the same
  category `Control.v`/`ALUCtrl.v`'s opcode/funct3/funct7 decoding already
  is -- not a width/depth knob at all.

### Named, not truly variable -- and why that's still worth doing

Neither parameter can actually be changed away from 32 today without
breaking RV32I compliance: the ISA's own encoding hardwires a 32-bit
instruction word and 5-bit rs1/rs2/rd fields regardless of what `XLEN`
or `NUM_REGS` say. This ADR does not change that -- it replaces scattered
magic-number literals with named parameters that are *coincidentally* only
ever valid at one value, the same relationship `docs/adr/0012`'s
`SIZE_BYTES` has to real usable configurability (memory size genuinely is
an independent, safely-variable axis; `XLEN`/`NUM_REGS` are not, for this
ISA). The value is: a single source of truth (matching CQ-1's
`riscv_defs.vh` spirit) instead of ~15 files independently spelling `32`,
self-documenting intent at every use site, and groundwork for a possible
future RV64I variant (same instruction encoding, wider `XLEN`) without
overclaiming that variant exists today.

### Mechanical changes worth flagging specifically

- **`Register.v`'s `// Do not modify this file!` header was removed.**
  Confirmed with the user before touching it (this file is the last piece
  of the original student-project template `handoff.md` describes;
  everything else in the repository has already been substantially
  rewritten over the course of this project).
- **A real, if minor, latent bug fixed alongside the refactor**: `x2`
  (RISC-V's `sp` by calling convention)'s reset value was a hardcoded
  `32'd128` -- historically matching the data memory's size, but never
  actually *wired* to it, so overriding `PIPELINED`'s existing
  `MEM_SIZE_BYTES` parameter (`docs/adr/0012`) would silently leave `sp`
  pointing at the old default instead of the real configured memory size.
  `Register.v` gained a `SP_INIT` parameter, and `riscvpipeline.v` now
  wires it to `MEM_SIZE_BYTES` directly, so the two can no longer drift
  apart. Verified directly (not just reasoned about): instantiating
  `PIPELINED #(.MEM_SIZE_BYTES(256))` and reading `m_Register.regs[2]`
  after reset now shows `256`, not the old hardcoded `128`.
- **`Register.v`'s reset used a real `for` loop instead of 32 unrolled
  lines** -- the same style `DataMemory.v`/`DataMemoryBRAM.v`/
  `InstructionMemory.v` already use for their own reset loops, and now
  actually scales with `NUM_REGS` instead of needing hand-editing.
- **`Divider.v`, `ALU.v`'s multiply/CTZ**: replaced hardcoded 32-bit
  sign-extension/two's-complement patterns (`{{32{x[31]}}, x}`,
  `~x + 32'b1`, iterate-31-times loops) with `XLEN`-relative forms
  (`{{XLEN{x[XLEN-1]}}, x}`, unary `-x`, iterate-`XLEN-1`-times). The
  shift-amount width for `sll`/`srl`/`sra` also became `$clog2(XLEN)` bits
  instead of the literal `[4:0]`.

## Alternatives considered

- **Two separate parameters for instruction width and XLEN.** Rejected for
  now: more rigorous, but adds a parameter axis with no current consumer
  (nothing in this codebase generates or verifies anything but 32-bit
  instructions), and would mean diverging from `ImmGen.v`'s existing
  precedent instead of extending it consistently. Worth revisiting if an
  actual RV64I variant is ever attempted.
- **Also parameterizing `DataMemoryBRAM.v`'s byte/halfword/word access
  logic.** Rejected: that's RV32I's `lb`/`lh`/`lw` instruction *encoding*,
  not a width/depth axis -- generalizing it would mean designing for a
  hypothetical `ld`/`sd` (RV64I) that doesn't exist in this ISA subset,
  out of scope for a parameterization pass.
- **Leaving `Register.v` untouched, scoping Phase 6 down to just the
  pipeline registers.** Considered, but the user confirmed treating the
  file's "do not modify" comment as stale template boilerplate rather than
  a live constraint, and the register file is the roadmap's explicitly
  named entry point for this phase -- skipping it would leave the actual
  target undone.

## Validation strategy

- Full directed suite: 25/25 tests, 136 checks, unchanged -- confirms the
  refactor is bit-exact at the default `XLEN=32`/`NUM_REGS=32`.
- Both standalone unit tests (`tb_divider_unit.v`, `tb_data_memory_bram.v`)
  instantiate `Divider`/`DataMemoryBRAM` *without* overriding the new
  parameters, relying entirely on defaults -- both still pass, confirming
  the defaults are correct.
- Constrained-random cross-check: 200/200 at default program length plus
  150/150 at 24 instructions/program across a disjoint seed range, all
  against the independent ISS (itself unchanged -- it checks architectural
  state, not RTL internals).
- `iverilog -Wall -g2005 -I design -tnull design/*.v`: clean, zero
  warnings.
- `sim/tools/coverage_report.py`: run clean after the change, same
  coverage shape as `docs/adr/0014` left it (no regression in what's
  exercised).
- Direct verification of the `SP_INIT`/`MEM_SIZE_BYTES` bug fix (see
  above), not just the refactor -- confirmed the *behavior change*, not
  only that the default case still matches.

## Future improvements

- The rest of Phase 6 ("pluggable subsystems," comparing hazard strategies
  or pipeline depths) is *not* delivered by this ADR -- this is the
  prerequisite cleanup the roadmap named, not the swappable-
  Forward.v/Hazard.v or variable-stage-count architecture Phase 6's full
  vision describes. That remains real, substantially larger future work.
- If a genuine RV64I variant is ever attempted, revisit the "instruction
  width == XLEN" simplification (see Alternatives) -- it would need to
  become two independent parameters at that point.
