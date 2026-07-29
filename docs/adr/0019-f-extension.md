# ADR 0019: RV32F single-precision floating point (Phase C of the redesign)

## Problem

The user's five-phase redesign (`docs/adr/0018`'s Problem section) named
variable pipeline depth (Phase A, done), a code-quality pass (Phase B), an
F-extension port (Phase C, this ADR), SoC integration (Phase D), and
performance work (Phase E) — sequenced so the currently-verified core is
never left broken mid-flight. Phase A's own plan explicitly scoped Phase C
as "orienting, not code-ready," requiring its own research-and-design pass
before implementation. That pass (recorded in a planning document, not
committed to the repo) confirmed three things before any code was written:

- **No opcode collisions.** RV32F's real encodings (`OP-FP`=`1010011`,
  `LOAD-FP`=`0000111`, `STORE-FP`=`0100111`, the R4-type
  `MADD`/`MSUB`/`NMSUB`/`NMADD` family=`1000011`/`1000111`/`1001011`/
  `1001111`) collide with nothing this core already defines. The one real
  structural collision this project has (`OPCODE_CUSTOM`/`ctz`=`0101010`,
  whose low 2 bits are RVC's "this is a compressed instruction" quadrant)
  is a future C-extension problem, not an F-extension one.
- **`ALUCtrl.v`/`ALU.v` have no room.** `ALUOp` (2 bits, all 4 used) and
  `ALUCtl` (5 bits, 4 free codepoints out of 32) cannot absorb RV32F's
  ~20+ operations. F needed a genuinely separate FPU control/datapath, not
  reuse of the integer ALU's enumeration.
- **RV32M (`docs/adr/0006`) was the right precedent**, not
  `HAZARD_STRATEGY`/`PIPELINE_PROFILE`: F is an always-present ISA
  addition, not a mutually-exclusive swappable research strategy — no new
  top-level parameter or `generate`/`if` toggle, just another fully-decoded
  part of the ISA, verified to the same bar as every other completeness
  pass in this project.

Two scoping decisions were made explicitly with the user before
implementation (via a planning-tool question, not assumed): **(1)** ship
the *full* RV32F extension, including `fdiv.s`/`fsqrt.s` and the
`fmadd.s`/`fmsub.s`/`fnmsub.s`/`fnmadd.s` family, not a reduced first pass,
and **(2)** build *full* float register forwarding from the start, not a
stall-only conservative first pass. Both were chosen as the more ambitious
option over a smaller first cut, which is why this phase spans ten
independently-verified steps (C1–C10) rather than one or two — larger than
Phase A.

Two further simplifications were adopted as conventional defaults (not
separately asked, since they're low-controversy given this project's own
precedents, but recorded here so they're visible and reversible):

- **No NaN-boxing.** NaN-boxing exists so code stays portable when `FLEN`
  (the float register width) exceeds an instruction's operand width — it
  matters for D-extension (64-bit) coexisting with F (32-bit) in one
  register file. This core is F-only, no D, `FLEN == XLEN == 32` exactly,
  so every float register always holds a real 32-bit value with nothing to
  box. Confirmed moot, not skipped for convenience.
- **Subnormals flush to zero, both on input and output**, with UF+NX set
  on the output side. Full gradual underflow is substantial extra design
  surface for a hand-written synthesizable core; flush-to-zero is a
  common, explicitly-documented simplification in real small FPUs. `NV`
  and `DZ` behave per spec regardless; only the subnormal *encoding* is
  affected — a subnormal-encoded operand is treated as its correctly-signed
  zero for arithmetic, and a result whose true magnitude underflows below
  the smallest normal is flushed to a correctly-signed zero rather than
  encoded as a real subnormal. `fclass.s` is the one deliberate exception:
  it inspects the raw encoding, not the arithmetically-flushed value, so a
  genuinely subnormal-encoded input still classifies as subnormal.

## Design

Ten steps, each its own commit (or small group), each ending with the full
suite passing again — the same discipline Phase A's A1–A6 established.

### C1 — Encoding infrastructure (`design/riscv_defs.vh`)

Every RV32F opcode/funct5/funct3/rounding-mode/CSR-address constant, no RTL
consumers yet — a pure documentation commit mirroring A1's
parameter-before-consumers staging and this project's CQ-1
(`riscv_defs.vh` as single source of truth) convention.

### C2 — `design/FRegister.v`, standalone

A parallel 32×32 float register file mirroring `Register.v`'s shape
(`XLEN`/`NUM_REGS` parameters, write-first bypass) but with **no
x0-hardwired-zero special case** (no float register is hardwired — f0 is
completely ordinary) and a **third read port** (`readReg3`/`readData3`)
built in from the start, since the R4-type FMADD family needs three float
source operands. Building the third port now avoided a second structural
change when C5 needed it. Verified standalone (`sim/tb/tb_fregister_unit.v`)
before any pipeline integration.

### C3 — `design/FALU.v`: combinational ops, standalone

One module covering every non-multi-cycle, non-FMA float op: `fadd.s`/
`fsub.s`/`fmul.s`, `fsgnj.s`/`fsgnjn.s`/`fsgnjx.s`, `fmin.s`/`fmax.s`,
`fclass.s`, `feq.s`/`flt.s`/`fle.s` (write an *integer* result despite
float operands — the first of several "reads float, writes int" cases),
`fcvt.w.s`/`fcvt.wu.s`/`fcvt.s.w`/`fcvt.s.wu`, `fmv.x.w`/`fmv.w.x`. Full
static and dynamic rounding-mode support and full NV/OF/UF/NX exception
flags. `design/fp_round.vh` (a shared `round_and_pack`/`shift_right_sticky`
pair, `` `include``d into every consumer since Verilog-2005 has no
function-library mechanism) was extracted from this module once
`FDivider.v`/`FSqrt.v` (C4) needed the identical logic.

Verified against a standalone Python reference model using exact
`fractions.Fraction` arithmetic (so every rounding mode could be checked
precisely, not just RNE) — ~4700 randomized and boundary-targeted vectors
during development, a curated ~230-check subset committed
(`sim/tb/tb_falu_unit.v`). **Found and fixed three real bugs**, all via
vector-by-vector testing, none by static reasoning:

1. **FMUL double-counted its own carry-out exponent adjustment** — once
   explicitly, once again via `round_and_pack`'s own carry-handling — a
   systematic 2×-too-large result across a large fraction of multiplies.
2. **`fcvt.w.s`/`fcvt.wu.s`'s shift-amount arithmetic was simply wrong** —
   extracted the integer part from an incorrectly-computed bit window.
   Fixed by reusing the already-verified `shift_right_sticky` helper
   instead of a bespoke shift formula.
3. **`round_and_pack`'s carry-renormalization mislabeled which bit becomes
   the new guard/round/sticky** after an addition carry-out, corrupting NX
   (and occasionally the rounding decision itself) for sums that happened
   to carry — including a case where the true sum was *exact* but got
   spuriously flagged inexact. A flag mismatch with matching result bits
   is not a "minor" bug; it traced back to a real, structurally-wrong bit
   assignment.

### C4 — `design/FDivider.v` + `design/FSqrt.v`: multi-cycle units

The plan's own flagged "least existing precedent, most real design
iteration expected" step. Both mirror `Divider.v`/`docs/adr/0009`'s proven
`busy`/`done` interlock signature exactly.

`FDivider.v`: restoring shift-subtract division of the two 24-bit
significands (`Divider.v`'s algorithm, adapted, not reinvented), 51
iterations of extra precision for correct rounding, NaN/inf/zero special
cases completing the same cycle `start` asserts. **Found and fixed two real
bugs**: the final iteration's packing step read the quotient/remainder
registers' *stale* (one-cycle-old, nonblocking) value instead of the
just-computed one, silently using only 50 of 51 needed iterations and
exactly halving every result; fixed with blocking-assigned locals the
packing step reads directly. And the divide-by-zero flag was only ever
driven high, never explicitly driven low entering a later, unrelated
division — a stale DZ from an earlier divide-by-zero silently persisted.

`FSqrt.v`: a binary digit-recurrence square root, no precedent anywhere in
this codebase, verified independently in Python (2000+ random values
against `math.sqrt`) before a line of Verilog was written. The real
subtlety: a float significand's implicit scale (2²³) is *odd*, so
`sqrt(mantissa)` directly picks up a spurious √2 factor unless the
exponent's parity is folded into the *radicand itself* first. Got this
wrong twice via closed-form derivation (off by 2, then by √2) before
empirical testing against known perfect squares pinned down the correct
construction (documented in the module's own header comment). Also hit,
and this time avoided from the start, the identical stale-register
off-by-one `FDivider.v` found.

### C5 — `design/FMADDUnit.v`: fused multiply-add

`fmadd.s`/`fmsub.s`/`fnmsub.s`/`fnmadd.s`, combinational — "fused" is about
*precision* (the full unrounded 48-bit product is aligned against the
addend and rounded exactly once, never rounded once for the multiply and
again for the add), not timing. Reuses `FALU.v`'s FADD/FSUB
swap-for-subtraction technique and `fp_round.vh`'s `round_and_pack`,
widened to a 112-bit alignment frame so the product's full 48 bits of
precision survive intact until the single final rounding. `op[1:0]`
(negate-product, negate-addend) reads directly off the opcode — see C9's
bugfix below for the real story of getting that bit slice right. Verified
against an independent Python reference (exact `Fraction` arithmetic on
product and addend separately, summed exactly before rounding once):
passed 3013/3013 general random vectors and 2000/2000
extreme-exponent-targeted vectors on the first run — the one new FPU
module this phase found no bugs in, plausibly because it built carefully
on top of already-verified pieces rather than designing alignment/rounding
from scratch again.

### C6 — Wire everything into the live pipeline

The plan's own flagged highest-risk single integration commit, mirroring
Phase A3's risk profile. `Control.v` gained a new `fRegWrite` output
(parallel to `regWrite`, mutually exclusive by construction — `feq.s`/
`flt.s`/`fle.s`/`fclass.s`/`fcvt.w.s`/`fcvt.wu.s`/`fmv.x.w` write the
*integer* file despite reading float operands). `FRegister.v` instantiated
in ID with its three read ports kept entirely separate from `Register.v`'s
`readData1`/`readData2` — deliberately *not* routed through
`Forward.v`/`MuxN`'s integer-only forwarding network, since that network's
hazard detection is keyed on plain 5-bit indices that can't distinguish an
integer register from a float one sharing the same index. `reg2.v`/
`reg3.v`/`reg4.v` extended with `fRegWrite`/`freadData1..3` threaded to
`FRegister.v`'s write port, which shares `writeData_regwb`/
`write_to_Reg_regwb` with `Register.v` (safe since `regWrite`/`fRegWrite`
never both fire). EX instantiates `FALU.v`/`FMADDUnit.v`/`FDivider.v`/
`FSqrt.v`, muxed into `fp_result`; `fp_stall` (mirroring `div_stall`'s
shape) merged into the existing stall fabric. Since real forwarding was
deferred to C7, C6 shipped a **deliberately maximally conservative
placeholder**: any float-reading instruction stalls while any float-write
is anywhere in flight — no register-index matching, correctness over
performance until C7 landed.

**Found and fixed two real bugs** via a hand-encoded directed test
(`sim/tb/tb_float_basic.v`, built via `asm.py`'s `word 0x...` raw-encoding
escape hatch since real F-mnemonic assembler support was still C9's job):

1. **`ImmGen.v` was never extended for `OPCODE_LOAD_FP`/`OPCODE_STORE_FP`**
   — `flw`/`fsw` both fell through to the default `imm=0` case, silently
   addressing offset 0 regardless of the instruction's actual immediate. A
   naive "store then immediately load back" round-trip check passed anyway
   (both ops used the same wrong address, internally consistent but
   pointing at the wrong memory location) — this only surfaced once
   `check_mem_word` independently verified the *intended* address actually
   held the written value. A round-trip check through the same buggy
   address computation cannot catch an offset bug like this; a check
   against the concrete address is what actually catches it.
2. **The pre-existing `docs/adr/0003` store-data-forwarding assertion**
   fired a false positive on `fsw`, since float stores source their data
   from `freadData2_regde`, not the integer forwarding network at all.
   Fixed by making the assertion's own expected-value computation
   float-aware — a reminder that a correctness *assertion* is itself code
   needing updates when an integer-only assumption stops holding, same as
   the RTL it checks.

### C7 — Float forwarding + hazard detection

The plan's own flagged single highest real-bug-risk area — float
interlocks share consumers (`reg2`'s `flush`/`hold`, `pc_stall`) with every
existing integer one, the exact bug class this project has hit four times
before (`docs/adr/0009`, `0013`, `0014`, `0016`). `design/FForward.v`
replaces C6's placeholder with real, register-indexed forwarding.
Deliberately a **sibling module**, not a generalized `Forward.v`: the
integer file has no third read port to give one, and bolting an
always-unused `readReg3`/`forwardC` onto `Forward.v` would be dead surface
on every non-float instruction. Same farthest-producer-first
priority-encode shape as `Forward.v` (index 0 = MEM/WB, index 1 = EX/MEM),
extended to three ports. One genuine behavioral difference: **no "forward
only if dest != 0" guard** — `Register.v` hardwires x0 and never really
commits a write there, so `Forward.v` must refuse that stale match;
`FRegister.v` hardwires nothing, so f0 is an ordinary forwardable register
and that guard would have silently broken any program computing into f0.

`reg2.v` gained a `readReg3`/`readReg3_regde` pass-through (the raw
`inst[31:27]` index) so `FForward.v` can see every instruction's rs3
index. The EX/MEM and MEM/WB forwarded *values* needed no new plumbing at
all — `exmem_fwd_val` (already `ALUOut_regem` for any non-jump
instruction, which float always is) and `writeData_regwb` (already generic
over destination file) turned out to already be exactly correct once
traced through, confirmed by inspection before wiring, not assumed.
`float_hazard_stall` was replaced by a narrow `float_load_use_hazard`: the
one float RAW hazard forwarding genuinely can't resolve is `flw`'s loaded
value (available one cycle later than any FALU/FMADD/FDivider/FSqrt
result), mirroring `Hazard.v`'s own `lw` check one stage upstream.

**No new bugs found in the forwarding logic itself** — the two real bugs
surfaced were existing wiring (`FALU.v`/`FMADDUnit.v`/`FDivider.v`'s EX
inputs, and reg3's `readData2_regde` for `fsw`'s store data) that still
needed to route through the newly-forwarded value instead of the raw
`freadData*_regde`, the same docs/adr/0003 lesson recurring on schedule.
Verified with a tight, back-to-back-dependency directed test
(`sim/tb/tb_float_forward.v`) targeting each forwarding path individually
(EX/MEM into rs1, MEM/WB into rs2, both operands from the same source at
once, EX/MEM and MEM/WB into rs3, the `flw` load-use hazard still
correctly stalling, and an integer/float pair sharing a numeric register
index with no cross-file contamination), plus confirming float forwarding
composes correctly with both `HAZARD_STRATEGY` values (deliberately not
gated by that parameter — it's the integer-only research-platform toggle).

### C8 — `fcsr` fully live

Replaces `RM_DYN`'s defensive-RNE-fallback and never-accumulated exception
flags with the real thing. `CSR.v` gained `fflags`/`frm` following the
existing `mscratch`-shaped plain-register pattern the C1 research
predicted would work, plus one genuinely new piece of behavior: `fflags`
is **sticky hardware-accumulated state** — every F-extension instruction
that retires ORs its own flags in, gated by a new `fp_flags_we`
(`(isOpFp_regde || isFma_regde) && !reg2_hold`) mirroring
`csr_write_en`/`trap_taken`/`mret_taken`'s existing `!reg2_hold` gating
one-for-one, for the identical reason: an instruction held in EX across
multiple cycles must commit its flags exactly once. `RM_DYN` resolution
now happens once, centrally, in `riscvpipeline.v`
(`fpu_rm = (funct3_regde==RM_DYN) ? frm_live : funct3_regde`) before any
FPU unit sees it — every module stays exactly as C3–C5 designed it,
expecting an already-resolved `rm`. Safe to apply unconditionally even
though `FALU.v`'s `funct3` port doubles as a sub-op selector for
FSGNJ/FMINMAX/FCMP/FMV_X_W_FCLASS: those families never legitimately
encode `funct3==111` at all (a reserved encoding for them).

**No RTL bugs found** — the one verification failure was the directed
test's own wrong expected value: `fcvt.w.s` of 2.5 is *inherently* inexact
under every rounding mode (2.5 has no exact integer representation), so
earlier conversions in the test had already set NX before a later
`fdiv.s`-by-zero contributed DZ — the value staying exactly constant
across an intervening *exact* `fadd.s` is itself the confirmation that
sticky-OR accumulation works correctly. `sim/tb/tb_float_fcsr.v` covers
`RM_DYN` genuinely reading live `frm` (the same conversion computed twice
with different `frm`, RUP→3 vs RNE→2), a static `rm` staying unaffected by
`frm`, sticky accumulation with no explicit write, an explicit software
clear, and the `fcsr` packed `{frm,fflags}` view read/written consistently
against `frm`/`fflags` addressed individually.

### C9 — Tooling completion + constrained-random verification

Every tool extended with real F-extension support, closing the
constrained-random cross-checking gap C6/C7/C8 had all explicitly carried
forward.

**A genuine RTL bug, found before any tooling work began**: building
`iss.py`'s independent float model required reasoning through the
MADD-family opcode encoding by hand, which surfaced that `fma_op_regde`
(`riscvpipeline.v`) sliced `opcode_regde[4:3]`, following `FMADDUnit.v`'s
own header comment ("bits[4:3] are 00/01/10/11"). That comment was simply
wrong: `OPCODE_MADD`/`MSUB`/`NMSUB`/`NMADD` all have bit4 == 0 — the bits
that actually vary across all four are **[3:2]**. Consequence:
`fmadd.s`/`fmsub.s` both decoded as op=00 (both computed `fmadd.s`'s
behavior), `fnmsub.s`/`fnmadd.s` both decoded as op=01 (both computed
`fmsub.s`'s behavior) — `fmsub.s`/`fnmsub.s`/`fnmadd.s` had been silently
wrong since C6 first wired the live pipeline. Not caught by C5's own
standalone `FMADDUnit.v` verification (drives the `op` port directly,
never through real decode) nor by any C6/C7/C8 directed test — every one
of them happened to only ever use `fmadd.s`, whose own op is 00 either
way, the one variant that could never have exposed this. Fixed to
`opcode_regde[3:2]`, with `FMADDUnit.v`'s own comment corrected (it's what
the fix was originally copied from); `sim/tb/tb_float_madd_family.v`
exercises all four variants together to close the gap for good. An
identical copy of the same mistake, inherited from the same wrong comment,
was independently found and fixed in this session's own scratch
hand-encoding tooling before it was trusted for any directed test.

**Tooling extensions**:
- `sim/tools/asm.py`: a `freg()` parser (`f0`-`f31`, no x0-equivalent) and
  encoders for every RV32F mnemonic, with a trailing optional rounding-mode
  operand defaulting to `dyn`. Validated by re-encoding earlier
  hand-encoded directed tests through the new mnemonics and diffing —
  byte-identical.
- `sim/tools/iss.py`: an independent RV32F reference model using exact
  rational arithmetic (`fractions.Fraction`; `math.isqrt` for `fsqrt.s`
  specifically, via exact-integer remainder classification against
  `(2·sig_floor+1)²`, since square root is generically irrational and a
  `Fraction` result isn't available) rounded once at the end — the same
  "exact math, then round" approach the C3–C5 standalone verification
  scripts used, reused here as a live oracle instead of a one-off script.
  Mirrors this core's two documented deviations exactly, not textbook
  float32. Validated against `numpy.float32` (3000/3000 matched per op,
  RNE, for fadd/fsub/fmul/fdiv/fsqrt) and against every existing directed
  float testbench's expected values through the full `ISS.step()`
  dispatch.
- `sim/tools/disasm.py`: full RV32F decoding including `fflags`/`frm`/
  `fcsr` in the CSR-name table.
- `sim/tools/random_gen.py`: float instructions mixed into the existing
  generator, drawing from the full `f0`-`f31` pool, `flw`/`fsw` reusing
  the same `BASE_REG`-relative safe-addressing pattern as `lw`/`sw`, and a
  curated set of "interesting" float32 bit patterns (0.0, 1.0, -1.0,
  +infinity, canonical NaN, a subnormal) seeded up front so NaN/Inf/
  subnormal/zero coverage shows up far more than uniform-random 32-bit
  patterns produce on their own. The original, more thorough 16-value seed
  list alone overflowed `InstructionMemory`'s 32-instruction budget before
  a single random instruction was generated — trimmed to 6, with an
  explicit budget assertion added to `gen_program` so this fails loudly if
  ever exceeded again.
- `sim/tb/dump_regs_template.v` / `sim/tools/run_random_tests.py`: the
  cross-check dump now includes all 32 float registers plus `fflags`/
  `frm`, read directly off `FRegister.v`'s/`CSR.v`'s own internal arrays.

## Alternatives considered

- **A reduced first pass** (deferring `fdiv.s`/`fsqrt.s`/the FMADD family,
  or stall-only hazard handling instead of full forwarding). Rejected —
  explicitly, by the user, when asked — in favor of full scope up front,
  sequenced into many small verified steps instead of one large one.
- **Generalizing `Forward.v` with a float-forwarding dimension** instead of
  a sibling `FForward.v`. Rejected: the integer file has no third read
  port to give one, and adding always-unused surface to every non-float
  instruction's forwarding path was worse than a small, clearly-scoped
  sibling module.
- **Real subnormal (gradual underflow) support.** Rejected as
  disproportionate extra design surface for a hand-written synthesizable
  core; flush-to-zero is a common, explicitly-documented simplification —
  see Problem section.
- **NaN-boxing.** Rejected as genuinely moot, not skipped for convenience
  — this core is F-only, `FLEN == XLEN` always.
- **Mirroring the RTL's internal bit-level rounding mechanics in
  `iss.py`** (guard/round/sticky bits, alignment shifts, digit-recurrence
  division/sqrt) instead of exact rational arithmetic. Rejected: an
  independent *result*, computed a structurally different way, is what
  actually catches RTL/model disagreements — reusing the same mechanics
  the RTL uses would only catch bugs in inputs, not in the shared
  algorithm itself.

## Validation strategy

Every step ended with the full suite passing again, zero-warning
`iverilog -Wall -g2005` compile, and (once each new module existed) its
own standalone Python-reference-checked unit test before any pipeline
integration — the same discipline as every prior phase. Directed suite
grew from Phase A/B's baseline to 35/35 by the end of C9 (`tb_falu_unit.v`,
`tb_fregister_unit.v`, `tb_fdivider_unit.v`, `tb_fsqrt_unit.v`,
`tb_fmaddunit_unit.v`, `tb_float_basic.v`, `tb_float_forward.v`,
`tb_float_fcsr.v`, `tb_float_madd_family.v` — nine new files across the
phase).

Standalone module verification (development-only vector counts, not all
committed — this project's convention of committing curated tests, not
bulk-generated ones): `FALU.v` ~4700 vectors (229 committed), `FDivider.v`
810 (35 committed), `FSqrt.v` 813 (33 committed), `FMADDUnit.v` 5013 across
two targeted batches (73 committed).

Constrained-random cross-checking (`sim/tools/run_random_tests.py` against
`sim/tools/iss.py`, C9): 675 programs total across this phase's sweeps —
300 + 200 + 50 + 5 at the default configuration across separate runs, 60 at
`HAZARD_STRATEGY=1`, 60 at `PIPELINE_PROFILE=1` — every one matched
bit-for-bit across integer registers, memory, all 32 float registers, and
`fflags`/`frm`. This is the first random cross-checking this phase had at
all; C6/C7/C8 were explicitly limited to directed tests until C9 built the
tooling to make it possible.

## Future improvements

- **Full IEEE 754 subnormal support** (gradual underflow) remains
  deliberately out of scope — see Problem/Alternatives.
- **D-extension (double precision)** not attempted; this phase's
  NaN-boxing-is-moot conclusion specifically depends on F being the only
  float extension present, and would need revisiting if D is ever added.
- **The C-extension's `OPCODE_CUSTOM` collision** with RVC's compressed-
  instruction quadrant, identified as a side effect of this phase's own
  opcode-space research, remains a separate, unaddressed future problem.
- **Real interrupts / `fence`** remain the same already-documented,
  unrelated intentional gaps noted in earlier ADRs.
- `FForward.v`'s `NUM_FWD_SRC` parameter (mirroring `Forward.v`'s A5
  generalization) is unexercised above its default of 2 by anything
  shipped in this phase, same open item A5 itself already noted for the
  integer side.
