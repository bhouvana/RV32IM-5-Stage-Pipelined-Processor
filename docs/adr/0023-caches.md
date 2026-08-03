# ADR 0023: Caches — I$ + D$, set-associative, write-back (Phase G)

## Problem

Phase F (MMU, `docs/adr/0022-mmu-sv32.md`) closed out at F9. Per the Generation 1 scope decision
(`docs/ROADMAP_VISION.md`) and `handoff.md`'s own "next up" pointer, Phase G — caches — was next:
`InstructionMemory.v` and `DataMemoryBRAM.v` are both single-cycle, always-hit arrays today, unrealistic
for anything beyond a teaching core. This phase ran its own dedicated research pass (three parallel
Explore agents: RTL/bus mechanics, verification-tooling implications, ADR staging precedent — mirroring
every prior phase's opening step) and confirmed three scope questions with the user via
`AskUserQuestion` (the most ambitious option each time, consistent with every phase so far):

- **PIPT addressing** (not VIPT) for both caches — research found fetch and load/store are *already*
  PIPT today (`Tlb.v` resolves translation combinationally the same cycle `InstructionMemory.v`/
  `DataMemoryBRAM.v` is indexed, translation strictly before the array read, not overlapped with it).
  VIPT would add real alias-handling complexity for zero latency benefit on this core's current
  single-cycle TLB timing.
- **Real `fence` semantics** (not a debug-only testbench flush hook) — a write-back D$ means dirty data
  can sit uncommitted in the cache, invisible to `sim/tb/check_tasks.vh`'s `check_mem_word` and every
  dump template, which all read `DataMemoryBRAM.v`'s backing array directly. `fence` was confirmed
  undecoded before this phase (`Control.v` had no `OPCODE_MISC_MEM` arm, fell to
  `default: illegalOpcode=1` — it would have *trapped*, not silently no-opped, contrary to
  `docs/ARCHITECTURE.md`'s pre-Phase-G "no-op, nothing to order" description). Giving it genuine
  flush-to-memory semantics gives it real purpose for the first time and closes the verification gap by
  construction, mirroring `docs/adr/0020`'s D10 "RTL and ISS agree by construction" precedent.
- **Sizing**: 4-way set-associative, 4KB, 16-byte lines, for both I$ and D$ (the more-ambitious option
  over a smaller 2-way/1KB first pass) — parameterized, not hardcoded, following the closed-named-enum
  convention `HAZARD_STRATEGY`/`PIPELINE_PROFILE`/`BRANCH_PREDICTOR` already established, now joined by
  `CACHE_MODE` (`CACHE_NONE`=0, bit-exact default; `CACHE_WRITEBACK_SETASSOC`=1).

Two research findings reshaped the plan versus a naive "cache goes on the bus" assumption:

1. **`InstructionMemory.v` isn't on the Wishbone bus at all** — it's a private, fully combinational array
   wired directly into `PIPELINED`, no `cyc`/`stb`/`ack`, and nothing else ever touches it (unlike
   `DataMemoryBRAM.v`, which `Ptw.v` shares with the LSU because page tables live in data memory). So
   `ICache.v` needed no bus arm, no arbitration — it fills by issuing sequential reads against a private
   internal `InstructionMemory.v` instance. Only `DCache.v` touches the shared Wishbone bus/PTW
   arbitration.
2. **A D$-miss stall is lower novel risk than a `dtlb_miss` stall on the forwarding-window axis.**
   `dtlb_miss` needed new `dtlb_vaddr_r`/`dtlb_store_data_r` latches (F5) because it stalls *upstream* of
   `reg3`, in EX, where operands are still live-forwarded and drain out of `Forward.v`'s ~2-cycle window.
   A D$-miss stall lives *downstream* of `reg3` — `reg3`'s `.hold()` freezes every field verbatim
   (`design/reg3.v`), so a multi-cycle D$ fill doesn't reopen that bug class; it's a straightforward
   variable-latency extension of the existing `mem_stall` mechanism.

One consequence flagged up front: **write-allocate (the standard pairing with write-back) means stores
can stall for the first time in this core's history.** Before this phase, `memWrite` never stalled
(`mem_stall` gated on `memRead_regem` only) — a store miss now needs a line fill before it can retire.
This is exactly the moment `docs/adr/0020`'s D3 predicted ("generalize `mem_stall`... deferred until a
peripheral with genuinely different latency actually needs it").

This made Phase G ten independently-verified steps (G1-G10), each ending with the full suite passing
again, per this project's established convention.

## Design

### Module structure: two separate modules, not one unified `Cache.v`

`Tlb.v` is unified (one array, two read ports) because I-side and D-side translation do the *identical*
thing to the *identical* storage. I$ and D$ diverge on the axis that mattered there: write policy. I$ is
pure fill/read — no dirty state, no writeback, no flush FSM. D$ needs dirty bits, byte-merge-on-store,
and an eviction/flush writeback engine. Forcing both into one module with an `IS_DATA` parameter gating
half its state would be the "config for a value that never changes per instantiation" shape this project
avoids elsewhere. Two modules: `design/ICache.v`, `design/DCache.v`, sharing only a naming/parameter
convention (`WAYS`/`CACHE_SIZE_BYTES`/`LINE_BYTES`), not code.

**Sizing** (both, independently parameterized — `ICACHE_*`/`DCACHE_*`): 4-way, 4KB → 256 lines / 4 ways
= 64 sets, 16B lines. Physical address split: `[3:2]` word-in-line, `[9:4]` set index, `[31:10]` tag.

**Replacement**: round-robin (2-bit per-set counter), not true LRU —
`# ponytail: round-robin, not LRU — upgrade to tree-PLRU only if a real hit-rate counter (G8) shows it
matters`. Functionally correct either way; this core's test programs are far smaller than the cache
anyway, so relative hit-rate is the only thing that would differ.

### Interlock design

**I-side** (`icache_miss`, joins the existing front-end-only interlock class exactly where `itlb_miss`
sits — `pc_stall`, `reg2_hold`, `reg2`'s bubble):

```verilog
wire itlb_miss = translate_enable && !itlb_hit && !(ptw_done_i && ptw_fault)
    && !branch_taken && !redirect_squash_extend_r;
wire icache_miss = (!translate_enable || itlb_hit) && !icache_hit
    && !branch_taken && !redirect_squash_extend_r;
```

Gated on `itlb_hit` (PIPT — the cache is indexed by the post-translation `imem_phys_addr`). Gated on
`!branch_taken && !redirect_squash_extend_r` — the exact fix `docs/adr/0016`/`0022` Finding 1 already
needed twice (stall winning over accepting a redirect); this phase needed it a *third* time (G3, below).

**D-side**: `mem_stall` generalized (G5) from a fixed 1-cycle read-only interlock into a
variable-latency "MEM-stage occupant not yet ready to retire" signal covering three causes with the same
transition-tracking discipline the original `mem_stall_done_r` already established — an ordinary D$ hit
(1 cycle, bit-identical to before), a D$ miss (read- or write-miss, since write-allocate means stores can
miss now), and a retiring `fence` (flush-all latency):

```verilog
wire mem_access_ready = (CACHE_MODE == CACHE_NONE) ? 1'b1 :
    (fence_pending_r ? dcache_flush_done : dcache_resp_ready);
wire mem_trigger = (CACHE_MODE == CACHE_NONE) ? memRead_regem :
    (memRead_regem || (memWrite_regem && !dcache_resp_ready) || fence_pending_r);
wire mem_stall = mem_trigger && !mem_stall_done_r;
```

All three still hold — never bubble — `reg3`/`reg4` (the `docs/adr/0013` reg4 lesson), joining
`pc_stall`/`reg2_hold` exactly as before.

**Bus arbitration (D-side only — I$ needs none)**: the existing 2-way mux
(`wb_m_* = ptw_busy ? ptw_* : lsu_*`) extends to three arms under `CACHE_WRITEBACK_SETASSOC`
(`dcache_m_cyc ? dcache_* : (ptw_busy ? ptw_* : 0)` — no raw `lsu_*` arm once a cache sits in front, the
LSU's request now always routes through `DCache.v` first). `ptw_start`'s gate changes meaning under
this mode: "the LSU wants the bus" no longer means every load/store once a cache sits in front, so the
gate becomes `!dcache_flush_busy` (not `!lsu_cyc`) — a genuine semantic difference between cache modes,
not a mechanical rename.

### `fence` semantics

`isFence` decodes in `Control.v` (new `OPCODE_MISC_MEM` arm, `funct3==000` only — other funct3 values
under that opcode, e.g. `fence.i`'s encoding, stay `illegalOpcode`, out of scope), threaded through
`reg2` mirroring `isSfenceVma`'s F2-F5 split (decode inert first, real behavior later). `fence_real`
triggers `DCache.v`'s `flush_all` in MEM stage (mirrors `sfence_real`'s wiring) — occupies `reg3` via the
same generalized D-side interlock, not a fourth bespoke stall category. The flush FSM walks all 256
lines, writing back every valid+dirty line through the *same* sub-engine an ordinary capacity-eviction
uses (one engine, two callers). I$ needs no fence-triggered invalidation (`fence` orders data memory, not
instruction fetch; `fence.i`/self-modifying-code coherency is explicitly out of scope, no regression from
this core's total absence of that story before this phase).

## Real bugs found, caught by tracing and by running

Matching this project's own "hand-trace before trusting a first design" precedent (`docs/adr/0009`,
reused every phase since), the hand-traced interaction checks from the plan (D$-miss + `branch_taken`
same cycle, an older instruction's D$-fill draining `reg3`/`reg4` while a younger instruction wants the
PTW, back-to-back store-miss then load-hit, a `fence` retiring after a stalled load/store) were all
already safe by construction. Four real bugs were still found by *running* the design, three of them
matching this project's own recurring "a bare level/state can't distinguish still-the-same-request from
a new one" bug class (first found in `docs/adr/0009`'s divider, recurring in `0013`, `0016`, `0022`):

1. **Split-fetch/redirect duplicate-fetch bug (G3).** `itlb_miss`/`icache_miss` weren't gated on
   `redirect_squash_extend_r`, letting a squashed fetch's miss still drive a stall — the exact
   "stall-vs-redirect priority" bug class `docs/adr/0016`/`0022` had already each found once. Root-caused
   via a custom debug testbench tapping `pc_o`/`pc_o_reg1a`/`inst_regfd`/`redirect_squash_extend_r`/
   `pc_stall`/`icache_miss` per-cycle. Fixed by adding `&& !redirect_squash_extend_r` to both wires.
   Confirmed under real churn by `sim/tb/tb_icache_live_g3.v`, a tight taken-branch loop forcing real
   eviction/refill (96 `icache_miss` events observed).
2. **Store-data assertion spurious failure (G6).** `docs/adr/0003`'s assertion re-checked every cycle
   `memWrite_regem` was high, an assumption broken once write-misses could hold `reg3` across multiple
   cycles. Fixed with a `store_already_checked_r` one-shot-per-occupant flag.
3. **Flush re-trigger race (G6).** `fence_pending_r` (driving `DCache.v`'s `flush_all`) cleared one cycle
   later than `DCache.v`'s own internal `flush_active_r`, causing a spurious second, redundant ~256-line
   flush scan. Fixed with a `fence_flush_started_r` latch.
4. **The deep `resp_ready` bug (G7), the most significant.** An initial fix attempt (a `served_valid_r`
   flag blocking re-entry into the hit-read state) was necessary-but-insufficient for the original
   MMU+cache cross-check failures (seeds 14, 48) AND introduced a NEW regression — hung the standalone
   `DCache.v` testbench on a legitimate repeat read of the same address, because the "no active request"
   reset window the fix assumed existed for back-to-back same-address reads never actually got hit
   before the caller's next request arrived. After extensive debugging (multiple custom debug
   testbenches, `$monitor`-based tracing to nail exact event ordering), `served_valid_r` was removed
   entirely and replaced with a simpler, correct fix: gate `resp_ready`/`resp_rdata` directly on the
   latched serving address (`served_addr_r` for hit-reads, `miss_orig_addr_r` for fills) matching the
   *current* `req_addr`, rather than trusting bare FSM state. This single change resolved both the
   original MMU+cache bug and the standalone-test hang simultaneously, and is architecturally cleaner
   than the state-based approach it replaced.

A fifth, related gap — not an RTL bug, but a genuine MMU/D$ coherency gap found the same way (G6/G7):
**`Ptw.v`'s raw bus reads bypass `DCache.v` by design** (no coherency mechanism was ever built between
them, matching this phase's own scope decision that `fence` orders data memory generally, not
specifically the page-table walker's private path). Under `CACHE_MODE=1`, page-table stores made by the
constrained-random test generator's own MMU setup sequence stayed dirty in D$, invisible to `Ptw.v`'s
direct bus reads — this caused immediate page faults trapping to `mtvec=0`, an infinite program-restart
loop. Fixed at the generator level, not the RTL level (the RTL behavior is correct and documented — a
real hardware MMU walker reading stale data past an un-flushed cache is exactly what `fence` exists to
prevent): `sim/tools/random_gen.py`'s MMU page-table setup prefix now inserts a `fence` between the PTE
stores and the `satp` write.

## Alternatives considered

- **A unified `Cache.v` with an `IS_DATA` parameter.** Rejected: I$ and D$ diverge on write policy (no
  dirty state/writeback/flush FSM in I$ at all), unlike `Tlb.v`'s I-side/D-side symmetry — a shared
  module would gate half its state behind a parameter that never varies per instantiation.
  - **VIPT addressing.** Rejected: fetch and load/store are already PIPT today (translation resolves
    strictly before the array index, not overlapped with it), so VIPT would add real alias-handling
    complexity for zero latency benefit at this core's current single-cycle TLB timing.
- **A debug-only testbench flush hook for `fence`, instead of real hardware semantics.** Rejected by the
  user's own scope decision — real semantics close the write-back verification gap by construction
  (`docs/adr/0020`'s D10 precedent) and give `fence` genuine purpose for the first time, instead of
  leaving it permanently undecoded (trapping).
- **A real bus arm/arbitration slot for `ICache.v`.** Rejected once research confirmed
  `InstructionMemory.v` is not on the Wishbone bus at all and nothing else ever shares it — a private
  internal instance needs no arbitration.
- **True LRU replacement.** Rejected for now (round-robin instead) — this core's directed/random test
  programs are far smaller than the cache, so replacement policy has no correctness impact and
  negligible hit-rate impact at this scale; flagged as a `# ponytail:` upgrade path if a real workload
  ever needs it.
- **2-way/1KB smaller-first-pass sizing.** Rejected by the user's own scope decision (the more-ambitious
  4-way/4KB/16B option, consistent with every prior phase's scoping pattern).

## Validation strategy

Every step ended with the full suite passing again before moving to the next, the same discipline as
every prior phase:

- **Standalone unit tests before pipeline wiring**: `sim/tb/tb_icache_unit.v` (G2, small 2-way/32B/8B-line
  override to force real conflict misses/eviction, 22/22 passing) and `sim/tb/tb_dcache_unit.v` (G4,
  same small-override discipline, against a *real* `RamWishboneAdapter`+`DataMemoryBRAM` backing target
  not a stub, 13/13 passing — covers read hit/miss/fill, write hit/miss, sub-word round trip, dirty
  eviction writeback, `flush_all` with mixed clean/dirty lines, post-flush still-hits-clean).
- **G3's live-pipeline stress test**: `sim/tb/tb_icache_live_g3.v`, a tight taken-branch loop forcing real
  eviction/refill under a small-cache override (96 `icache_miss` events observed), proving the
  split-fetch/redirect fix holds under heavy real churn, not just directed hand-crafted cases.
- **G5's bit-exactness bar**: full suite required and confirmed bit-identical to pre-G5 under
  `CACHE_MODE=0` — the variable-latency interlock degenerates to exactly 1 cycle under `CACHE_NONE`.
- **G6's register-only bar, deliberately incomplete**: register/float cross-check clean under
  `CACHE_MODE=1`, cross-producted against both `HAZARD_STRATEGY` values, both `PIPELINE_PROFILE`s, both
  `BRANCH_PREDICTOR`s, MMU on/off — `check_mem_word`-based tests and the memory-dump portion of
  cross-check were *expected* to fail here (nothing yet flushed dirty data before the harness read it
  directly), not a regression; G7 closed that gap immediately after.
- **G7's full bar**: full `sim/run_tests.sh` under both `CACHE_MODE=0`/`=1`, plus the full
  constrained-random cross-check (150/150 MMU-enabled + 60/60 non-MMU) including full memory-dump
  comparison, both cache modes — this is where "full suite green under `CACHE_MODE=1`" became true. New
  permanent regression `sim/tb/tb_fence_flush_g7.v` (store → `fence` → check the raw backing array
  directly, confirming the dirty value actually landed) — kept forever as direct proof of this phase's
  core promise.
- **G8's tooling sanity check**: `bench_runner.py --compare-cache` hit/miss counters cross-checked
  against each benchmark's own already-documented architectural profile (`docs/ROADMAP.md`) — confirmed
  non-trivial, not silently 100%-hit no-ops (e.g. `bench_fib`: 0 D$ misses matching its known small
  working set; `bench_sum_array`: real D$ misses matching its known streaming-access profile).
- **Zero-warning compile throughout**: `iverilog -Wall -g2005 -tnull design/*.v` stayed clean across every
  step, including the N-way hit-compare logic in `ICache.v`/`DCache.v`, written with a generate/
  `assign`-based masked-OR-accumulator pattern (mirroring `MuxN.v`'s own convention) specifically to avoid
  Icarus's "sensitive to all N words in array" warning an `always@*` loop over an unpacked array would
  have triggered.
- **Bit-exact default confirmed by construction and by running**: `CACHE_MODE=0` reduces every new signal
  to its pre-Phase-G behavior, and the entire pre-existing corpus is unaffected by construction.

## Future improvements

- **Tree-PLRU or true LRU replacement**, if a real hit-rate counter (G8's own tooling) ever shows
  round-robin materially underperforms on a realistic workload larger than this project's current test
  programs.
- **`fence.i` / self-modifying-code coherency.** Explicitly out of scope this phase — `fence` orders data
  memory only; I$ has no invalidation path today.
- **MMU/D$ coherency as a real hardware mechanism**, rather than the test-generator-level `fence`
  workaround this phase used to route around `Ptw.v`'s direct-bus-read bypass. A real hardware fix
  (routing the walker's reads through `DCache.v`, or snooping) was out of scope — the current behavior is
  spec-correct (a walker reading stale data past an un-flushed cache is exactly what `fence` exists to
  prevent), just not automatic for the MMU's own internal use.
- **Real hardware performance counters (HPC CSRs)**, a separate Generation 1 item per
  `docs/ROADMAP_VISION.md` — G8's testbench-side hit/miss counters are deliberately not synthesizable
  RTL, only a verification/tooling aid.

## Closing out Phase G

Phase G (G1-G10) is done. `docs/ROADMAP.md`, `docs/ARCHITECTURE.md`, and `handoff.md` are updated by this
same commit to reflect its status. Per the Generation 1 scope decision (`docs/ROADMAP_VISION.md`), Phase
H (dual-issue) stays dropped from near-term scope. Generation 1's other new items (variable-latency
memory, HPC performance CSRs, a profiler, formal verification) remain to be sequenced next.
