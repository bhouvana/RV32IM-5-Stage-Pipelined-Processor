# ADR 0024: Variable-latency memory (Phase I)

## Problem

Phase G (caches) closed out at G10 (`docs/adr/0023-caches.md`). Per the Generation 1 scope decision
(`docs/ROADMAP_VISION.md`), the remaining Generation-1 items — variable-latency memory, HPC
performance-monitoring CSRs, a profiler, formal verification — are real, sequenced work, not deferred.
This is the first of them: independently configurable I-side and D-side wait-state cycles
(`MEM_LATENCY_I`/`MEM_LATENCY_D`), modeling that real memory doesn't respond in a fixed 0-or-1 cycles
the way `InstructionMemory.v`/`DataMemoryBRAM.v` do today.

Research (direct reads of `RamWishboneAdapter.v`, `DataMemoryBRAM.v`, `InstructionMemory.v`,
`WbDecoder.v`, `ICache.v`, and the existing `mem_stall`/`mem_access_ready`/`mem_trigger`/`lsu_ack`
machinery) found the real shape of the problem, narrower and safer than a generic "add a wait-state
model" task sounds:

- **D-side is already fully ack-driven.** `DCache.v`'s fill/writeback engine and `Ptw.v`'s walker both
  gate every bus step on `if (m_ack)` — no hardcoded cycle count anywhere. `riscvpipeline.v` even had a
  pre-existing comment on `lsu_ack`: "reserved for a future variable-latency-peripheral
  generalization... deliberately NOT consumed here" — this phase is that generalization, already
  anticipated.
- **But `mem_access_ready`'s `CACHE_MODE==CACHE_NONE` branch was hardcoded to `1'b1`**, not actually
  driven by `lsu_ack` — harmless before this phase only because `RamWishboneAdapter.v`'s real timing
  happened to always be exactly 1 cycle, which the hardcoded constant was silently calibrated to match.
- **`InstructionMemory.v` has no ack/handshake of any kind** — a flat combinational array read, no
  clock. Fetch under `CACHE_NONE` and `ICache.v`'s own internal fill engine both previously just trusted
  it was instant. Neither had any interlock to hang a wait-state model on — this was genuinely new
  machinery, not a rewire of existing ack-driven logic.
- **The ISS (`sim/tools/iss.py`) has no cycle model whatsoever** — confirmed directly (its own docstring
  says so; `load_mem_byte`/`store_mem_byte` are zero-cycle array accesses). A wait-state RAM model is
  timing-only by the same reasoning as branch prediction (`docs/adr/0021`) and caches (`docs/adr/0023`):
  it can only change *when* a value becomes visible, never *what* value it is. Zero ISS changes needed.

Scope confirmed with the user (`AskUserQuestion`, one question): **full I-side coverage** — instruction
fetch gets real wait-states even under `CACHE_NONE` (the harder, more-ambitious option, consistent with
every prior phase's scoping pattern), not just the D-side/cache-fill paths that already had a handshake
to extend.

This made Phase I eight independently-verified steps (I1-I8). Unlike most prior phases, several of the
hardest bugs here were found only by *running*, not by hand-tracing up front — the interlock shapes
involved (a shared bus with three independent masters, each holding request signals for a real,
variable, multi-cycle duration) turned out to have failure modes that hand-tracing alone did not surface.

## Design

### New module: `design/MemoryLatencyModel.v`

A small, generic delay-line primitive, reusing the project's own established `start`/`busy`/`done`
one-shot contract (`Divider.v`/`Ptw.v`'s shape) rather than inventing a new interlock idiom:

```verilog
module MemoryLatencyModel #(
    parameter LATENCY = 0   // additional wait-state cycles; 0 = pure combinational passthrough
)(
    input  clk, input rst,
    input  start,   // pulse or level: begin a new LATENCY-cycle wait (ignored while busy)
    output busy,
    output done      // one-cycle pulse, LATENCY cycles after start (same cycle as start when LATENCY==0)
);
```

`LATENCY==0`: `done = start` combinationally, `busy` tied 0 — the bit-exact default every other axis in
this project already follows. `LATENCY>0`: a small down-counter, `start && !busy` loads it, decrements
each cycle, `done` pulses exactly once at zero. Standalone-first, its own testbench
(`sim/tb/tb_memory_latency_unit.v`, 20/20), covering `LATENCY=0/1/4`, back-to-back requests, and a
spurious `start` arriving mid-count (correctly ignored).

### D-side: address-tracked capture-and-delay wrapper around `RamWishboneAdapter`

New `PIPELINED` parameter `MEM_LATENCY_D` (default 0). `RamWishboneAdapter`'s own instantiation stays
**outside** any `generate` block deliberately — its hierarchical instance name (`dut.m_DataMemory`) is
depended on directly by `check_tasks.vh` and every dump template's memory-dump loop; nesting it inside a
`generate` block per-branch would rename that path and break dozens of existing tests. Instead, a
`generate if (MEM_LATENCY_D == 0)` block wraps only the *result*:

```verilog
wire is_new_request = wb_s_cyc[0] && wb_s_stb[0] &&
    (!req_active_r || wb_s_addr != req_addr_r || wb_s_we != req_we_r);
```

Track the (address, write-enable) of whatever request is currently being serviced; a live `cyc && stb`
whose (addr, we) differs from that (or arrives with nothing tracked) is a genuinely new request. The
request reaches `RamWishboneAdapter` **undelayed** — its own already-correct ack generation runs at its
natural timing, unchanged. On `is_new_request`, capture the first real ack/data it produces (one-shot,
`captured_this_req_r` guards against `ram_ack_raw` itself being a multi-cycle level while the real master
waits), and delay *exposing* that capture to the real master by `MEM_LATENCY_D` cycles via
`MemoryLatencyModel`, retriggered by the same `is_new_request` pulse. Because every D-side master (raw
LSU under `CACHE_NONE`, `DCache.v`'s fill/writeback engine, `Ptw.v`'s walker) already only reads
`lsu_ack` (`WbDecoder`'s `m_ack` mux output) — never a hardcoded cycle count — all three transparently
inherit the added latency with **zero changes to `WbDecoder.v`/`DCache.v`/`Ptw.v`**. UART/Timer slaves
are untouched — this models memory latency specifically, not peripheral latency.

Two narrow changes to the existing `mem_access_ready`/`mem_trigger` so the now-genuinely-variable
`lsu_ack` actually has an effect under `CACHE_NONE` (previously wired around entirely):

```verilog
wire mem_access_ready = (CACHE_MODE == CACHE_NONE) ? lsu_ack :
    (fence_pending_r ? dcache_flush_done : dcache_resp_ready);
wire mem_trigger = (CACHE_MODE == CACHE_NONE) ? (memRead_regem || (memWrite_regem && !lsu_ack)) :
    (memRead_regem || (memWrite_regem && !dcache_resp_ready) || fence_pending_r);
```

At `MEM_LATENCY_D==0`, `lsu_ack` pulses on the exact same cycle the old hardcoded-1 assumption already
matched — bit-exact by construction this time, not coincidence. The `CACHE_WRITEBACK_SETASSOC` branch is
untouched — `dcache_resp_ready`/`dcache_flush_done` already transparently reflect the added bus latency
through `DCache.v`'s own already-ack-driven FSM.

### I-side: `CACHE_NONE` — new interlock, `imem_wait`

New `PIPELINED` parameter `MEM_LATENCY_I` (default 0). Detects a fresh fetch address (`imem_phys_addr`
changed since the one last served — PC/`imem_phys_addr` are frozen by `pc_stall` throughout a wait, so no
repeat-while-waiting ambiguity is possible), gated on translation having resolved
(`!translate_enable || itlb_hit`, mirroring `icache_miss`'s own gate) and on
`!branch_taken && !redirect_squash_extend_r`. Folds into `pc_stall` and `reg2`'s `flush` alongside
`itlb_miss`/`dtlb_miss`/`icache_miss`, tied `1'b0` under `CACHE_WRITEBACK_SETASSOC` (that mode's I-side
latency is I4's job instead — a cache hit never touches memory at all).

### I-side: `ICache.v`'s own internal fill engine

New `ICache.v` parameter `MEM_LATENCY` (default 0), threaded from `PIPELINED`'s `MEM_LATENCY_I`. Unlike
the D-side, `ICache.v` is the sole consumer of its own private `InstructionMemory.v` instance — no shared
bus, no other master — so a plain single-outstanding `start`/`busy`/`done` timer suffices, retriggered
per word (`start = (state == S_FILL) && !busy`). `S_FILL`'s existing per-word capture/advance becomes
conditional on the timer's `done` instead of unconditional every cycle. Generate-gated on `MEM_LATENCY`
so `MEM_LATENCY==0` callers (the overwhelming majority of existing tests) never need
`MemoryLatencyModel.v` in their own include list.

## Real bugs found, caught by tracing and by running

Unlike most prior phases, several of these were found only after multiple wrong designs, not by
hand-tracing before writing RTL — this project's own "3+ fixes failed, question the architecture"
guidance (`superpowers:systematic-debugging`) was explicitly consulted partway through the D-side work
and judged not yet triggered, since each failed attempt genuinely narrowed the real mechanism rather than
just relocating the same symptom.

1. **D-side, attempt 1 — ack+data shift register (rejected).** Delaying just `RamWishboneAdapter`'s
   ack/data pair by a plain N-deep shift register broke `Ptw.v`'s own two-level walk: it holds `m_stb`
   continuously across its two separate, different-address reads (level1 then level0) without ever
   dropping it between them. `RamWishboneAdapter`'s ack is a LEVEL tied to however long `stb` stays
   asserted, so once a delayed ack made the real master wait longer, that level — echoed through a plain
   shift register — produced a stale tail from the first read bleeding into where the second read's real
   ack belonged. Observed directly: a real page fault, RTL reading the first level's stale PDE where the
   second level's real PTE should have been.
2. **D-side, attempt 2 — delay the request instead (also rejected).** Time-shifting the whole
   `cyc`/`stb`/`addr` waveform into `RamWishboneAdapter` hit the identical problem one layer down: the
   real master's own `stb` is ALSO held for the entire round trip now, so replaying that whole held
   duration through the delay still produced multiple acks for what `DCache.v` treats as one logical,
   `m_ack`-gated request per word — confirmed by reading `DCache.v`'s own `S_FILL`/`S_WB` states directly
   (`if (m_ack) ... else fill_word_r <= fill_word_r + 1`), which does NOT free-run one word per cycle as
   first assumed; it waits for `m_ack` exactly like `Ptw.v` does between its two levels. A single `sw`
   under `CACHE_WRITEBACK_SETASSOC` hung forever, stuck on the fill/writeback's own first word.
   (A secondary bug surfaced and was fixed mid-attempt-2 before the whole approach was abandoned:
   nesting `RamWishboneAdapter`'s own instantiation inside a `generate` block renamed
   `dut.m_DataMemory`'s hierarchical path per-branch, breaking `check_tasks.vh` and every dump template —
   fixed by keeping the instantiation unconditional and muxing only its inputs, which is also how the
   final design is structured.)
3. **D-side, attempt 3 — the actual fix.** Address-tracked capture-and-delay (see Design section above).
   Correctly handles a single discrete request, a continuous one-word-per-cycle burst, and back-to-back
   distinct transactions uniformly, since it tracks the real distinguishing signal (address/we change)
   rather than the ack line's own level, which never cleanly pulses once between held sub-requests for
   any of the three masters.
4. **I-side, finding 1 — output masking, not just trigger masking.** Gating only `imem_latency_start` on
   `!branch_taken` wasn't enough: a wait that had already started for an older, about-to-be-squashed
   fetch kept the wait signal asserted through the exact cycle a younger instruction's redirect resolved
   — the same `PC.v` stall-over-redirect priority bug `docs/adr/0016`/`0022`/`0023` had each already found
   once, a fourth occurrence. Fixed by masking the whole exposed `imem_wait` signal on every redirect
   cycle, matching exactly how `itlb_miss`/`icache_miss` are themselves defined (not just their trigger).
   Also added `imem_abandoned_r` (mirrors `docs/adr/0022` Finding 3's `ptw_abandoned_r`): once a wait is
   abandoned mid-flight, its eventual completion must not mark the abandoned address "already served"
   using `imem_phys_addr`, which has since moved on to the redirect target.
5. **I-side, finding 2 — the one-cycle registered-gap bug (the deepest one).** Gating `pc_stall` through
   a *registered* wait signal (as the finding-1 fix still did) left a one-cycle gap between the wait
   starting (combinational) and `pc_stall` actually freezing `reg1` (one cycle later, once the register
   caught up). `InstructionMemory.v` is purely combinational — `inst` is already valid the exact cycle a
   new address appears — so during that one free cycle, `reg1` (not yet stalled) legitimately latched the
   real instruction and it advanced into `reg2` completely normally. Only then did the artificial wait
   catch up and start masking `pc_stall` for an address already correctly fetched — `reg2` spent the rest
   of the (now-pointless) wait being bubbled, discarding an instruction that was never actually stale
   (unlike `itlb_miss`/`icache_miss`, purely combinational with no such lag, so `reg1` genuinely never
   latches anything during their own stalls). Only ever exposed under `BRANCH_PREDICTOR=1`: a
   correctly-predicted self-looping `jal` (a real halt-loop instruction) got bubbled away one cycle after
   being correctly decoded, then re-fetched with a stale BTB prediction (`predict_taken_regde` still `1`
   from the earlier, since-discarded decode), computing `mispredict=1` against a now-zeroed
   `desired_taken` and taking the fallthrough-PC arm of `branch_or_jump_target` instead of the real
   self-loop target — running the CPU off the end of the program into zero-filled memory, an illegal-
   instruction trap to `mtvec=0`, and an infinite restart loop. Fixed by gating on the combinational
   `imem_latency_start || imem_latency_busy` pair directly instead of the registered wait signal.
6. **I-side, finding 3 — the retrigger-gap bug.** Fixing finding 2 introduced a new, narrower gap:
   `imem_served_addr_r` (a registered bookkeeping update, only visible starting the cycle *after* `done`)
   hadn't caught up yet on the exact cycle `done` fires, while `MemoryLatencyModel`'s own `busy` had
   *already* cleared that same cycle (its `start && !busy` guard evaluates `busy_r`'s just-updated value).
   `imem_new_addr` was still true (stale `served_addr_r`) while `busy` was already false —
   `imem_latency_start` fired again on that exact cycle and restarted the whole wait for an address
   already served, silently doubling every wait's real duration (confirmed directly: a `MEM_LATENCY_I=3`
   wait was taking 8 real cycles instead of the expected 4). Fixed by excluding both `busy` and `done`
   from `imem_latency_start`'s own condition — the identical protection `MemoryLatencyModel`'s own
   internal `start && !busy` guard already gives itself, needed here too against this wire's downstream
   bookkeeping's own one-cycle registered lag.

## Alternatives considered

- **A single shared `MEM_LATENCY` for both I-side and D-side.** Rejected: the vision doc explicitly asks
  for independently "configurable I-mem/D-mem latency," and a real system's instruction and data paths
  can have genuinely different timing behind them.
- **Delaying `RamWishboneAdapter`'s ack/data on the way back (attempt 1) or delaying the whole request on
  the way in (attempt 2).** Both rejected after being built and found wrong by running — see Real bugs
  found, items 1-2.
- **A registered `imem_wait` signal for pc_stall (the finding-1 fix, before finding 2 was found).**
  Rejected once finding 2 was root-caused: the one-cycle registered lag it introduced is exactly what let
  a real instruction slip past `reg1` before the artificial stall caught up.
- **Building the I-side wait as a shared bus wrapper, matching the D-side's shape.** Rejected:
  `InstructionMemory.v` under `CACHE_NONE` and inside `ICache.v`'s own fill engine are each the sole
  consumer of their own target (confirmed by `docs/adr/0023`'s own research finding, reused here) — no
  shared-bus arbitration complexity to account for, so a simpler single-outstanding timer is correct and
  sufficient for both, unlike the D-side's genuinely multi-master bus.

## Validation strategy

Every step ended with the full suite passing again before moving to the next:

- **Standalone unit test**: `sim/tb/tb_memory_latency_unit.v` (I1), `LATENCY=0/1/4`, back-to-back
  requests, a spurious mid-count `start` correctly ignored — 20/20.
- **`MEM_LATENCY_D` directed test**: `sim/tb/tb_mem_latency_d_i2.v`, a store-then-load sequence under both
  `CACHE_MODE` values, confirming real multi-cycle stalls occur (measured directly via a testbench-side
  `mem_stall` run-length counter) and produce correct data, including a full fence-flush-then-check
  round trip under `CACHE_WRITEBACK_SETASSOC` proving `DCache.v`'s fill/writeback engine inherited the
  delay transparently. Verified at `MEM_LATENCY_D=1` specifically (the tightest timing case) as well as
  `=3`.
- **`MEM_LATENCY_I` directed test**: `sim/tb/tb_mem_latency_i3.v`, several sequential fetches plus an
  unconditional jump under `CACHE_NONE`, confirming real multi-cycle `imem_wait` runs occur and that the
  jump's redirect isn't swallowed by an in-progress wait.
- **`ICache.v` fill-engine test**: a second, independently-reset small instance added to
  `sim/tb/tb_icache_unit.v` at `MEM_LATENCY>0`, confirming the fill still produces correct data and
  genuinely takes longer (not a silent no-op).
- **Constrained-random cross-check** (register AND memory-dump comparison) at every step, expanding
  coverage: both cache modes, MMU on/off, combined `MEM_LATENCY_I`+`MEM_LATENCY_D`, and finally the full
  cross product — `HAZARD_STRATEGY` × `PIPELINE_PROFILE` × `BRANCH_PREDICTOR` × `CACHE_MODE` × MMU × both
  latency axes simultaneously (I5), including the "everything at once" configuration. This full
  cross-product pass is specifically where findings 2 and 3 above were caught — neither showed up in any
  narrower sweep, confirming the value of running the complete cross product rather than only the axes
  believed relevant.
- **Zero-warning compile throughout**: `iverilog -Wall -g2005 -tnull design/*.v` stayed clean across every
  step.
- **Bit-exact default confirmed by construction and by running**: `MEM_LATENCY_I=0`/`MEM_LATENCY_D=0`
  reduce every new signal to its pre-Phase-I behavior; the full existing directed suite (68 tests) and
  the pre-existing random corpus are unaffected by construction.
- **Real, meaningful telemetry**: `bench_runner.py --compare-latency` at `MEM_LATENCY_I=D=3` shows
  ~3-4x more cycles across all three benchmark kernels (roughly matching one extra stall cycle per
  memory-bound instruction times both fetch and data access), confirmed not a silent no-op.

## Future improvements

- **A more realistic latency distribution** (e.g. a fixed-plus-random model, or burst-vs-random-access
  distinction), rather than a single configured constant per axis. Out of scope this phase — a fixed
  configurable wait-state count already satisfies the vision doc's own "configurable I-mem/D-mem
  latency" wording; a more elaborate model is future work if a real research use case needs it.
- **Peripheral (UART/Timer) latency.** Deliberately out of scope — this phase models memory latency
  specifically, per the vision doc's own item; peripheral timing is a separate, already-real-and-
  cycle-accurate concern (`design/Uart.v`'s own bit-shifted framing, `design/Timer.v`'s own
  `mtime`/`mtimecmp`), not something this phase's wrapper touches.
- **A unified delay-line abstraction for the D-side and I-side cases.** Considered and rejected as
  premature: the two use genuinely different underlying primitives (D-side: address-tracked
  capture-and-delay around a shared multi-master bus; I-side: a plain single-outstanding timer around a
  private, single-consumer target) for real structural reasons documented in Alternatives considered,
  not because unification wasn't tried.

## Closing out Phase I

Phase I (I1-I8) is done. `docs/ROADMAP.md`, `docs/ARCHITECTURE.md`, and `handoff.md` are updated by this
same commit to reflect its status. Generation 1's remaining new items (HPC performance CSRs, a profiler,
formal verification) remain to be sequenced next, per `docs/ROADMAP_VISION.md`.
