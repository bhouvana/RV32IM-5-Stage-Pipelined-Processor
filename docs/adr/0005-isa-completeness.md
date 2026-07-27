# ADR 0005: RV32I completeness (jalr, lui, auipc, bltu/bgeu, byte/halfword memory)

## Problem

`docs/ARCHITECTURE.md` §11 catalogued the gap between "README claims all
R/I/L/S/B types" and reality: `jalr`, `lui`, `auipc` entirely absent;
`bltu`/`bgeu` absent (the branch funct3 space was fully claimed by
`beq/bne/blt/bge` plus the custom `ble/bgt`); loads/stores only supported
word width. `docs/ROADMAP.md` sequenced closing this gap (Phase 5.1) ahead
of any RV32M/CSR/privilege work, since those would only add more opcodes on
top of an already-incomplete base.

## Background / design reuse

Each addition was scoped against what `jal`'s existing plumbing
(`docs/adr/0001`) and `Forward.v`'s existing EX/MEM/MEM-WB paths already
provide, to keep each piece as small as it could genuinely be:

- **`jalr`**: turned out to need almost nothing new. It sets `jump=1` (a
  new `jalr` bit distinguishes it from `jal` only for target-address
  computation), so it automatically inherits `jal`'s squash logic, link-value
  writeback override, and EX/MEM forwarding correction with zero additional
  code in those paths. The only genuinely new wiring is the target adder:
  `jal`'s target is `PC + shifted_imm` (via `ShiftLeftOne` + `Adder_2`);
  `jalr`'s is `rs1 + imm` (unshifted) with bit0 cleared. Implemented as a
  2-way mux on `Adder_2`'s own inputs (`target_base`/`target_off` in
  `riscvpipeline.v`) rather than a second adder, plus a bit0 mask on the
  final `imm_sum` (harmless no-op for branch/jal, whose sums are already
  even by construction).
- **`lui`/`auipc`**: no new writeback path at all. Both reuse the ALU's
  existing `ADD` op by overriding its *A* operand (0 for `lui`, PC for
  `auipc`) via a new `Mux4to1` ahead of the ALU -- `Forward.v`'s existing
  EX/MEM/MEM-WB forwarding of `ALUOut_regem`/`writeData_regwb` therefore
  needed no changes, unlike `jal`/`jalr` which required the
  `exmem_fwd_val` correction (`docs/adr/0001`) specifically because their
  result *wasn't* the raw ALU output.
- **`bltu`/`bgeu`**: RV32I's branch funct3 space is 3 bits (8 values); this
  core's existing custom encoding used only 6 (`beq/bne/blt/bge/ble/bgt`),
  leaving `funct3=110/111` free -- assigned to `bltu`/`bgeu` with no
  encoding conflict. Discovering this also surfaced a real bug
  (`docs/adr/0004`): `slt`/`blt`/`bge`/`ble`/`bgt` were comparing as
  unsigned (missing `$signed()` casts), the same class of bug as the `sra`
  fix from Phase 3's verification pass.
- **Byte/halfword loads/stores**: `DataMemory.v` gained a `funct3` input
  (threaded through a new `reg3` field, `funct3_regem` -- `reg1`/`reg2`
  already carried `funct3` this far for `ALUCtrl`, it just didn't continue
  past EX into MEM before now) and case-based byte/halfword read
  (sign/zero-extending per `funct3[2]`) and write (masking to the owned
  bytes per `funct3[1:0]`) logic. `Control.v` needed no changes: `lb/lh/lw/
  lbu/lhu` all share opcode `0000011`, `sb/sh/sw` all share `0100011` --
  funct3 alone distinguishes width, exactly like the real RV32I encoding.

## Alternatives considered

- **A dedicated jalr target adder** instead of muxing `Adder_2`'s inputs.
  Rejected: `Adder_2` is idle whenever a jalr is in EX (nothing else uses it
  that cycle), so a second adder would be pure duplication for no timing or
  clarity benefit.
- **A separate writeback-override mux for lui/auipc**, mirroring jal's
  `pc_plus4` path. Rejected once it became clear the ALU-A-operand-mux
  approach reuses the *entire* existing ALU result path (including
  forwarding) for free -- strictly less new logic for the same result.
- **Word-granularity DataMemory kept as-is, with byte/halfword extraction
  done in a new stage after MEM.** Rejected: sign-extension needs to know
  which byte(s) are relevant before the value leaves memory, and doing the
  masking inside `DataMemory` keeps the "one memory, one owner of the
  addressing logic" property intact rather than splitting address-to-byte
  mapping across two modules.

## Expected impact

RV32I base ISA is now complete apart from `fence`/`ecall`/`ebreak` and CSR
(explicitly out of scope until Phase 5's CSR/privilege work, tracked
separately in `docs/ROADMAP.md`). This is also the first point a real
compiled-C toolchain target becomes plausible: `lui`+`addi` / `auipc`+`jalr`
are the standard sequences compilers emit for far calls and large
constants, and were previously entirely unavailable.

## Validation strategy

Four new directed tests (16 checks): `lui_auipc.s`, `bltu_bgeu.s` (extended
to also cover the ADR 0004 signed-comparison fix), `jalr_test.s` (link
value, squash, and the EX/MEM forwarding correction specifically), and
`mem_bytes.s` (sign vs. zero extension on load, and -- via a full-word
readback after a halfword store -- that `sh`/`sb` only touch the bytes they
own rather than silently behaving like `sw`). Full suite: 12 tests / 46
checks, all passing, no regressions in the 8 pre-existing tests.

## Future improvements

`fence`/`ecall`/`ebreak`/CSR and exceptions remain open (`docs/ROADMAP.md`
Phase 5, CSR/machine-mode item). RV32M (mul/div) is next in line and will
be the project's first genuine multi-cycle-execute requirement.
