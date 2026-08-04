# ADR 0028: RV64 migration foundation (Generation 2, Phase M)

## Problem

Generation 1 ("RV32IMAF Research Processor v1.0") closed out with Phase L (`docs/adr/0027`).
`docs/ROADMAP_VISION.md` calls for Generation 2 next: RV64 migration. `XLEN` is already a named
parameter (`docs/adr/0015-xlen-and-regcount-parameterization.md`) threaded through ~15 files, but
that ADR's own "Future improvements" section said plainly it wasn't truly variable yet — a real
RV64I attempt would need a second parameter separating instruction width from XLEN, and the
"instruction width == XLEN" simplification would need revisiting.

Three parallel research agents (RTL width assumptions, verification-tooling implications, ADR/
phase-sizing precedent) confirmed the actual gaps before any design work: `ImmGen.v`'s
sign-extension logic hardcoded 32-bit-sized replication counts (real bug, not just unexercised
code), the ALUCtl code space was nearly full (4 spare 5-bit codes, the `*w` family needed 9 new
ops), `DataMemoryBRAM.v` had no `ld`/`sd`/`lwu` support and its `lw` arm zero-extended instead of
sign-extending, and the entire toolchain (`asm.py`/`iss.py`/`disasm.py`/`random_gen.py`/
`run_random_tests.py`) was RV32-only with no XLEN awareness at all.

Confirmed via `AskUserQuestion` with the user (most-ambitious option each time, this project's
consistent pattern across every prior phase):
1. **Phase scope**: widen the existing RV32IMAF datapath to real XLEN=64 correctness AND add the
   new RV64-only instruction family together, in one phase — they touch the same files.
2. **Toolchain/verification timing**: ships lockstep inside this same phase, not deferred.
3. **Compliance suite** (riscv-arch-test): explicitly a separate later phase, not part of Phase M.

## Design

### Core decision: reuse ALUCtl codes via a `wordOp` signal, not new codes

RV64I's OP-32 (`7'b0111011`)/OP-IMM-32 (`7'b0011011`) opcodes reuse OP/OP-IMM's own funct7/funct3
encodings byte-for-byte — `ALUCtrl.v`'s existing R-type case arms already decode `addw`/`subw`/
`sllw`/`srlw`/`sraw`/`mulw`/`divw`/`divuw`/`remw`/`remuw` to the *existing* `ALUCTL_ADD`/`SUB`/
`SLL`/`SRL`/`SRA`/`MUL`/`DIV`/`DIVU`/`REM`/`REMU` codes with zero ALUCtrl changes. A new `wordOp`
signal — recomputed from `inst_regde` at EX (`isOp32_regde`/`isOpImm32_regde`), the same "second
decode" pattern this project's own F-extension classification already uses, no new `reg2`/`reg3`
field — tells `ALU.v` and a small `Divider.v` operand wrapper to truncate-to-32-and-sign-extend.
Since ALUCtl alone can't distinguish `divw` from `div`, `wordOp_regde` is the only thing that does.

### The widened shift-immediate split (RV32I vs. RV64I's full-width shifts)

RV32I's `slli`/`srli`/`srai` use a 5-bit shamt (`inst[24:20]`) with a 7-bit funct7 discriminator
(`inst[31:25]`). RV64I's full-width (non-`w`) versions need a 6-bit shamt (`inst[25:20]`) to reach
63 — bit 25 (formerly the low bit of funct7) becomes part of shamt, shrinking the discriminator to
a 6-bit funct6 (`inst[31:26]`, `riscv_defs.vh`'s new `FUNCT6_ALT`). `ALUCtrl.v`'s fix
(`funct7[6:1] == FUNCT6_ALT` instead of the full 7-bit compare) is bit-exact at XLEN=32 (bit 25 is
spec-0 for every legal RV32 shift there). The `*w` family's own shamt stays exactly 5 bits
regardless of XLEN (spec-mandated) — a second, independent code path in `ALU.v`/`ImmGen.v`/
`asm.py`/`iss.py`, not reusing the XLEN-dependent one.

### The `*w` divide family: wrap `Divider.v`, don't modify it

`divw`/`divuw`/`remw`/`remuw` truncate operands to 32 bits, sign/zero-extend back to XLEN
(matching the op's own signedness), run the unmodified, already fully XLEN-parameterized
`Divider.v` at full width, then truncate-and-**sign**-extend the result (always sign-extend,
regardless of signedness — the spec's "word instructions always sign-extend their result" rule,
matching `ALU.v`'s `wordOp` arms). Verified by hand this reproduces the INT32_MIN/-1 overflow edge
case correctly without a separate special case: two's-complement truncation of the true 64-bit
quotient (`2^31`) reproduces exactly the spec-mandated overflow result (the dividend itself).
`# ponytail: costs a full 64-cycle divide for what's architecturally a 32-bit divide; a genuine
32-cycle fast path is a separable future optimization, not attempted here.`

### MMU stays Sv32-only, force-disabled at XLEN=64

`translate_enable` gained `&& (XLEN==32)`. `CSR.v`'s `satp`/`mstatus` stay exactly RV32-shaped — no
`UXL`/`SXL`, no widened `satp.MODE`. A real RV64 MMU/CSR layout is Generation 3's own new-design
task (`docs/ROADMAP_VISION.md` already says Sv39 is a substantially new implementation, not a Sv32
port). Mirrored in `sim/tools/iss.py`'s `translate()`.

### `mulw` added beyond the originally-confirmed scope

The user's confirmed scope named only `divw`/`divuw`/`remw`/`remuw`; `mulw` (real RV64M) was added
alongside them since leaving it out would ship an incomplete RV64M under a core whose Generation 2
release name is explicitly "RV64IMAF Processor v2.0", and `ALU.v`'s existing single-cycle multiply
needed no new design work to extend. Low-risk, matches this project's "pick the more complete
option" pattern throughout its history.

## Real bugs/findings

Ten real, verified bugs found by running — this project's now-repeated experience that width/
timing interaction bugs only reveal themselves under real execution, not review:

1. **`ImmGen.v`: sign-extension broken at any `Width` other than 32** (the confirmed, expected
   bug this phase was scoped around). Every immediate arm used a fixed `{20{inst[31]}}`-shaped
   replication count sized for a 32-bit result — a concatenation's width is self-determined by its
   own operands, not the `signed` keyword on the output port, so assigning that fixed-32-bit result
   into a wider `imm` zero-extended the top bits instead of sign-extending them. Fixed by replacing
   every hardcoded `20`/`21`-shaped count with `Width-12`/`Width-21` (reduces to the original
   literal at Width=32). Caught the U-type (lui/auipc) arm too, which the research phase's own
   inventory had incorrectly called "already width-safe" — it wasn't; the spec requires the 32-bit
   result sign-extended to XLEN, and the un-fixed code zero-extended.
2. **`DataMemoryBRAM.v`'s `lw` arm had the identical bug**, independently found: `readData =
   raw_word_r` zero-extended instead of sign-extending at XLEN=64 — the entire reason RV64I has a
   separate `lwu` for the zero-extending case. Fixed alongside adding real `ld`/`sd`/`lwu` support.
3. **`WbDecoder`'s `BASE`/`SIZE` parameters were corrupted at XLEN=64.** Found by tracing a plain
   `sw`/`lw` sequence that hung forever (`mem_stall` stuck, no slave ever ack'd) — not anticipated
   in the plan. `riscvpipeline.v`'s `WbDecoder` instantiation built `BASE`/`SIZE` (flattened
   `NUM_SLAVES*XLEN`-wide arrays, `WbDecoder.v`'s own `[g*XLEN +: XLEN]` per-slot slicing) by
   concatenating `` `TIMER_BASE``/`` `UART_BASE``/`` `TIMER_SIZE``/`` `UART_SIZE``/`32'd0` — every
   one of them a plain 32-bit-sized literal (`riscv_defs.vh`). Fine (and bit-exact) at XLEN=32,
   where 32 bits *is* one whole slot; at XLEN=64 the concatenation was only half the width each
   slot needed, misaligning the entire address map. Fixed by explicitly zero-extending each field
   to a full XLEN-wide slot at the instantiation site.
4. **`ImmGen.v` had no case arm for the new `OPCODE_OP_IMM_32` opcode at all.** `addiw`/`slliw`/
   `srliw`/`sraiw` silently computed `imm=0` (the module's own latch-inference-safe default),
   making every one of the four behave like a no-op/pass-through. Found via the new directed
   test's own `x3`-`x6` checks all reading back exactly `x2`'s unmodified value. Fixed with a new
   case arm mirroring `OPCODE_I`'s shape but with a fixed 5-bit shamt (not the XLEN-dependent
   `SHAMT_BITS`).
5. **`ShiftLeftOne.v` was hardcoded 32-bit**, silently truncating `imm_regde` (XLEN-wide) before
   shifting — a real correctness gap for branch/jal targets at XLEN=64, found via a `-Wall` width
   warning once a testbench actually instantiated `PIPELINED` at XLEN=64 (the `iverilog -Wall
   -tnull design/*.v` check alone never elaborates at XLEN=64, so it couldn't have caught this).
   Fixed by adding a `Width` parameter.
6. **Two plain, unsized-literal `Adder` connections** (`.b(4)`, `.b(32'd4)` for PC+4) padded
   correctly by luck (Verilog's signed-port zero/sign-extension), but still warned under `-Wall` at
   XLEN=64. Fixed with explicit `{{(XLEN-32){1'b0}}, 32'd4}`.
7. **F-extension unit connections warned at XLEN=64** (`FALU`/`FMADDUnit`/`FDivider`/`FSqrt` are
   deliberately fixed FLEN=32, correctly taking only the low 32 bits of an XLEN-wide carrier wire
   via Verilog's implicit port-width pruning — correct behavior, but `-Wall`-noisy). Fixed with
   explicit `[31:0]` slicing at each connection point, no semantic change.
8. **`Uart.v`'s Wishbone connection warned the same way** (a deliberately fixed-32-bit 4-register
   peripheral fed from XLEN-wide bus wires). Fixed with an intermediate 32-bit wire and an explicit
   zero-extending `assign` into its slot of `wb_s_data_i`.
9. **`sim/tools/iss.py`'s `fmv.w.x` didn't truncate to the low 32 bits of its integer source.**
   Found by the XLEN=64 random-test sweep: a float register seeded via `lui`+`fmv.w.x` (both
   sides, RTL and ISS, correctly sign-extend `lui`'s result at XLEN=64 per fix #1) came back
   correct on the RTL side but wrong on the ISS side, since `self.fregs[rd] = A` copied the whole
   (sign-extended, 64-bit) integer register instead of just its low 32 bits — real spec text:
   "FMV.W.X... moves \[the] lower 32 bits of integer register rs1" to the float register. This
   confirmed the RTL was *already* correct; only the ISS had the bug. Fixed with `self.fregs[rd] =
   u32(A)`.
10. **`sim/tools/iss.py`'s `fcvt.s.w`/`fcvt.s.wu` had the identical class of gap**, not yet
    RTL-cross-checked (no directed/random test happened to hit it before the fix): `A` (the raw
    XLEN-wide integer source) was passed directly into `f_cvt_from_int`, which only correctly reads
    bit 31 as the 32-bit sign bit if the input is already truncated. Fixed with `f_cvt_from_int(
    u32(A), rm, unsigned)`.

## Alternatives considered

- **Widening `ALUCtl` to accommodate new codes for `addw`/`subw`/etc.** — rejected. The code space
  is nearly full, and it's unnecessary: OP-32/OP-IMM-32's funct7/funct3 fields exactly match OP/
  OP-IMM's for the operations they share, so `wordOp` (a one-bit "truncate this" signal) is
  strictly less code and touches far fewer files than widening a bus threaded through most of
  `riscvpipeline.v`.
- **A `generate if (XLEN >= 64)` guard for `DataMemoryBRAM.v`'s 8-byte access logic** — considered,
  then confirmed unnecessary by direct experiment: a plain runtime `if (XLEN >= 64)` (XLEN being a
  true elaboration-time constant) dead-code-eliminates cleanly under Icarus, with zero warnings and
  zero errors on the otherwise out-of-range `writeData[63:32]` slice at XLEN=32. Simpler than the
  approved plan assumed, avoiding a multi-driver/generate-scope refactor.
- **`check_tasks.vh`'s `check_reg`/`check_val` taking an explicit XLEN parameter** — considered
  (the approved plan expected this), then found unnecessary: Verilog's `!==` zero-extends both
  operands to the wider context width, so an unconditional widening to `[63:0]` is bit-exact at
  XLEN=32 with no parameter needed.

## Validation strategy

Eighteen independently-verified steps (M1-M18): parameter/declaration first, standalone fixes with
their own new unit testbenches next (`tb_immgen_unit.v`, `tb_aluctrl_unit.v`,
`tb_alu_wordop_unit.v`, `tb_control_unit.v`), the MMU-disable scoping decision isolated in its own
directed test (`tb_mmu_disabled_rv64_m7.v`), then the one high-risk "wire it all live" step
(`tb_rv64_wordops_m8.v`, every new instruction exercised end to end, including the `sllw`-vs-plain-
`sll` differentiator proving `wordOp_regde` really changes ALU behavior), toolchain in lockstep,
then a full re-verification sweep, then this ADR.

Final bar: 83/83 directed tests (7 new/extended: the 4 new unit tests, the 2 new XLEN=64 directed
tests, plus `tb_data_memory_bram.v` extended with an XLEN=64 instance), zero-warning
`iverilog -Wall -g2005 -tnull design/*.v` compile, 100/100 fresh random cross-check at default
XLEN=32 (regression), and 195 random seeds at XLEN=64 across every axis this project's own
constrained-random harness supports (default, `HAZARD_STRATEGY=1`, `PIPELINE_PROFILE=1`,
`BRANCH_PREDICTOR=1`, `CACHE_MODE=1`, variable memory latency, and one combined "everything at
once" run) — all clean. The independent `sim/tools/iss.py` reference model was cross-checked
directly against the RTL-verified `tb_rv64_wordops_m8.v` results before being trusted as the random
sweep's own oracle (Findings #9/#10 were found this way).

## Future improvements

- **Compliance suite** (riscv-arch-test) — confirmed as a separate later phase, not started here.
- **A 32-cycle fast path for `*w` divides** — currently costs a full XLEN-cycle (64-cycle) divide
  for what's architecturally a 32-bit divide (see Design's `# ponytail` note).
- **A real RV64 MMU** (Sv39, 3-4 level, 64-bit PTEs) and the real RV64 `satp`/`mstatus` CSR layout
  (`UXL`/`SXL` fields, widened `satp.MODE`) — deliberately deferred to Generation 3, per
  `docs/ROADMAP_VISION.md`'s own assessment that this is a substantially new implementation, not a
  Sv32 port.
- **`sim/tools/gen_trace.py`'s pipeline viewer** gained an `--xlen` flag affecting only its
  disassembly of plain shift immediates — the underlying `sim/tb/gen_trace.v` testbench itself is
  still untouched and explicitly `PIPELINE_PROFILE=0`-only; a genuinely XLEN=64-aware viewer
  (wider register-heatmap hex formatting, etc.) is unstarted.
- **`sim/tools/bench_runner.py`/`sim/tools/profiler.py`** gained `__XLEN__` template plumbing
  (default 32, bit-exact) but no CLI flag to actually drive a benchmark/profiler run at XLEN=64 —
  minimal wiring only, not a claim that benchmark/profiler numbers exist for RV64 yet.
