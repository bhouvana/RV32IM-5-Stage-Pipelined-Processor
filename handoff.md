# Handoff

Read this first in a new conversation on this repo. It's a map, not a
duplicate of the real docs — follow the pointers for depth.

## What this is

A synthesizable RV32I+M RISC-V 5-stage pipeline in Verilog
(`design/riscvpipeline.v` is the top-level `PIPELINED` module), built up from
a basic student pipeline project into a verified, documented core with a
real verification harness, machine-mode CSRs/exceptions, and FPGA bring-up
scaffolding. Every non-trivial design decision and every real bug found
along the way is written up in `docs/adr/0001` through `0012` — those are
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
- **22/22 directed tests, 122/122 checks passing** (`sim/run_tests.sh` /
  `make test`), plus constrained-random cross-checking against an
  independent reference-model ISS (`sim/tools/iss.py`, `make random-test`),
  4 embedded RTL assertions, and functional coverage (`make coverage`).
- FPGA readiness is *scaffolding only*: parameterized memory sizes, a
  standalone unit-tested synchronous-read memory
  (`design/DataMemoryBRAM.v`, **not wired into the live pipeline**), a
  `debug_x10` observability port, `fpga/top.v`, `fpga/constraints_template.
  xdc`. Nothing has touched real hardware. See `docs/adr/0012` for exactly
  what's deferred and why.
- Git repo, 12 commits as of this writing, all on `master`. No remote.

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
fpga/              Bring-up scaffolding, not yet integrated or hardware-
                   tested. See docs/adr/0012.
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
   pipeline retiming to integrate it is explicitly deferred, not done.
8. **Cruft cleanup**: removed a stale `simulation/` directory (fully
   superseded by `sim/`) and several leftover dead-code fragments across
   `design/*.v` (commented-out code from early drafts, a hardcoded path in
   a comment, unused wire declarations) that had survived every prior pass
   because nothing ever exercised or grepped for them specifically.

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
- **`dict.get(key, default)` in Python evaluates `default` eagerly.**
  `sim/tools/asm.py`'s CSR-address lookup originally did
  `CSR_ADDR.get(csr, int(csr, 0))`, which calls `int("mscratch", 0)` and
  raises even when `"mscratch"` *is* a valid key, because `.get`'s second
  argument is a normal function argument, evaluated unconditionally before
  the lookup happens. Fixed with an explicit `if key in dict` check
  (`csr_lookup()` in `asm.py`).

## What's genuinely not done (in rough priority order)

1. **MEM-stage retiming** to actually integrate `design/DataMemoryBRAM.v`
   into the live pipeline (`Forward.v`/`Hazard.v` need a new forwarding
   source and a load-result stall, the way `docs/adr/0009` added one for
   div/rem). This is the real remaining Phase 7 (FPGA) work — scaffolding
   is done, this is not. Deserves its own ADR and dedicated verification
   pass, not a drive-by change.
2. **Real hardware validation** — nothing in `fpga/` has touched an actual
   board. `fpga/constraints_template.xdc` is Xilinx/XDC-syntax only.
3. Minor verification gaps, all documented in ARCHITECTURE.md §15 / ROADMAP
   status log: `blt`/`bge`/`ble`/`bgt`/`bltu`/`bgeu` each missing directed
   coverage of one branch direction; `ALUCTL_ILLEGAL` (recognized opcode,
   unrecognized funct7/funct3) has no directed test; `random_gen.py`
   doesn't generate CSR/exception instructions yet.
4. Phase 6 (research platform / pluggable subsystems): memory sizes are
   parameterized now, but the architectural register file and pipeline
   register widths are still fixed literals.
5. Phase 8 (tooling) and Phase 10 (benchmarking): both essentially not
   started beyond early building blocks (`asm.py`, `trace_debug.v`).
6. Real Verilog lint (Verible) — CQ-5 in ROADMAP, still open; the closest
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
