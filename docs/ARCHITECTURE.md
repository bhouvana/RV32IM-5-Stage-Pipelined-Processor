# Architecture Report — RV32I 5-Stage Pipeline

**Status**: Phase 1 audit (baseline as of this document's authoring), now updated with real findings from Phase 3 verification work. Assume correctness only where verified below; everywhere else, "assumed correct" means "not yet proven wrong," not "proven right."

## Errata (added after building the verification harness)

This audit was originally static analysis only (§0). Once a directed test
suite existed and actually ran (`sim/run_tests.sh`, 8 tests / 36 checks, all
passing as of this update), it immediately found three real bugs that
reading the RTL had not surfaced -- concrete evidence for why §15 ranked
verification as the highest-leverage next investment rather than a nice-to-have:

1. **`ALU.v`'s `sra` didn't sign-extend** -- `A`/`B` are plain (unsigned)
   ports, so Verilog's `>>>` silently degraded to a logical shift. Fixed
   with `$signed(A) >>> B`.
2. **Register-file same-cycle write/read race, gap=3** -- `Register.v` had
   no write-first bypass, and neither `Forward.v` (covers gap=1/2) nor
   `Hazard.v` (covers load-use) covered the specific case where a
   producer's WB cycle exactly coincides with a different instruction's ID
   read (concretely: producer and consumer exactly 3 instructions apart).
   See `docs/adr/0002-register-file-write-first-bypass.md`.
3. **Store data bypassed forwarding entirely** -- `reg3`'s store-data input
   was wired to the raw, unforwarded `readData2_regde` instead of the
   already-correctly-computed `readData2_final`. Any `sw` whose data
   register was written 1-2 instructions earlier stored stale data. See
   `docs/adr/0003-store-data-forwarding.md`.
4. **`slt`/`blt`/`bge`/`ble`/`bgt` compared as unsigned** -- the same root
   cause as the `sra` bug (plain, non-`signed` ALU ports), found while
   implementing `bltu`/`bgeu` and fixed in the same pass. See
   `docs/adr/0004-signed-arithmetic-casts.md`.
5. **`sll`/`srl`/`sra` used the full 32-bit shift-amount register instead of
   its low 5 bits** -- per spec, register-register shifts only use `rs2[4:0]`;
   `A >> B` with `B >= 32` discards every bit in Verilog. Invisible to every
   directed test (none happened to use a shift-amount register holding
   >=32); found by constrained-random cross-checking against an independent
   reference model. See `docs/adr/0010-random-testing-and-coverage.md`.
6. **`riscvpipeline.v` declared `funct3_regde` with a source-bit-position-
   shaped range (`[14:12]`) instead of a plain 3-bit width (`[2:0]`)** --
   every prior use connected or indexed the whole vector (position/value
   based, so the mismatched index labels never mattered), but CSR wiring's
   `funct3_regde[2]`/`funct3_regde[1:0]` bit-selects fell outside the
   declared `[12:14]` range and silently read as `x`. Found immediately by
   the CSR directed tests (a consecutive-cycle CSR read-after-write
   corrupted with X). See `docs/adr/0011-csr-and-exceptions.md`.
7. **Two real interlock bugs surfaced integrating `DataMemoryBRAM.v`'s
   synchronous read into the live pipeline**: (a) deriving the new MEM-stage
   stall from the memory's own registered "read happened" signal broke
   back-to-back loads (a busy/done-style level-vs-edge ambiguity, the same
   class of bug as errata's div/rem interlock, `docs/adr/0009`); (b) an
   initial "bubble" applied to the MEM/WB register on every stall cycle
   evicted an unrelated, already-complete instruction's forwardable result
   one cycle before an instruction stalled behind an in-flight load actually
   needed it. Neither was visible in the directed suite -- (a) needed a
   directed test with two adjacent loads, (b) only showed up via
   constrained-random cross-checking. See `docs/adr/0013-mem-stage-retiming.md`.

Also implemented in this pass: `jal` (previously decoded but functionally
inert, §11) is now fully wired -- target, link value, and forwarding
correction (`docs/adr/0001-jal-implementation.md`) -- followed by the rest
of RV32I completeness: `jalr`, `lui`, `auipc`, `bltu`/`bgeu`, and
byte/halfword loads/stores (`docs/adr/0005-isa-completeness.md`). §11's ISA coverage
table and §15's readiness table are otherwise still accurate as written;
this errata doesn't change them, it documents what the errata itself
found.

## 0. Scope of this audit

Every RTL file in `design/` and the testbench (then in `simulation/`, since removed -- see §14) was read in full. No synthesis, lint, or simulation run has been performed as part of this audit — the findings below are static-analysis (read-the-RTL) findings. Section 13 explicitly separates "observed in code" from "would need simulation/synthesis to confirm."

## 1. Block diagram

```mermaid
graph LR
    subgraph IF[Fetch]
        PCreg[PC.v] --> IMEM[InstructionMemory.v]
        AdderPC4[Adder.v +4]
    end
    subgraph ID[Decode]
        reg1[reg1.v IF/ID] --> RF[Register.v]
        reg1 --> CTRL[Control.v]
        reg1 --> IMM[ImmGen.v]
        reg1 --> HZD[Hazard.v]
    end
    subgraph EX[Execute]
        reg2[reg2.v ID/EX] --> FWD[Forward.v]
        reg2 --> SLA[ShiftLeftOne.v]
        FWD --> MUXA[Mux4to1 A]
        FWD --> MUXB[Mux4to1 B]
        MUXA --> ALUCTRL[ALUCtrl.v]
        ALUCTRL --> ALU[ALU.v]
        SLA --> AdderBR[Adder.v branch target]
    end
    subgraph MEM[Memory]
        reg3[reg3.v EX/MEM] --> DMEM[DataMemoryBRAM.v]
    end
    subgraph WB[Writeback]
        reg4[reg4.v MEM/WB] --> WBMUX[Mux2to1 WB select]
    end
    WBMUX -.write.-> RF
    ALU -.branch_zero/zero.-> PCMUX[Mux2to1 PC select]
    AdderBR -.imm_sum.-> PCMUX
    PCMUX --> PCreg
```

This matches the diagram in [README.md](../README.md) but adds the two feedback paths that the README omits: the writeback-to-regfile path and, more importantly, the **EX-stage-to-fetch-stage branch resolution path**, which is the most architecturally significant (and riskiest) wire in the design — see §8.

## 2. Module inventory

| Module | File | Parameterized? | Role |
|---|---|---|---|
| `PIPELINED` | `riscvpipeline.v` | No | Top-level integration |
| `PC` | `PC.v` | No | Program counter register, stall-holds |
| `Adder` | `Adder.v` | No (fixed 32-bit) | Generic add; reused for PC+4 and branch target |
| `InstructionMemory` | `InstructionMemory.v` | No | 128-byte instruction ROM, `$readmemb`-loaded |
| `reg1` | `reg1.v` | No | IF/ID register; also does branch-squash and stall-hold |
| `Control` | `Control.v` | No | Main decoder (opcode → control signals) |
| `ImmGen` | `ImmGen.v` | `Width` (unused in practice — always 32) | Immediate extraction |
| `Register` | `Register.v` | No | 32×32 register file, `x0` hardwired, `sp` reset to 128 |
| `Hazard` | `Hazard.v` | No | Load-use RAW hazard → stall/flush |
| `reg2` | `reg2.v` | No | ID/EX register; also does branch-squash and load-use bubble |
| `Forward` | `Forward.v` | No | EX/MEM & MEM/WB forwarding priority logic |
| `ShiftLeftOne` | `ShiftLeftOne.v` | No | `imm << 1` for branch target |
| `Mux4to1` | `Mux4to1.v` | `size` | ALU operand forwarding mux (only 3 of 4 select codes used) |
| `Mux2to1` | `Mux2to1.v` | `size` | Generic 2:1 mux, reused 3× (PC select, ALU-B select, WB select) |
| `ALUCtrl` | `ALUCtrl.v` | No | ALUOp + funct3/funct7 → 5-bit ALU opcode |
| `ALU` | `ALU.v` | No | Execute unit; also computes branch conditions |
| `reg3` | `reg3.v` | No | EX/MEM register; `hold` freezes it during `mem_stall` (`docs/adr/0013`) |
| `DataMemoryBRAM` | `DataMemoryBRAM.v` | `SIZE_BYTES` | Data RAM, byte/halfword/word access; synchronous (registered) read |
| `reg4` | `reg4.v` | No | MEM/WB register; `hold` freezes it during `mem_stall` (`docs/adr/0013`) |

**Reuse is already present** (`Adder` used twice, `Mux2to1` used three times) — this is a good foundation for the "reusable IP" objective, but the reuse stops at trivial combinational primitives. None of the stage-specific logic (`Control`, `ALUCtrl`, `Hazard`, `Forward`) is written against a shared types/constants package, so there is no single source of truth for opcode values, ALUCtl encodings, or pipeline register field layouts. Every module re-derives bit widths and magic numbers independently.

## 3. Pipeline register contents (the actual "architecture" of this CPU)

### `reg1` (IF/ID)
| Field | Width | Purpose |
|---|---|---|
| `inst_regfd` | 32 | Fetched instruction |
| `pc_o_regfd` | 32 | PC of fetched instruction |

Squash behavior: on `branch_regde & zero` → loads `0x00000013` (`nop`) and `pc=0`. On `stall` → holds. This is the correct location for a load-use stall bubble (freeze IF/ID, freeze PC) but it double-encodes reset (`~rst`) and branch-squash as separate `if` arms with duplicated field lists — see §12.

### `reg2` (ID/EX)
Carries every decoded control signal (`branch`, `memRead`, `memtoReg`, `memWrite`, `ALUSrc`, `regWrite`, `ALUOp`), the destination register, both register-file read values, the immediate, funct3/funct7, and the two raw source-register numbers (needed downstream only for forwarding compare in `Forward.v`, since the actual operand values are forwarded via mux rather than at this register). This is the widest and busiest of the four pipeline registers — a natural target if `PIPELINED` is ever split into a `struct`/`packed` bus (see Roadmap R-2).

### `reg3` (EX/MEM)
Carries `ALUOut`, `readData2` (store data), destination register, and the memory/writeback control bits. Notably carries `zero`/`branch_regde`/`imm_sum` through to EX/MEM even though branch resolution has *already happened* by the time this register latches (branch resolution reads `reg2`'s outputs directly, combinationally, in the same cycle) — these three fields (`branch_regem`, `zero_regem`, `imm_sum_regem`) are dead: nothing downstream reads them. **Confirmed by grep**: no consumer of `branch_regem`, `zero_regem`, or `imm_sum_regem` exists anywhere in `riscvpipeline.v`. This is unused pipeline-register width — free to remove, and a good first PR for a new contributor.

### `reg4` (MEM/WB)
Carries `readData` (load result), `ALUOut_regem` (ALU result), destination register, `memtoReg`, `regWrite`. Minimal and clean — this is the tightest of the four registers.

## 4. Control unit (`Control.v`)

Pure combinational decoder keyed on `opcode` only (7 bits), producing `{branch, memRead, memtoReg, ALUOp[1:0], memWrite, ALUSrc, regWrite}`. `funct3`/`funct7` are *passed through* unmodified (not used for control decisions in this module) — all funct-based sub-decoding happens later in `ALUCtrl`. This is architecturally correct (matches Patterson & Hennessy's canonical single-cycle/pipelined control unit split) and is one of the cleanest modules in the repo.

Opcodes handled: `0101010` (custom), `0000011` (load), `0100011` (store), `0010011` (I-type ALU), `0110011` (R-type ALU), `1100011` (branch), `1101111` (JAL, decoded but see §11 — datapath doesn't actually support it correctly). Everything else falls into an explicit all-zero `default` — this module is fully specified and latch-free.

## 5. ALU / ALUCtrl encoding

`ALUCtrl.v` builds a 5- or 6-bit concatenation of `{ALUOp, funct7, funct3}` (R-type/I-type-shift) or `{ALUOp, funct3}` (branches, most I-type) and maps it to a 5-bit `ALUCtl`. Full opcode table:

| ALUCtl | Operation | ALUCtl | Operation |
|---|---|---|---|
| `00000` | add | `01001` | and |
| `00001` | sub | `01010` | beq |
| `00010` | sll | `01011` | bne |
| `00011` | slt | `01100` | blt |
| `00100` | sltu | `01101` | bge |
| `00101` | xor | `01110` | ble* |
| `00110` | srl | `01111` | bgt* |
| `00111` | sra | `10101` | ctz (custom) |
| `01000` | or | `11111` | illegal/default |

`*` `ble`/`bgt` are **not standard RV32I** — real RISC-V only defines `beq/bne/blt/bge/bltu/bgeu` (6 funct3 values). This design instead maps funct3 `100`/`101` to `ble`/`bgt`, meaning it diverges from the real RV32I branch encoding. This should be flagged clearly as a **custom ISA extension**, not standard RV32I, in any external-facing documentation — someone assembling with a real RISC-V toolchain (`riscv32-unknown-elf-as`) would get `bltu`/`bgeu` semantics on those same bit patterns, not `ble`/`bgt`. This is the single biggest "is this really RV32I" claim to correct.

`ALU.v` computes `branch_zero` for every branch variant and unconditionally does `ALUOut = A & B` on all six branch paths — `ALUOut` is architecturally meaningless for branches (never consumed downstream since `regWrite=0` on branches), but the redundant `A & B` costs real gates/power in a real synthesis. Free cleanup.

The custom `ctz` op (`10101`) is a **32-cycle unrolled loop in a combinational `always @*` block** (`for (i=0;i<31;...)`). Functionally fine in simulation; in synthesis this becomes a 31-deep priority-encoder chain — almost certainly the **longest combinational path in the entire ALU**, and thus a strong candidate for the processor's critical path if this opcode is reachable (see §8). It also has an off-by-one: the loop only scans bits `[0:30]`, never checking `A[31]`, so `ctz(0x80000000)` (only the sign bit set) would report 31 instead of the value being fully zero only in bit 31 — needs a testbench case.

## 6. Hazard detection (`Hazard.v`)

```verilog
flush = memRead_regde && ((write_to_Reg_regde == readReg1_fd) || (write_to_Reg_regde == readReg2_fd))
stall = flush
```

This is the textbook load-use hazard: if the instruction currently in ID/EX (`reg2`) is a load, and the instruction currently in IF/ID (`reg1`) reads the load's destination register, stall the PC and IF/ID, and bubble ID/EX for one cycle. Correct in concept. Two gaps:

1. **No `x0` exclusion.** If `write_to_Reg_regde == 0` (e.g., `lw x0, 0(x1)` — legal, discards the load), the hazard unit still stalls, even though `x0` reads always return 0 regardless of forwarding. Wasted cycle, not a correctness bug (`Register.v` already forces `x0` reads to 0 combinationally), but worth fixing when touching this file.
2. **No hazard check against `reg3`/`reg4`.** This is fine *only* because `Forward.v` covers EX/MEM and MEM/WB RAW hazards for register-value forwarding — the load-use case specifically needs a stall (not forward) because the loaded value isn't available until the end of MEM, one cycle later than a normal ALU result. The division of labor between `Hazard.v` (load-use, 1-cycle-late data) and `Forward.v` (everything else, data available in time) is architecturally correct and matches the standard MIPS/RISC-V textbook pipeline design.

## 7. Forwarding (`Forward.v`)

Priority-encoded per operand: EX/MEM (`regWrite_regem`, most recent) beats MEM/WB (`regWrite_regwb`), both gated on `dest != x0`. This is correct RAW-hazard priority (forward the *freshest* value). `forwardA`/`forwardB` are 2-bit but the `Mux4to1` consumers only implement 3 of 4 select codes (`00`=regfile, `01`=MEM/WB, `10`=EX/MEM); `2'b11` is unreachable given `Forward.v`'s logic (it never emits `11`), so the mux's fallback-to-`s0` default for `11` is dead code, not a live bug — but it's a code smell: a 2-bit signal with a value that can never occur should either be a proper 3-way tagged encoding with an explicit "invalid" assertion, or narrowed. Good candidate for a `unique case` + assertion once a lint/formal flow exists (Roadmap V-3).

## 8. Branch resolution — the architecturally load-bearing decision

Branches resolve in **EX**, one stage later than the classic "resolve in ID with a dedicated comparator" scheme, and two stages after fetch. The resolution signal (`branch_regde & zero`, both driven off `reg2`'s *registered* outputs and the *combinational* `ALU.zero` output) feeds directly, combinationally, into the **fetch-stage PC select mux** (`m_Mux_PC`). This means:

- **Squash condition is `branch_regde & zero` in both `reg1` and `reg2`** — i.e. squashing (and therefore the fetch penalty) fires only when a branch is resolved **taken**. Not-taken branches fall through with zero penalty, since sequential fetch was already the (correct) guess. This is textbook predict-not-taken behavior: **misprediction penalty = 2 cycles, paid only on taken branches.** This reading should still get a directed testbench case (Roadmap V-2) before being relied on, since it's a static-analysis conclusion, not a simulated one.
- **The combinational path this creates is long**: `reg2`'s registered branch/funct fields → `ALUCtrl` → `ALU` (comparator) → `zero` → AND with `branch_regde` → `Mux2to1` PC select → `PC` register input — all settling within one clock period, in the same cycle the ALU is also computing `A & B` for the branch's (unused) `ALUOut`. **This is very likely the critical path of the whole processor** and should be the first thing measured once a synthesis flow exists (Roadmap F-1).

## 9. Memory interfaces (updated — see errata items 5-7 and `docs/adr/0005`, `0011`, `0012`, `0013`)

**Instruction memory**: size is now a `parameter` (`SIZE_BYTES`, default 128, threaded from `PIPELINED`'s `MEM_SIZE_BYTES`, `docs/adr/0012`), word-read only; `readAddr >= SIZE_BYTES` still returns 0. Past-end-of-program execution is no longer a silent, harmless NOP stream, though — as of `docs/adr/0011`, opcode `0000000` is not a valid instruction and correctly raises an illegal-instruction trap. Every test program (directed and random-generated) now ends in a deliberate `jal x0, self` spin loop rather than relying on running off the end into zero-filled memory; "program ended" is still not something architectural state exposes directly (there's no `wfi`/halt instruction), but the spin-loop convention makes intent explicit rather than accidental.

**Data memory**: size is likewise now a `parameter` (`docs/adr/0012`). Byte/halfword access width (`lb`/`lh`/`lbu`/`lhu`/`sb`/`sh`) was completed in `docs/adr/0005` — this section's original claim that only `lw`/`sw` worked is no longer accurate; see §11's ISA coverage table for current state.

As of `docs/adr/0013`, the live data memory is `DataMemoryBRAM.v` (synchronous write **and** read) — `docs/adr/0012` built and unit-tested this as a standalone, BRAM-inferable replacement for the old combinational-read `DataMemory.v` (since removed, fully superseded) but deliberately deferred wiring it in, since doing so changes when load data becomes available (one cycle later than before). That retiming is now done: `riscvpipeline.v`'s `mem_stall` interlock holds `reg2`/`reg3`/`reg4` for exactly the one extra cycle a fresh load spends in `reg3`, mirroring the shape `docs/adr/0009`'s divider interlock established one stage earlier in the pipe. No changes were needed to `Hazard.v` or `Forward.v` themselves — the existing load-use stall/bubble and MEM/WB forwarding path turned out to already be sufficient once `reg2`/`reg3`/`reg4` correctly held their occupants for the extra cycle (see the ADR for the two real interlock bugs found getting this right).

## 10. Reset strategy

Every clocked module uses `if (~rst) <reset values> else <normal operation>`, checked *inside* the `always @(posedge clk)` block — this is a **synchronous, active-low reset**, which is synthesis-friendly and ASIC-conventional. Good.

However: the signal is called `rst` throughout the design but is literally wired to the top-level port named **`start`**, and the testbench treats it as "hold low to reset, then drive high to run" (`start = 0; #10 start = 1;`) — i.e., it is *never deasserted again* after the initial reset. There is no reset synchronizer (not needed for synchronous reset). ~~Recommend renaming the port~~ **Done, partially**: the port itself was left as `start` (renaming it would mean touching every instantiation across `sim/tb/*.v`, `fpga/top.v`, and this document for a cosmetic gain), but `riscvpipeline.v` now carries an explicit header comment documenting the misnomer and its single-cycle-CPU-template origin, so the behavior is no longer undocumented even though the name itself wasn't changed. (This section originally cited a stale in-code comment, `// TODO: connect wire to realize SingleCycleCPU`, as evidence of that origin — that comment has since been removed from the file; the origin is now documented in prose instead of left as an accidental artifact.)

## 11. ISA coverage matrix (RV32I base, 47 instructions)

**Updated by `docs/adr/0001` and `docs/adr/0005`** — this section originally documented real gaps (jal inert, jalr/lui/auipc absent, bltu/bgeu absent, byte/halfword access absent); all have since been closed and verified (`sim/run_tests.sh`, 12 tests / 50 checks). Table below reflects current state; see those ADRs for what changed and why.

| Category | Implemented | Missing |
|---|---|---|
| R-type ALU | `add sub sll slt sltu xor srl sra or and` (10/10) | — |
| I-type ALU | `addi slti sltiu xori srli srai ori andi` (8/8, via `ALUOp=11`) | — |
| Loads | `lw lb lh lbu lhu` (5/5, funct3-selected width in `DataMemoryBRAM.v`) | — |
| Stores | `sw sb sh` (3/3) | — |
| Branches | `beq bne blt bge bltu bgeu` (6/6 standard) plus custom `ble bgt` (funct3=100/101, using the two funct3 codes standard RV32I leaves for `bltu`/`bgeu` — those got the two *other* free codes, funct3=110/111; see `docs/adr/0005`) | — |
| Jumps | `jal jalr` (both fully wired: target, PC+4 link, forwarding correction) | — |
| Upper-immediate | `lui auipc` (both reuse the ALU's `ADD` via an A-operand override, no new writeback path) | — |
| Custom | `ctz`-like instruction, opcode `0101010`, `ALUOp=10`, funct7=`1`/funct3=`111` pattern | — |
| Fence/system | `ecall ebreak mret` (M-mode synchronous exceptions) and `csrrw csrrs csrrc csrrwi csrrsi csrrci` against `mstatus mtvec mscratch mepc mcause` — see `docs/adr/0011-csr-and-exceptions.md` | `fence` (a no-op on this in-order, single-hart, no-cache design — nothing for it to order); real interrupts (no timer/external IRQ line exists to drive them); S-mode/U-mode/PMP |

**Bottom line**: RV32I base ISA plus RV32M (`docs/adr/0006`) is complete. M-mode synchronous exceptions and the CSRs needed to handle/return from them (`docs/adr/0011`) close the last ISA-completeness gap named in Phase 5; only `fence` (structurally a no-op here) and real interrupt support (no hardware interrupt source exists) remain unimplemented, both by design rather than oversight. The README's claim of "all the R I L S B type instructions" is now accurate and understates what's actually implemented.

## 12. Coding style / synthesis-friendliness observations

- ~~No `` `default_nettype none`` in any file~~ **Done** (`docs/adr/0008`): every `design/*.v` file now brackets itself with `` `default_nettype none``/`` `default_nettype wire``, which caught 3 genuinely undeclared wires in the process.
- ~~No shared constants/parameters package~~ **Done**: `design/riscv_defs.vh` centralizes opcodes/ALUOp/ALUCtl encodings, migrated into `Control.v`/`ALUCtrl.v`/`ALU.v` (`ImmGen.v` left as literals — already clearly commented per-case, migrating it was judged not worth the churn). `sim/tools/asm.py` still keeps an independent Python copy of the same encodings (can't `` `include`` a Verilog header) — noted as a known sync-by-hand gap in `docs/ROADMAP.md`.
- ~~`wire [14:12] funct3_regde;` in `riscvpipeline.v`~~ **Fixed** (`docs/adr/0011`): this was flagged here as merely cosmetic, but turned out to be a real latent bug — every use up to that point connected/indexed the *whole* vector (position/value based, so the mismatched index labels never mattered), but `docs/adr/0011`'s CSR wiring was the first code to bit-select *into* it (`funct3_regde[2]`, `funct3_regde[1:0]`), and those indices fall outside the declared `[12:14]` range, silently reading as `x`. Now `[2:0]`. Worth remembering as a general lesson: an index-range mismatch that only ever appears in whole-vector connections is invisible until something finally slices it.
- `ImmGen.v`'s `case` statement has no `default` arm — for any opcode not in {`0010011`,`1100011`,`0000011`,`0100011`,`1101111`}, `imm` is left unassigned in that evaluation of the `always @*` block, which in a real synthesis tool infers a **level-sensitive latch**, not a wire. Not a functional bug today (every consumer of `imm` gates it behind `ALUSrc`, which is 0 for opcodes ImmGen doesn't cover), but it will show up as a "latch inferred" warning the moment anyone runs a real lint pass, and is exactly the kind of thing Phase 3 (verification) should catch with an assertion or lint gate before it's allowed to merge again.
- ~~`reg1.v`/`reg2.v` repeat their entire reset-value field list~~ **Done** (`docs/adr/0008`): `reg2.v` now uses text macros (`` `ZERO_CONTROL_FIELDS`` etc.) instead of repeating ~90 lines across 4 arms; `reg1.v` needed no change (already minimal).
- ~~Every register file, memory, and pipeline register in the design is sized as literal `32`/`128`/`5` rather than a `localparam`~~ **Partially done** (`docs/adr/0012`): `DataMemory.v`/`InstructionMemory.v` sizes are now a `parameter` (`SIZE_BYTES`), threaded from `PIPELINED`'s new `MEM_SIZE_BYTES`. The architectural register file (32 x 32-bit) and pipeline register widths are still fixed literals — only memory sizing was in scope for FPGA readiness; the rest remains blocking for the fuller Phase 6 "compare pipeline depths" goal.

## 13. What this audit could *not* determine from static reading alone

These require an actual simulation or synthesis run and are listed here specifically so Phase 3 (verification) has a concrete initial test list:

1. Whether the pipeline actually produces correct architectural results end-to-end for a nontrivial program (no self-checking testbench exists today — see §14).
2. The `ctz` off-by-one on `A[31]` (§5) — needs a directed test.
3. Actual critical-path length/Fmax (§8) — needs synthesis (even an open-source Yosys+nextpnr flow would do for a first estimate).
4. Whether `InstructionMemory`'s `$readmemb` path (`C:/Users/samar/Downloads/TEST_INSTRUCTIONS.dat`, hardcoded, machine-specific) even allows the existing testbench to run in this environment — almost certainly not, since that path doesn't exist here. **This blocks all other verification work until fixed or parameterized.**

## 14. Testbench assessment (historical — `simulation/` since removed)

`simulation/riscvpipeline_tb.v` was, at the time of this original audit, a **waveform-dump-and-inspect** testbench: it drove reset, poked `sp` directly into the register file array (a simulation-only backdoor, fine for bring-up, not representative of real boot), ran for a fixed 3000-time-unit window, and dumped a VCD. There were no assertions, no expected-result checks, no pass/fail output, no coverage collection, and (per point 13.4) it couldn't even load a program on a machine other than its original author's.

That was the correct **starting point** for Phase 3, not a criticism of what existed — a waveform-dump testbench is a completely normal first artifact for a student pipeline project. It has since been entirely superseded by the `sim/` self-checking harness this audit's own findings motivated (`sim/run_tests.sh`, directed programs, assertions, random cross-checking, coverage — see §15's Phase 3 row), and the `simulation/` directory (which had become dead weight: unreferenced by any tooling, containing a stray empty file alongside the one testbench) was removed once that superseding work was complete rather than kept around as an unused historical artifact.

## 15. Readiness vs. the ten requested phases

| Phase | Current readiness |
|---|---|
| 1. Audit | This document. Done. |
| 2. Code quality | Latch risk, hardcoded instruction-memory path, defs package, `default_nettype none` (which found 3 genuinely undeclared wires, `docs/adr/0008`), dead-field removal, and `reg1`/`reg2` dedup are all done. Real Verible lint config (CQ-5) is the only item still open. |
| 3. Verification | Substantially complete. Self-checking directed suite (`sim/run_tests.sh`, 22 programs / 122 checks, including 5 CSR/exception tests and a standalone `DataMemoryBRAM` unit test), 4 embedded assertions (`docs/adr/0007`), an independent reference-model ISS (`sim/tools/iss.py`, now covering CSR/`ecall`/`ebreak`/`mret`) cross-checked against constrained-random programs (`docs/adr/0010`), and functional coverage (`sim/tools/coverage_report.py`). Found and fixed 8 real bugs total (see errata above plus the shift-mask bug from V-4). Remaining gaps: `blt`/`bge`/`ble`/`bgt`/`bltu`/`bgeu` each still missing directed coverage of one branch direction; `ALUCTL_ILLEGAL` (a recognized opcode with an unrecognized funct7/funct3, as opposed to `illegalOpcode`'s unrecognized-opcode case) has no directed test yet (both documented, lower priority). |
| 4. Visualization | First version done: `sim/tb/gen_trace.v` + `sim/tools/gen_trace.py`/`build_viewer.py` produce an interactive, playable pipeline-occupancy viewer from a real execution trace (`make viewer`). Multi-program comparison and VCD export still open. |
| 5. Extensions (RV32M/CSR/caches/prediction/etc.) | RV32I completeness (5.1, `docs/adr/0005`), RV32M (5.2, `docs/adr/0006` + `0009`), and CSR/M-mode synchronous exceptions (5.3, `docs/adr/0011`) all done. RV32M includes a real multi-cycle divider (`design/Divider.v`) with a genuine pipeline interlock — the project's first multi-cycle-execute mechanism, whose stall/redirect shape CSR/exceptions reused directly. Caches/branch prediction/interrupts not started (the last needs a hardware interrupt source this design doesn't have — see `docs/adr/0011`'s Future improvements). |
| 6. Research platform (pluggable subsystems) | Not started; memory sizes are now parameterized (`docs/adr/0012`), but the architectural register file/pipeline register widths still aren't — the rest of the §12 parameterization work is still required. |
| 7. FPGA support | Scaffolding done (`docs/adr/0012`): memory sizes parameterized, a standalone unit-tested synchronous-read memory (`design/DataMemoryBRAM.v`, not yet wired in), a `debug_x10` observability port, a vendor-neutral bring-up top level (`fpga/top.v`), and a generic XDC constraints template. Still blocked on the actual MEM-stage retiming to integrate synchronous-read memory into the live pipeline, and completely unverified on real hardware. |
| 8. Tooling | `sim/tools/asm.py` (assembler, now with CSR/`ecall`/`ebreak`/`mret` encoding and a raw `word` directive) and `sim/tb/trace_debug.v` (ad hoc cycle trace) exist as early building blocks; not yet the dedicated profiler/debugger/trace-explorer tooling Phase 8 describes. |
| 9. Documentation | This document, `docs/ROADMAP.md`, and 12 ADRs (`docs/adr/`) as of this update. |
| 10. Benchmarking | Not started; ISA is now complete enough to be a meaningful benchmarking target, but no benchmark suite exists yet. |

Git repository initialized and committed as of this update (see commit history).
