# Handoff

Read this first in a new conversation on this repo. It's a map, not a
duplicate of the real docs — follow the pointers for depth.

## What this is

A synthesizable RV32I+M RISC-V 5-stage pipeline in Verilog
(`design/riscvpipeline.v` is the top-level `PIPELINED` module), built up from
a basic student pipeline project into a verified, documented core with a
real verification harness, machine-mode CSRs/exceptions, and FPGA bring-up
scaffolding. Every non-trivial design decision and every real bug found
along the way is written up in `docs/adr/0001` through `0015` — those are
the actual source of truth for *why* things are the way they are. This file
just orients you fast; `docs/ARCHITECTURE.md` (full technical audit,
updated incrementally) and `docs/ROADMAP.md` (phased backlog + status log)
are the next things to read after this.

## Current state (verify, don't trust — see commands below)

- RV32I base + RV32M (`mul`/`div`/`rem` etc., real multi-cycle divider) +
  M-mode CSRs/synchronous exceptions (`csrrw`/`csrrs`/`csrrc`(+`i`),
  `ecall`/`ebreak` traps, `mret`). Only `fence` (a no-op here — no cache,
  no multi-hart) and real interrupts (no hardware IRQ source exists) are
  unimplemented, both intentionally.
- **25/25 directed tests, 136/136 checks passing** (`sim/run_tests.sh` /
  `make test`), plus constrained-random cross-checking (now including CSR
  instructions) against an independent reference-model ISS (`sim/tools/iss.py`,
  `make random-test`), 4 embedded RTL assertions, and functional coverage
  (`make coverage`) confirming every branch direction and `ALUCTL_ILLEGAL`
  are exercised.
- FPGA readiness: memory sizes parameterized, a `debug_x10` observability
  port, `fpga/top.v`, `fpga/constraints_template.xdc`. The synchronous-read
  memory (`design/DataMemoryBRAM.v`) is **wired into the live pipeline**
  (`docs/adr/0013`), replacing the old combinational-read `DataMemory.v`
  (deleted) — a `mem_stall` interlock in `riscvpipeline.v` holds
  `reg2`/`reg3`/`reg4` for the one extra cycle a load's registered read
  needs; no changes were needed to `Hazard.v`/`Forward.v`. Nothing has
  touched real hardware yet — that's the one remaining Phase 7 item.
- `docs/adr/0013` and `0014` between them found and fixed four real
  interlock/reset bugs while wiring the synchronous memory in and then
  extending random testing to CSR instructions — see "Lessons" below before
  touching `mem_stall`/`reg2_hold`/CSR.v/reset values again.
- Phase 6's entry point is done (`docs/adr/0015`): the register file and
  every pipeline register's data/register-address widths are now `XLEN`/
  `NUM_REGS` parameters (default 32/32) instead of scattered literals —
  named, not truly variable at other values for this ISA (see the ADR).
  `design/Register.v`'s old `// Do not modify this file!` header is gone
  (confirmed stale template leftover with the user before removing it).
- Git repo, all on `master`, no remote — run `git log --oneline | head -20`
  for the current commit count/truth rather than trusting a number here.

## Verify the state yourself (don't take the above on faith)

```
cd c:/Python/5-stage-pipelined-processor-main
bash sim/run_tests.sh /c/iverilog/bin      # directed suite; expect NN/NN passed
python sim/tools/run_random_tests.py --count 30 --iverilog-dir /c/iverilog/bin
git log --oneline | head -20
```

**Windows/environment gotchas** (all cost real time to rediscover once
already, so don't):
- Icarus Verilog lives at `C:\iverilog\bin`, not on PATH by default. Pass it
  explicitly: `sim/run_tests.sh /c/iverilog/bin` (Git Bash path form) or
  `run_random_tests.py --iverilog-dir /c/iverilog/bin`. If it looks
  "already installed" but files are missing, reinstall with
  `winget install --id Icarus.Verilog -e --silent --force --accept-package-agreements --accept-source-agreements`.
- Git Bash's `/tmp` is not a real Windows temp dir for native-Windows Python
  subprocess calls. Use the session's actual scratchpad path, or a Windows-
  style path passed directly to `subprocess` (not relying on PATH search —
  call the `.exe` directly).
- This repo's line endings are LF; `git add`/`commit` on Windows will warn
  about LF→CRLF conversion. Harmless, ignore it.

## Repository map

```
design/           RTL. riscvpipeline.v is the top-level PIPELINED module —
                   read it first, it instantiates everything else and is
                   the map of how stages connect.
sim/programs/*.s   Hand-written directed test programs (custom asm, see
                   sim/tools/asm.py's header for the exact dialect).
sim/tb/tb_*.v      One self-checking testbench per program, same basename.
                   Auto-discovered by sim/run_tests.sh (glob), no registry
                   to update when adding one.
sim/tools/asm.py   The assembler (this core's specific ISA subset + a couple
                   of custom instructions — not a general RV32I assembler).
sim/tools/iss.py   Independent reference-model simulator, used for
                   constrained-random cross-checking. Deliberately NOT
                   sharing code with asm.py's encoding tables or the RTL —
                   the whole point is to catch disagreements.
sim/tools/random_gen.py   Constrained-random program generator (forward-only
                   control flow, reserved base pointer — see its docstring).
docs/ARCHITECTURE.md   Full technical audit, with an Errata section at the
                   top listing every real bug found by verification.
docs/ROADMAP.md    Phased backlog (Phase 1-10) with a status log at the
                   bottom — read the last few "Status update" paragraphs for
                   the most recent narrative of what happened and why.
docs/adr/000N-*.md One ADR per non-trivial decision or bug fix. Numbered,
                   chronological. This is where the actual engineering
                   reasoning lives — ARCHITECTURE.md/ROADMAP.md summarize,
                   ADRs explain.
fpga/              Bring-up wrapper/constraints, not yet hardware-tested (the
                   RTL it targets is fully integrated as of docs/adr/0013).
                   See docs/adr/0012, 0013, 0014.
```

## How the project got here (brief — ADRs have the real detail)

Started as a basic 5-stage pipeline student project (all R/I/L/S/B-type
instructions, forwarding, hazard detection) with no verification, a
hardcoded machine-specific instruction-memory path, and several latent RTL
bugs. Rebuilt incrementally, in this order (each is a real commit + ADR):

1. **Phase 1 audit** (`docs/ARCHITECTURE.md`'s baseline) + P0 fixes
   (hardcoded path, latch risk) + a self-checking verification harness from
   scratch (there was none).
2. **RV32I completeness**: `jalr`/`lui`/`auipc`/`bltu`/`bgeu`/byte-halfword
   memory (`0005`). Found real bugs along the way (`0002`-`0004`).
3. **Pipeline visualizer** (`236780b`, no dedicated ADR — see Phase 4 in
   ROADMAP).
4. **RV32M**, first single-cycle (`0006`), then a real multi-cycle divider
   with a genuine pipeline interlock (`0009`) — this established the
   "multi-cycle EX" pattern (freeze PC/IF-ID, hold ID/EX, bubble-then-latch
   EX/MEM) that CSR/exceptions later reused directly for trap redirects.
5. **Verification depth**: embedded assertions (`0007`), code-quality
   cleanup (`0008`), constrained-random cross-checking + functional
   coverage against an independent ISS (`0010`).
6. **CSR + M-mode synchronous exceptions** (`0011`) — the last real ISA-
   completeness gap. Found a nasty X-propagation bug here (see "Lessons"
   below).
7. **FPGA readiness scaffolding** (`0012`) — parameterization, a standalone
   synchronous-read memory building block, a bring-up top level. The actual
   pipeline retiming to integrate it was deliberately deferred at this point.
8. **Cruft cleanup**: removed a stale `simulation/` directory (fully
   superseded by `sim/`) and several leftover dead-code fragments across
   `design/*.v` (commented-out code from early drafts, a hardcoded path in
   a comment, unused wire declarations) that had survived every prior pass
   because nothing ever exercised or grepped for them specifically.
9. **MEM-stage retiming** (`0013`) — the deferred item from step 7. Wired
   `design/DataMemoryBRAM.v` (synchronous read) into the live pipeline in
   place of the old combinational-read `DataMemory.v` (deleted, fully
   superseded), with a new `mem_stall` interlock holding `reg2`/`reg3`/`reg4`
   for the one extra cycle a load's registered read now needs. Found and
   fixed two real interlock bugs along the way (see "Lessons" below);
   `Hazard.v`/`Forward.v` needed no changes at all.
10. **Closing the last verification gaps** (`0014`) — directed coverage for
    the one missing branch direction on six branch types and for
    `ALUCTL_ILLEGAL`, plus extending `random_gen.py` to generate CSR
    instructions (deliberately not `ecall`/`ebreak`/`mret`/illegal-control-
    flow, see the ADR for why). The CSR-generation work found two more real
    bugs: `CSR.v` double-applying writes when `reg2` is held behind an
    unrelated `mem_stall`, and `reg1.v`'s reset value for `inst_regfd`
    (a literal `0`, decoding as a real illegal-instruction trap since
    `docs/adr/0011`) corrupting `mcause`/`mepc` for one cycle at every
    simulation's start.
11. **Phase 6 parameterization** (`0015`) — `XLEN`/`NUM_REGS` threaded
    through ~15 files, replacing scattered `32`/`[31:0]`/`[4:0]` literals.
    Found and fixed one real latent bug: `x2`/`sp`'s reset value was
    hardcoded independently of `MEM_SIZE_BYTES` instead of wired to it.
    `Register.v`'s stale "do not modify" header removed (confirmed with the
    user first). Named parameters, not truly variable at other values —
    RV32I's own encoding fixes a 32-bit instruction word and 5-bit register
    fields regardless.
12. **Phase 8 tooling**: `sim/tools/debugger.py`, an interactive step
    debugger built on `sim/tools/iss.py` (instant stepping, architectural
    state only — not cycle-accurate pipeline timing, that's still
    `build_viewer.py`'s job). Extracted a shared `sim/tools/disasm.py` out
    of `gen_trace.py` along the way, fixing a real latent bug: the old
    disassembler only checked instruction bit 30, so every RV32M
    instruction silently misdisassembled as `add`/`sll`/etc. in the
    pipeline viewer. Pure tooling, no ADR (see ROADMAP's own rule for that).

## Lessons worth not re-learning

- **This codebase's verification standard**: every claim gets checked by
  actually running Icarus Verilog, not just read/reasoned about statically.
  Every non-trivial change gets an ADR (Problem → Design → real bugs found
  during verification, if any → Alternatives considered → Validation
  strategy → Future improvements). Every coherent increment gets committed
  separately with a descriptive message. This isn't a style preference to
  rediscover each session — it's the established, working pattern.
- **Whole-vector connections hide index-range bugs.** `riscvpipeline.v` had
  `wire [14:12] funct3_regde;` (should've been `[2:0]`) for who knows how
  long — invisible because every use connected/indexed the *whole* 3-bit
  vector by position, and Verilog doesn't care about declared index labels
  for that. The CSR work's `funct3_regde[2]`/`funct3_regde[1:0]` bit-selects
  were the first code to actually slice into it, and out-of-range bit-
  selects silently read as `X` rather than erroring. If you're adding new
  bit-selects into an existing signal, sanity-check its declared range
  first, especially in this file — `docs/adr/0011` has the full story and
  §12 of ARCHITECTURE.md flags it as worth a broader grep that hasn't been
  done yet.
- **Verilog testbench stimulus needs nonblocking assignment.** Driving DUT
  inputs with blocking assignment (`=`) immediately after `@(posedge clk)`
  races the DUT's own posedge-triggered read of those same signals. Always
  use `<=` for stimulus in a task, even though it doesn't matter
  semantically the way it does for synthesis. Bit us once in
  `tb_divider_unit.v` (`docs/adr/0009`).
- **Positional module instantiation is fragile.** Adding `debug_x10` as a
  new trailing output port on `PIPELINED` broke all 23 `dut(clk, start);`
  positional instantiations (Icarus requires an exact port-count match).
  Fixed by converting everything to named connections
  (`dut(.clk(clk), .start(start))`), which is now the convention going
  forward — use it for any new instantiation, not just when a port list is
  actively changing.
- **Any program that runs off the end of instruction memory now traps.**
  Since `docs/adr/0011`, opcode `0000000` (instruction memory's zero-filled
  remainder) is a real illegal-instruction trap, not a harmless implicit
  NOP. Every test program (directed and randomly generated) must end in a
  deliberate `jal x0, <self>` spin loop. If you write a new `.s` test
  program and it doesn't end that way, it will silently corrupt itself by
  looping back to address 0 mid-test — this exact failure mode ate real
  debugging time once already (see `docs/adr/0011`'s "A real bug found
  during verification").
- **A bare "was X requested last cycle" level signal can't tell a repeated
  request from a new one that looks the same.** Bit us three times now in
  the same shape: `docs/adr/0009`'s divider re-triggered a bogus second
  division because `start && !busy` looked identical on the done cycle and
  the next idle cycle; `docs/adr/0013`'s first MEM-stage interlock attempt
  derived readiness from `DataMemoryBRAM`'s own registered "read happened"
  signal, which broke on back-to-back loads for the identical reason (a
  load held for its stall cycle keeps `memRead` asserted for 2 cycles, so
  the *next* load's first cycle looks like the previous one's completion);
  `docs/adr/0014` hit it a third time when `CSR.v`'s write/trap/`mret`
  inputs, wired directly to combinational EX-stage signals, double-applied
  their effect for every cycle `reg2` was held behind an unrelated
  `mem_stall`. When gating on "did an in-flight operation finish" *or*
  "should this side effect fire," track it against the *consumer's*
  occupancy/hold state, not a raw combinational level from the thing being
  waited on or the instruction causing it — grep for any other module wired
  the same way (a combinational EX-stage signal driving an external
  stateful module's write) before adding the next hold/interlock mechanism.
- **Reset values need to be "obviously inert," not just zero.** `reg1.v`'s
  squash path already knew to reset `inst_regfd` to `32'h00000013` (a real
  `nop`), not `0` — because opcode `0000000` has been a genuine illegal-
  instruction trap since `docs/adr/0011`. Its *reset* path used a literal
  `0` anyway, meaning every simulation spent its first post-reset cycle
  presenting what `Control.v` correctly reads as an illegal instruction,
  silently corrupting `mcause`/`mepc`. Invisible for a long time because
  every existing test overwrites those CSRs with a deliberate real trap
  before ever checking them; only surfaced once `docs/adr/0014` made random
  testing read CSRs early. When a signal has more than one "not a real
  instruction yet" source (reset *and* squash here), make sure they agree
  on what that looks like, not just that each one individually seems safe.
- **A bubble is not always the right fix for "don't let a stalled register
  latch bad data" — sometimes it needs a real hold instead.** `docs/adr/0009`
  established feeding a zeroed bubble into the register just *after* a
  multi-cycle unit (bubble the control signals, not the data) as the
  pattern for that problem. `docs/adr/0013` copied that pattern one stage
  later (bubbling `reg4` during `mem_stall`) and it was wrong: unlike
  `reg3`, `reg4` is also the sole source of MEM/WB forwarding, and bubbling
  it evicts a real, still-needed forwardable result one cycle before some
  *unrelated* instruction riding out the same stall actually needs it. Only
  caught by constrained-random cross-checking, not any directed test —
  before reusing a "bubble vs. hold vs. freeze" pattern from an earlier ADR,
  check what else the target register is a source of, not just whether it
  looks structurally similar.
- **`dict.get(key, default)` in Python evaluates `default` eagerly.**
  `sim/tools/asm.py`'s CSR-address lookup originally did
  `CSR_ADDR.get(csr, int(csr, 0))`, which calls `int("mscratch", 0)` and
  raises even when `"mscratch"` *is* a valid key, because `.get`'s second
  argument is a normal function argument, evaluated unconditionally before
  the lookup happens. Fixed with an explicit `if key in dict` check
  (`csr_lookup()` in `asm.py`).

## What's genuinely not done (in rough priority order)

1. **Real hardware validation** — nothing in `fpga/` has touched an actual
   board. `fpga/constraints_template.xdc` is Xilinx/XDC-syntax only. This is
   the one remaining Phase 7 (FPGA) item; MEM-stage retiming (integrating
   `design/DataMemoryBRAM.v`) is done as of `docs/adr/0013`.
2. `random_gen.py` still doesn't generate `ecall`/`ebreak`/`mret`/
   deliberately-illegal-instruction control flow (deliberately scoped out
   of `docs/adr/0014` — see that ADR for why: needs real safety machinery
   an already-directed-tested area doesn't currently justify).
3. Phase 6 (research platform / pluggable subsystems): the named-
   parameterization prerequisite is done (`docs/adr/0015`), but the actual
   "pluggable subsystems" vision — swappable hazard strategies, variable
   pipeline depth — hasn't been started.
4. Phase 8 (tooling): interactive debugger now done (`sim/tools/debugger.py`);
   a dedicated profiler and benchmark runner are still open. Phase 10
   (benchmarking) not started.
5. Real Verilog lint (Verible) — CQ-5 in ROADMAP, still open; the closest
   thing today is `make lint` (just `iverilog -Wall`, catches syntax/width/
   latch issues, not a real style/lint pass).

## If you're picking this up cold

1. Run the verify commands above. Confirm the state matches this doc before
   trusting anything else in it — this file will drift out of date exactly
   like ARCHITECTURE.md/ROADMAP.md did before (both needed a "bring current"
   pass more than once this session).
2. Read the last few status-update paragraphs at the bottom of
   `docs/ROADMAP.md` for the most recent narrative.
3. Pick a "What's genuinely not done" item, or ask what's wanted — the
   project has generally been driven by "complete everything on the
   roadmap," but that's this session's instruction, not a standing default.
