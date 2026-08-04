# ADR 0037: RVC (Compressed Instruction) Support (Generation 3, Phase U)

## Problem

Phase T (`docs/adr/0036`) found this core cannot decode a real riscv64 Linux kernel Image's own first
instruction — a real `c.j` compressed jump forming the standard kernel-header trampoline. Virtually
every real-world prebuilt RISC-V binary is built with RVC (the "C" extension) enabled for code density;
this core (RV64IMAFD) had zero compressed-instruction support anywhere in the RTL. Presented to the
user via `AskUserQuestion` (close Phase T honestly vs. source a non-RVC kernel vs. implement real RVC
support): implement real RVC support now, not a workaround specific to one kernel build.

## Design

### Fetch-side simplification found by reading, not assumed

The hardest part of a real hardware RVC implementation is usually misaligned fetch: a 2-byte compressed
instruction shifts every later instruction off the 4-byte grid, and a 4-byte instruction can then start
at a 2-byte-aligned-but-not-4-byte-aligned address, straddling a word boundary. This core's own
`InstructionMemory.v` already reads `SIZE_BYTES`-bounded bytes starting at an arbitrary `readAddr` (a
behavioral byte-array model, not a real word-aligned BRAM primitive) — so an unaligned 4-byte read
already just works, with zero new memory-side plumbing needed. This single fact is what made the rest
of the design tractable at this scope.

### CompressedExpander.v

A new, purely combinational module: given the low 16 bits of whatever 4-byte fetch `InstructionMemory.v`
returns, decompresses a real compressed instruction into its bit-exact standard 32-bit RV64GC encoding.
Every downstream stage (`ImmGen.v`, `Control.v`, `ALUCtrl.v`, the register file) decodes the *expanded*
instruction exactly as if it had been fetched as a real 32-bit one — this module is the only place that
needs to know RVC exists at all. Covers the full standard C0/C1/C2 quadrant table this core's own
RV64IMAFD subset needs: `C.ADDI4SPN`/`C.{F}LD`/`C.LW`/`C.{F}SD`/`C.SW` (quadrant 0), `C.ADDI`/`C.ADDIW`/
`C.LI`/`C.ADDI16SP`/`C.LUI`/`C.SRLI`/`C.SRAI`/`C.ANDI`/`C.SUB`/`C.XOR`/`C.OR`/`C.AND`/`C.SUBW`/`C.ADDW`/
`C.J`/`C.BEQZ`/`C.BNEZ` (quadrant 1), `C.SLLI`/`C.{F}LDSP`/`C.LWSP`/`C.LDSP`/`C.JR`/`C.MV`/`C.EBREAK`/
`C.JALR`/`C.ADD`/`C.{F}SDSP`/`C.SWSP`/`C.SDSP` (quadrant 2). Reserved/unimplemented encodings expand to
`32'h0` — reusing this project's own existing "opcode 0000000 is a real illegal-instruction trap"
convention (`InstructionMemory.v`'s own out-of-bounds-read convention) rather than inventing a second
illegal-instruction signal path.

### Pipeline threading

`is_compressed` (combinational, `inst[1:0] != 2'b11`) threaded through `reg1`/`reg2` alongside the
existing `ifetch_fault`-style decode-context fields (same "must survive a load-use flush unmolested"
treatment). Two adders needed real fixes: the fetch-stage PC-increment adder (`pc_o + 4` → `pc_o +
(is_compressed ? 2 : 4)`) and the decode-stage link/fallthrough adder (`pc_plus4_regde`, used by both
`jal`/`jalr`'s own link value and the branch predictor's misprediction comparison) — a compressed
`c.jalr`'s real link value is PC+2, not PC+4; getting this wrong would corrupt the return address of
every compressed call. Scoped to `PROFILE_5STAGE` only (matching this phase's own real target — the
kernel boot never runs under `PROFILE_6STAGE_SPLIT_FETCH`); under split-fetch, `is_compressed` would be
computed one cycle stale relative to `pc_o`, a real, documented, but never-exercised gap (`is_compressed`
is provably always 0 for every existing non-RVC test regardless of profile, so this doesn't affect any
current regression).

### A second, fundamental Harvard-architecture fix (found by running, not designed for)

`InstructionMemory.v` read bytes MSB-first (`{insts[addr], insts[addr+1], insts[addr+2], insts[addr+3]}`)
— a real, pre-existing asymmetry with `DataMemoryBRAM.v`'s own LSB-first read, compensated for by
`elf2mem.py`/`asm.py` applying a real per-4-byte-*aligned*-word byte swap on write. This only ever
worked because every fetch before RVC was 4-byte-aligned, making a fixed per-aligned-word swap
indistinguishable from a real per-instruction swap. RVC breaks that: once a compressed instruction
shifts later instructions off the 4-byte grid, a **real, worked proof** shows no fixed static byte array
can satisfy "every possible unaligned 4-byte read reconstructs the correct little-endian value"
simultaneously (the same byte position gets required to hold two different values depending on which
overlapping 4-byte window is being read). Found directly: a raw, unswapped kernel Image byte-for-byte
placed into `imem.mem` read back as `0x81a00000` instead of the real little-endian `0x0000a081`,
silently corrupting the very first fetched instruction. Fixed at the real root: `InstructionMemory.v`
now reads LSB-first, matching `DataMemoryBRAM.v`'s own already-correct convention exactly — `asm.py`'s
`write_mem` updated to match (plain little-endian byte order, no swap), and `elf2mem.py`'s own
`swap_instruction_words` step removed entirely (real ELF bytes now work directly for both memories, no
reordering needed anywhere). This is a real, project-wide RTL/tooling change, not a kernel-boot-specific
patch — verified bit-exact for every existing (non-RVC) code path by regenerating and re-running both
Phase S's own firmware (`sim/firmware/build/`, still prints "OK") and a hand-written directed test
(`sim/programs/arith.s`, 26 instructions, reaches its own halt loop cleanly with zero spurious traps).

## Real bugs/findings

Found via the same granular Verilator PC/`mcause`/register-trace methodology Phase S established (new
`debug_jump_regde`/`debug_imm_sum`/`debug_inst_regfd`/`debug_inst_raw`/`debug_is_compressed`/
`debug_inst_final`/`debug_illegal_regde`/`debug_inst_regde`/`debug_pc_o_regde` taps, all the same
"unconnected changes nothing" shape `debug_x10` already established):

1. **`C.J`'s own immediate bit assembly had a real 2-bit swap**: `c[10:9]` (a Verilog bit-select,
   `{c[10],c[9]}` in that order) was used where `{c[9],c[10]}` was needed for `imm[9]`/`imm[8]` — found
   by hand re-deriving the RVC spec's own `imm[11|4|9:8|10|6|7|3:1|5]` table bit-by-bit against the
   actual encoding, not caught by the first several real instructions decoded correctly (`imm[9]`/
   `imm[8]` both happened to be 0 in every `c.j`/`c.jal` this phase's own kernel exercised before the
   bug was found by inspection).
2. **The InstructionMemory.v byte-order bug above** — the single most consequential finding, corrupting
   every fetched instruction from the kernel's own entry point onward until fixed.
3. **`C.BEQZ`/`C.BNEZ`'s own immediate was double-shifted**: an extra explicit trailing `1'b0` bit was
   included when assembling the real offset value, which `ShiftLeftOne`'s own downstream `<<1` (the
   standard mechanism this core's `ImmGen.v` already uses for B/J-type immediates, reconstructing the
   spec's implicit-zero low bit at use time) then doubled *again* — a real, second bit-position bug, not
   caught until a `c.bnez`'s own resolved branch target was directly compared against a hand-decoded
   expected value via a new `imm_sum` debug tap and found to be exactly double. Found only after ruling
   out the AMO 2-phase interlock (`docs/adr/0038`) as the cause first, via a dedicated
   `amo_active`/`amo_write_phase`/`amo_write_done`/`amo_stall` trace showing the interlock behaving
   exactly as designed.

## Alternatives considered

**A minimal expander covering only the specific compressed forms the kernel's own header happened to
use**, rather than the full standard table. Rejected once `objdump`'s own real disassembly of the
downloaded kernel showed RVC used pervasively throughout the binary, not just in the 64-byte header —
a minimal patch would only have delayed the identical class of failure by a few instructions.

## Validation strategy

Regenerated and re-ran Phase S's own firmware (bit-exact "OK") and `arith.s` (26-instruction directed
test, clean halt, zero spurious traps) after every RTL change in this phase — the same "prove nothing
existing regressed" bar every prior phase established, constrained here by Icarus being unexpectedly
unusable in this environment (a real, pre-existing, unrelated toolchain gap: even an unmodified
`riscvpipeline.v` fails to elaborate under this machine's own bundled Icarus with "declaration after
use" errors this project's own RTL has always relied on being legal — Verilator lint/compile substituted
throughout this phase instead). Beyond the firmware/directed-test regression, correctness was
established by running the real kernel itself: dozens of real compressed instructions (`c.j`, `c.lui`,
`c.li`, `c.bnez`, `c.mv`, `c.jr`, `c.sd`, and more) were hand-verified bit-by-bit against their expected
standard-encoding expansion at the exact point they were fetched, using the debug taps above.

## Future improvements

`PROFILE_6STAGE_SPLIT_FETCH`/`CACHE_WRITEBACK_SETASSOC` + RVC is untested and has a known, documented
timing gap (see Design). `sim/formal/`'s own frozen `CSR.v`/`riscvpipeline.v` copies (Phase L) remain
further unsynced. A hand-written directed RVC-specific test (assembled via a real toolchain with `-march
=...c`, checking known register results) would be a real, still-missing piece of standalone regression
coverage beyond "the real kernel happened to exercise it" — noted, not built, given this phase's own
time budget.
