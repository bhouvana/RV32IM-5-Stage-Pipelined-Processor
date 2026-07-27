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
- **CQ-2**: Add `` `default_nettype none`` to every file. Fix whatever implicit-net warnings surface.
- **CQ-3**: Refactor `reg1.v`/`reg2.v` to eliminate the 3x-duplicated field-assignment arms (§12) — likely via a packed struct/typedef (requires moving to SystemVerilog, or a disciplined macro in plain Verilog).
- **CQ-4**: Remove dead fields `branch_regem`/`zero_regem`/`imm_sum_regem` from `reg3.v` (confirmed unused downstream, §3).
- **CQ-5**: Set up Verible (lint + format) and a `Makefile`/`justfile` with `make sim`, `make lint`, `make wave` targets. No CI without a git repo — see P0-adjacent infra item below.
- **Infra**: initialize git (`git init`), commit the current state as a baseline before any of the above land, so every subsequent change has a reviewable diff.

## Phase 3 — Verification (highest-leverage next investment)

- **V-1**: ✅ Done. Self-checking harness: `sim/tools/asm.py` (a small assembler for this core's exact instruction subset/encodings), `sim/tb/check_tasks.vh` (shared `check_reg`/`check_mem_word`/`report` tasks), `sim/run_tests.sh` (assembles + runs everything, PASS/FAIL summary, nonzero exit on failure). No reference-model/ISS comparison yet -- expected values are hand-computed per test, which doesn't scale past directed testing (see V-4).
- **V-2**: ✅ Directed suite covers: full R/I-type ALU op coverage + the custom `ctz` op (`arith.s`), EX/MEM forwarding (`forward_exmem.s`), MEM/WB forwarding (`forward_memwb.s`), load-use stall (`load_use_stall.s`), store/load round-trip (`store_load.s`), taken/not-taken branch (`branch_taken.s`/`branch_not_taken.s`), `jal` (`jal_test.s`). Not yet covered: `bne`/`blt`/`bge`/`ble`/`bgt` individually (only `beq` exercised so far), back-to-back branches, a branch immediately after a load-use stall, illegal-instruction behavior.
- **V-3**: Not started. Assertions (SVA if moving to SystemVerilog, or `` `ifdef ASSERT_ON`` Verilog-2001 style otherwise) for invariants already identified: `Forward.v`'s `forwardA/B` never equals `2'b11`, `x0` writes never actually change `regs[0]`, `Hazard.v`'s stall/flush are always equal, and (new, from `docs/adr/0003-...`) `readData2_regem` matches the forwarded value whenever `memWrite_regem` is set -- this last one would have caught the store-forwarding bug structurally instead of needing a directed test to stumble into it.
- **V-4**: Not started. Constrained-random instruction sequence generator, ideally cross-checked against a small reference ISS rather than hand-computed expected values (hand-computing doesn't scale, and is exactly how a wrong expected-value bug slipped into two of this session's own test files before being caught -- see the `branch_not_taken.s` and `tb_jal.v` fixes alongside the three RTL ADRs).
- **V-5**: Not started. Coverage collection (statement/branch coverage via Icarus+`covered`, or Verilator if the project moves that direction).

## Phase 4 — Visualization

- **Viz-1**: ✅ Done. `sim/tb/gen_trace.v` emits a per-cycle CSV straight off real DUT signals (PC/instruction per stage, stall/flush, branch resolution, forwarding selects, memory/writeback activity — nothing inferred). `sim/tools/gen_trace.py` disassembles the raw instruction words into real mnemonics and converts to JSON.
- **Viz-2**: ✅ Done (first version). `sim/tools/build_viewer.py` + `sim/tools/viewer_template.html` produce a self-contained interactive HTML pipeline viewer: play/step/scrub transport, a stage-occupancy timeline color-coded for stalls/squashes/branches/forwarding, a per-cycle stage-detail panel, and a 32-register heatmap reconstructed by replaying real WB-stage write events. `make viewer` (or the equivalent manual `iverilog`/`vvp`/`build_viewer.py` steps) regenerates it from any `sim/programs/*.s`.
- **Next**: multi-program comparison (run two programs side by side to compare e.g. hazard-heavy vs. hazard-free code), a full waveform/VCD export path for use in GTKWave alongside this tool, and wiring the viewer into `sim/run_tests.sh` so a failing directed test can auto-generate its own trace for debugging.

## Phase 5 — ISA/architectural extensions

Ordered by how much they build on each other:
1. **ISA completeness first**: ✅ Done (`docs/adr/0005-isa-completeness.md`). `jalr`, `lui`, `auipc`, `bltu`/`bgeu`, byte/halfword loads-stores all implemented and verified (4 new directed tests, 16 checks). Found and fixed a real bug along the way (`docs/adr/0004`: `slt`/`blt`/`bge`/`ble`/`bgt` were comparing unsigned). RV32I base is now complete except `fence`/`ecall`/`ebreak`/CSR (see item 3).
2. **RV32M** (mul/div) — ✅ Done, first version (`docs/adr/0006-rv32m.md`). All 8 ops implemented and verified, using Verilog's native `*`/`/`/`%` operators (single-cycle) rather than a real iterative multi-cycle divider -- deliberately deferred, see the ADR. Also widened `funct7` from 1 bit to the full 7-bit field (a prerequisite RV32M's opcode reuse needed, and now removes the same wall for any future R-type extension). **The real multi-cycle divider + generic multi-cycle-execute stall mechanism is now the next open item here.**
3. **CSR + machine mode + exceptions/interrupts** — largest single item in this list; touches fetch (illegal instruction), decode (CSR opcode), and adds real architectural state (`mcause`, `mepc`, etc.). Needs its own ADR and probably its own sub-roadmap.
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

**Status update**: RV32M (first version, single-cycle) is done. **13/13 tests, 67/67 checks passing.**

**Recommended next milestone**: the real multi-cycle divider + generic multi-cycle-execute stall mechanism (the item `docs/adr/0006` explicitly deferred) is the largest piece of unfinished RV32M work and a genuine microarchitecture milestone in its own right. V-3 (assertions) remains the other strong candidate: cheap to add now, and would have caught at least one of this session's bugs (the store-forwarding wiring mistake, `docs/adr/0003`) structurally rather than needing a directed test to stumble into it.
