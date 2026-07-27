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

- **CQ-1**: Add `riscv_defs.vh` — single source of truth for opcodes, ALUCtl encodings, funct3/funct7 values. Migrate `Control.v`, `ALUCtrl.v`, `ImmGen.v` to use it. Removes an entire class of copy-paste bugs and is a prerequisite for RV32M/CSR work (Phase 5) which will add opcodes to the same table.
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

Depends on V-1's execution trace format existing first. Once it does:
- **Viz-1**: Cycle-by-cycle pipeline occupancy table (which instruction is in which stage, stalls/bubbles marked) — a static HTML table generator is a half-day task and immediately useful for debugging V-2's directed tests.
- **Viz-2**: Interactive replay (scrub through cycles, see forwarding paths light up) — genuinely valuable but substantial front-end work; scope as its own project once Viz-1 proves the trace format is right.

## Phase 5 — ISA/architectural extensions

Ordered by how much they build on each other:
1. **ISA completeness first**: `jalr`, `lui`, `auipc`, `bltu`/`bgeu` (currently entirely missing, §11), byte/halfword loads-stores (needs `DataMemory.v` to gain funct3-aware access width, §9). This closes the actual RV32I base before adding extensions on top of an incomplete one.
2. **RV32M** (mul/div) — new opcode in `riscv_defs.vh` (CQ-1 dependency), new execute-stage unit, likely multi-cycle (division isn't single-cycle-friendly) which means this is also the project's first real excuse to design a stall/multi-cycle-execute mechanism generically instead of ad hoc.
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

**Status**: P0 and the core of V-1/V-2 are done (see above) — Icarus Verilog is now installed and on this machine, the suite runs via `sim/run_tests.sh` or `make test`, and it found and fixed 3 real RTL bugs plus completed `jal`. 8/8 tests, 36/36 checks passing as of this update.

**Recommended next milestone**: CQ-1 (`riscv_defs.vh`) before touching RV32M/CSR opcodes, since those add to the same magic-number tables `Control.v`/`ALUCtrl.v` currently hardcode — or, if the priority is finishing ISA completeness first, `jalr`/`lui`/`auipc`/byte-store (Phase 5.1) using the same assemble-a-directed-test workflow this session established. Either is a reasonable next step; genuinely a judgment call on what matters more right now, not something to guess at from the roadmap alone.
