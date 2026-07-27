# Roadmap

This backlog exists because "turn this into a comprehensive research platform" isn't a single task — it's a multi-year program. Treating it as one undifferentiated pile of work is how projects end up with ten half-finished subsystems and none of them trustworthy. Every item below is scoped to be independently reviewable, verifiable, and mergeable. Items are grouped by the phase they belong to (see [ARCHITECTURE.md](ARCHITECTURE.md) §15 for phase definitions) and ordered by dependency, not by phase number — several Phase-2/3 items block everything in Phases 4–10.

Each item that touches RTL or changes observable behavior should get a short ADR (`docs/adr/NNNN-title.md`) before implementation: **Problem, Background, Alternatives considered, Tradeoffs, Chosen solution, Expected impact, Validation strategy.** Purely additive documentation/tooling work doesn't need one.

## Sequencing logic

```
P0 fixes (correctness/portability) ─┬─→ Verification harness ─┬─→ Visualization
                                     │                          ├─→ Benchmarking
Code-quality pass (defs, dedup) ────┘                          └─→ Research-platform parameterization
                                                                        │
ISA completion (P1) ────────────────────────────────────────────────→ Extensions (RV32M/CSR/caches/...)
                                                                        │
                                                                        └─→ FPGA bring-up
```

Verification has to exist before visualization or benchmarking mean anything (you can't visualize or benchmark execution you haven't proven correct). ISA completion should land before layering RV32M/CSR/privilege on top of a base that's still missing `jalr`/`lui`/`auipc`/byte loads.

## P0 — Blocking correctness/portability fixes

These are bugs, not features. Small, independently mergeable, no ADR needed (each is a straightforward fix with one obviously-correct answer).

- **P0-1**: ✅ Done. `InstructionMemory.v` and the `PIPELINED` top module now take an `INIT_FILE` parameter (default `sim/programs/arith.mem`); no more hardcoded machine-specific path.
- **P0-2**: ✅ Done. `ImmGen.v`'s `always @*` block now defaults `imm = 0` before the `case`.
- **P0-3**: ✅ Done. `jal` fully wired (target, link value, EX/MEM forwarding correction). See `docs/adr/0001-jal-implementation.md`.
- **P0-4**: ✅ Confirmed by simulation (`sim/programs/branch_taken.s` / `branch_not_taken.s`): predict-not-taken, 2-cycle penalty on taken branches only, as §8 described.

Three more bugs surfaced *while building the verification harness* (P0-adjacent, found and fixed the same way): `ALU.v`'s broken `sra`, a register-file same-cycle write/read race (`docs/adr/0002-...`), and store data bypassing forwarding (`docs/adr/0003-...`). See `docs/ARCHITECTURE.md`'s errata section for the full list. This is the expected shape of doing verification work, not a sign the plan was wrong -- it's exactly why V-1/V-2 were sequenced ahead of everything else.

## Phase 2 — Code quality (foundation for everything else)

- **CQ-1**: ✅ Done. `design/riscv_defs.vh` centralizes opcodes/ALUOp/ALUCtl encodings; migrated into `Control.v`, `ALUCtrl.v`, `ALU.v` (`ImmGen.v` left as literals — already clearly per-case commented, not worth the churn). `sim/tools/asm.py` keeps an independent Python copy (can't `` `include`` a Verilog header) — still a known hand-sync gap.
- **CQ-2**: ✅ Done (`docs/adr/0008-code-quality-cleanup.md`). Added `` `default_nettype none`` to every design file. This wasn't a no-op: `stall`, `flush`, and `branch_zero` in `riscvpipeline.v` were genuinely undeclared, relying on implicit net declaration -- harmless in practice (always used consistently) but exactly the class of thing this guards against for the next typo. Fixed with explicit `wire` declarations.
- **CQ-3**: ✅ Done. `reg1.v` turned out not to need it (already minimal, 2 fields). `reg2.v`'s ~90 lines of repeated field-assignment arms reduced via Verilog-2001 text macros (`` `ZERO_CONTROL_FIELDS``/`` `ZERO_DECODE_CONTEXT``/`` `PASS_DECODE_CONTEXT``) rather than a SystemVerilog struct -- avoids a toolchain language-mode change for one file.
- **CQ-4**: ✅ Done. Removed `branch_regem`/`zero_regem`/`imm_sum_regem` from `reg3.v` (confirmed unused downstream) plus a second dead wire (`readData1_regem` in `riscvpipeline.v`, declared but never connected, predating this session) found during the same pass.
- **CQ-5**: Set up Verible (lint + format) and a `Makefile`/`justfile` with `make sim`, `make lint`, `make wave` targets. No CI without a git repo — see P0-adjacent infra item below.
- **Infra**: initialize git (`git init`), commit the current state as a baseline before any of the above land, so every subsequent change has a reviewable diff.

## Phase 3 — Verification (highest-leverage next investment)

- **V-1**: ✅ Done. Self-checking harness: `sim/tools/asm.py` (a small assembler for this core's exact instruction subset/encodings), `sim/tb/check_tasks.vh` (shared `check_reg`/`check_mem_word`/`report` tasks), `sim/run_tests.sh` (assembles + runs everything, PASS/FAIL summary, nonzero exit on failure). Directed tests still use hand-computed expected values; `sim/tools/iss.py` (V-4) is the reference-model comparison for random programs.
- **V-2**: ✅ Directed suite covers: full R/I-type ALU op coverage + the custom `ctz` op (`arith.s`), EX/MEM forwarding (`forward_exmem.s`), MEM/WB forwarding (`forward_memwb.s`), load-use stall (`load_use_stall.s`), store/load round-trip (`store_load.s`), taken/not-taken branch (`branch_taken.s`/`branch_not_taken.s`), `jal` (`jal_test.s`). Not yet covered: `bne`/`blt`/`bge`/`ble`/`bgt` individually (only `beq` exercised so far), back-to-back branches, a branch immediately after a load-use stall, illegal-instruction behavior.
- **V-3**: ✅ Done (`docs/adr/0007-assertions.md`). Four `` `ifdef ASSERT_ON``-guarded invariants embedded directly in the RTL (compiled out unless `-DASSERT_ON`, now default in `sim/run_tests.sh`): `Forward.v`'s `forwardA/B != 2'b11`, `Hazard.v`'s `stall === flush`, `Register.v`'s `x0` always reads 0, and `riscvpipeline.v`'s store-data-matches-forwarded-value check. Verified the last one actually catches the `docs/adr/0003` bug shape by deliberately reintroducing it and confirming the assertion fires on the first affected cycle.
- **V-4**: ✅ Done (`docs/adr/0010-random-testing-and-coverage.md`). `sim/tools/iss.py`, an independent reference-model interpreter of this core's ISA, cross-checked against 110 constrained-random programs via `sim/tools/random_gen.py`/`run_random_tests.py`. Found and fixed a real, previously-undocumented RTL bug: R-type `sll`/`srl`/`sra` used the full 32-bit shift-amount register instead of its low 5 bits (`design/ALU.v`), invisible to every hand-written directed test because none happened to use a shift-amount register holding >=32.
- **V-5**: ✅ Done, first version (same ADR). Functional coverage (not statement/branch -- no formal tool available): `` `ifdef COVERAGE``-guarded counters in `riscvpipeline.v`, aggregated by `sim/tools/coverage_report.py`. Found and closed a real gap (`bne` was never exercised by any directed test). `blt`/`bge`/`ble`/`bgt`/`bltu`/`bgeu` each still missing one direction (taken or not-taken) -- lower priority, left open, see the ADR.

## Phase 4 — Visualization

- **Viz-1**: ✅ Done. `sim/tb/gen_trace.v` emits a per-cycle CSV straight off real DUT signals (PC/instruction per stage, stall/flush, branch resolution, forwarding selects, memory/writeback activity — nothing inferred). `sim/tools/gen_trace.py` disassembles the raw instruction words into real mnemonics and converts to JSON.
- **Viz-2**: ✅ Done (first version). `sim/tools/build_viewer.py` + `sim/tools/viewer_template.html` produce a self-contained interactive HTML pipeline viewer: play/step/scrub transport, a stage-occupancy timeline color-coded for stalls/squashes/branches/forwarding, a per-cycle stage-detail panel, and a 32-register heatmap reconstructed by replaying real WB-stage write events. `make viewer` (or the equivalent manual `iverilog`/`vvp`/`build_viewer.py` steps) regenerates it from any `sim/programs/*.s`.
- **Next**: multi-program comparison (run two programs side by side to compare e.g. hazard-heavy vs. hazard-free code), a full waveform/VCD export path for use in GTKWave alongside this tool, and wiring the viewer into `sim/run_tests.sh` so a failing directed test can auto-generate its own trace for debugging.

## Phase 5 — ISA/architectural extensions

Ordered by how much they build on each other:
1. **ISA completeness first**: ✅ Done (`docs/adr/0005-isa-completeness.md`). `jalr`, `lui`, `auipc`, `bltu`/`bgeu`, byte/halfword loads-stores all implemented and verified (4 new directed tests, 16 checks). Found and fixed a real bug along the way (`docs/adr/0004`: `slt`/`blt`/`bge`/`ble`/`bgt` were comparing unsigned). RV32I base is now complete except `fence`/`ecall`/`ebreak`/CSR (see item 3).
2. **RV32M** (mul/div) — ✅ Done, including the real multi-cycle divider. First version (`docs/adr/0006-rv32m.md`) used Verilog's native `/`/`%` (single-cycle); `docs/adr/0009-multicycle-divider.md` replaced `div`/`divu`/`rem`/`remu` with a genuine 32-cycle iterative unit (`design/Divider.v`) plus a real pipeline interlock (PC/IF-ID freeze, ID/EX hold, EX/MEM bubble-then-latch) -- the project's first multi-cycle-execute mechanism. `mul`/`mulh`/`mulhsu`/`mulhu` stay single-cycle (a defensible simplification even for real hardware, unlike division). Also widened `funct7` from 1 bit to the full 7-bit field (a prerequisite RV32M's opcode reuse needed, and now removes the same wall for any future R-type extension).
3. **CSR + machine mode + exceptions** — ✅ Done (`docs/adr/0011-csr-and-exceptions.md`). New `design/CSR.v` register file (`mstatus`/`mtvec`/`mscratch`/`mepc`/`mcause`); `Control.v`/`ImmGen.v` decode `csrrw`/`csrrs`/`csrrc`(`+i`)/`ecall`/`ebreak`/`mret`; illegal instructions (both a fully unrecognized opcode and a recognized opcode with an unrecognized funct7/funct3) now trap instead of silently no-opping. Reused the `docs/adr/0009` redirect/squash machinery directly — exceptions and `mret` are just two more `unconditional_redirect` sources. Real interrupts explicitly out of scope: this design has no hardware interrupt source to drive them with.
4. Branch prediction (static, then BTB/dynamic), caches, MMU, dual-issue — genuinely research-scale items; each deserves to be evaluated on its own merits once the base core is verified and benchmarked, not bolted on speculatively. Listed here as backlog, not committed to.

## Phase 6 — Research platform (pluggable subsystems)

Requires CQ-1 (defs) and the parameterization cleanup noted in §12 (widths/depths as `parameter`, not literals) before "compare hazard strategies" or "compare pipeline depths" is even mechanically possible. Realistic entry point: parameterize `DataMemory`/`InstructionMemory` size first (low risk, immediately useful for larger test programs), then revisit.

## Phase 7 — FPGA support

Blocked on `DataMemory.v`'s combinational-read model (§9) — needs a synchronous-read variant to infer BRAM cleanly on Xilinx/Intel/Lattice toolchains. Do this after ISA completeness, not before, so the FPGA target isn't chasing a moving ISA.

## Phase 8 — Tooling

Instruction trace generator and binary loader are natural byproducts of V-1; the rest (profiler, interactive debugger, benchmark runner) are downstream of Phases 3–4 existing.

## Phase 9 — Documentation

This audit + this roadmap are the start. Grows incrementally alongside each phase above — resist writing documentation for subsystems that don't exist yet.

## Phase 10 — Benchmarking

Not meaningful until the core is ISA-complete (Phase 5.1) and verified (Phase 3). CoreMark/Dhrystone require a working C toolchain target (`lui`/`auipc` in particular are load-bearing for real compiled code, not just hand-written test programs) — this is a direct, concrete reason ISA completeness has to land before benchmarking claims mean anything.

---

**Status**: P0, CQ-1, V-1/V-2, Phase 5.1 (ISA completeness), and a first version of Phase 4 (visualization) are done. Icarus Verilog is installed on this machine, the suite runs via `sim/run_tests.sh` or `make test`, and it found and fixed 5 real RTL bugs (`docs/adr/0002-0004`) plus completed `jal`/`jalr`/`lui`/`auipc`/`bltu`/`bgeu`/byte-halfword memory (`docs/adr/0001`, `0005`). **12/12 tests, 50/50 checks passing** as of this update. RV32I base ISA is complete except fence/ecall/ebreak/CSR. An interactive pipeline viewer (`make viewer`) replays a real execution trace with stalls/squashes/forwarding/branches color-coded.

**Status update**: RV32M (including the real multi-cycle divider), V-3 (assertions), and CQ-2/3/4 (code quality) are all done. **15/15 tests, 84/84 checks passing** (13 pipeline directed tests + 1 standalone divider unit test + 1 forwarding-specific test), plus 4 embedded invariant assertions verified to actually catch what they're meant to. Found and fixed a real re-triggering bug in the divider's pipeline interlock during this work (`docs/adr/0009`) -- the kind of edge case multi-cycle interlocks are notorious for.

**Status update**: V-4 and V-5 are both done, including a real RTL bug found and fixed (`sll`/`srl`/`sra` shift-amount masking). **16/16 directed tests, 87/87 checks passing**, plus 110/110 random programs matching the independent ISS reference. Phase 3 (verification) is now substantially complete: self-checking harness, assertions, random cross-checking, and functional coverage all exist and all found real bugs.

**Status update**: CSR/exceptions (Phase 5 item 3) is done (`docs/adr/0011-csr-and-exceptions.md`) — `ecall`/`ebreak`/illegal-instruction traps, `mret` return, and all six `csrrX` forms against `mstatus`/`mtvec`/`mscratch`/`mepc`/`mcause`. Found and fixed a real X-propagation bug along the way: `funct3_regde` was declared with a source-bit-position-shaped range (`[14:12]`) instead of a plain width (`[2:0]`), invisible until CSR wiring became the first code to bit-select into it. **21/21 directed tests, 114/114 checks passing**, plus 60/60 random programs matching the independent ISS reference (now also modeling CSR/exception semantics, `sim/tools/iss.py`).

**Recommended next milestone**: FPGA readiness (Phase 7) is the largest remaining item — blocked on `DataMemory`'s combinational-read model needing a synchronous-read variant, plus a constraints template and top-level wrapper.
