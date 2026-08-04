# ADR 0029: Generation 2 (RV64IMAF Processor v2.0) closes without riscv-arch-test integration

## Problem

Phase M (`docs/adr/0028-rv64-migration-phase-m.md`) delivered every item `docs/ROADMAP_VISION.md`'s
Generation 2 list names except one: "RISC-V compliance testing," explicitly deferred to a
separate later phase at Phase M's own scoping decision. The user then asked to complete the whole
of Generation 2, which meant attempting that last item: integrating the official
`riscv-non-isa/riscv-arch-test` suite.

## Research

Two real, independent blockers were found by direct investigation (cloning and reading the actual
repository, not assumed from prior knowledge):

1. **No local reference model.** Both generations of the test framework require running a golden
   reference model to compute each test's expected architectural state:
   - The current framework ("ACT4," replacing the deprecated `riscof` tool) bakes Sail-computed
     expected results directly into each self-checking ELF at generation time — confirmed by
     reading `README.md` and every `config/*/test_config.yaml` (including the `config/qemu/*`
     ones, which still name `sail_riscv_sim` as `ref_model_exe` — QEMU there is a DUT example, not
     a Sail replacement).
   - The older, `riscof`-based tag (`3.9.1`) ships only test *content*
     (`riscv-test-suite/`) — no `riscv-target/` plugin directory exists in that tag at all; `riscof`
     itself is a separate package, and its own reference plugins are conventionally Spike or Sail.
   - Neither Spike (`riscv-isa-sim`) nor Sail (`sail-riscv`) publishes an official Windows-native
     binary (`sail-riscv`'s own GitHub releases: Linux x86_64/aarch64 and Mac arm64 only, confirmed
     directly against the `0.13.1` release assets). This project's environment is native Windows
     (Git Bash/MSYS, not WSL) — a Linux ELF binary can't execute here directly. Building either
     from source needs a large toolchain neither present nor trivially installable here (Sail:
     OCaml/dune/zarith; Spike: autotools/DTC/a C++ build chain), on top of `make`/`bison`/`flex`
     already confirmed absent from this environment.
   - A real RISC-V GCC *is* obtainable here without a from-source build — the xPack project
     publishes a prebuilt Windows-native `riscv-none-elf-gcc` release — so the assembler/toolchain
     half of the problem is actually solvable. The reference-model half is not.

2. **This core's branch encoding is not spec-standard — found independent of the tooling
   question, and the more fundamental blocker of the two.** `design/riscv_defs.vh`/`ALUCtrl.v`
   place `blt`/`bge` at funct3 `010`/`011` and use the real spec's `100`/`101` slots (real spec:
   `blt`=100, `bge`=101, both reserved at 010/011) for this project's own custom `ble`/`bgt`
   instructions instead — a real, deliberate, and previously-documented deviation
   (`docs/ARCHITECTURE.md` sec 5), not a new bug. Official RISC-V architectural *compliance*
   testing is, by definition, a check of standard-encoding conformance: a real, spec-compliant
   GCC-compiled test binary's `blt`/`bge` instructions would be silently misdecoded as `ble`/`bgt`
   by this core. Even a fully working Sail/Spike-backed pipeline would not produce a meaningful
   "compliant" result against this encoding — the test binaries themselves assume standard
   positions this core doesn't implement.

## Decision

Confirmed with the user (`AskUserQuestion`, presented with the research above and four real
options — accept without it, hand-port a non-official subset, fix the branch encoding first as
its own prerequisite phase, or attempt a from-source Spike/Sail build anyway): **Generation 2
closes now, without official riscv-arch-test integration.** Every other Generation 2 item
(`docs/ROADMAP_VISION.md`) is done and verified: XLEN migration, register file, ALU, divider,
memory (`ld`/`sd`/`lwu`, alignment handling — unchanged from this core's own pre-existing
non-faulting byte-addressable design, which never enforced alignment at RV32 either), and
toolchain (assembler/ISS/debugger/visualizer/benchmarks all real, not stubbed). Differential
testing exists and is exercised continuously (`sim/tools/iss.py` cross-checked against the RTL,
195 XLEN=64 seeds plus 100 XLEN=32 seeds in Phase M's own final sweep alone).

**Release: RV64IMAF Processor v2.0.**

Compliance-suite integration remains real, open, documented backlog — not silently dropped. A
real attempt needs, in order: (1) a prerequisite decision on whether to fix the branch-encoding
deviation (a large, invasive change rippling through the RTL, `asm.py`/`iss.py`/`disasm.py`, every
existing directed test using `ble`/`bgt`, and several ADRs — its own phase, not a drive-by fix),
and (2) either a working local Sail/Spike build (uncertain on native Windows) or running the
generation/verification step on a different (Linux/WSL) environment entirely.

## Alternatives considered

- **Hand-port a representative compliance-style subset** in this project's own asm.py/iss.py
  style — real additional coverage value, considered and available as a future option, but not
  official spec conformance (can't be, given the encoding point above) and explicitly not chosen
  now (the user's own confirmed decision).
- **Attempt a from-source Spike or Sail build anyway** — rejected as high-risk/high-cost for
  uncertain payoff: likely multi-hour, uncertain success without WSL, and would still hit the
  branch-encoding blocker even if it worked.
