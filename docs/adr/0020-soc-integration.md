# ADR 0020: SoC integration — bus protocol, UART, timer, real interrupts (Phase D of the redesign)

## Problem

The user's five-phase redesign (`docs/adr/0018`'s Problem section) named
variable pipeline depth (Phase A, done), a code-quality pass (Phase B,
partially done — see that phase's own notes in `handoff.md`; item 2,
signal-naming/port-ordering conventions, remains deliberately deferred), an
F-extension port (Phase C, done, `docs/adr/0019`), **SoC integration (Phase
D, this ADR)**, and performance work (Phase E). Phase A's own plan explicitly
flagged Phase D as needing its own dedicated research-and-design pass before
implementation, and called it "the hardest verification problem in this
whole roadmap." Three parallel research agents confirmed, by direct reading
rather than assumption, that this premise was correct and in one respect
worse than assumed:

- **Zero bus/address-decode logic existed.** `design/DataMemoryBRAM.v` was a
  single flat device — the entire `address` bus indexed straight into its
  byte array, no range checking, no chip-select, no mux for multiple
  devices. `fpga/top.v`'s own comment already said "deliberately not a full
  SoC (no UART, no memory-mapped I/O, no boot ROM)."
- **Zero interrupt CSR state existed.** `design/CSR.v` implemented exactly
  `mstatus` (MIE/MPIE only), `mtvec`, `mscratch`, `mepc`, `mcause`, plus the
  F-extension's `fflags`/`frm` — no `mie`, `mip`, or `mtval`. `docs/adr/0011`
  had already anticipated this: "if this core ever gains a timer or external
  IRQ line, `mstatus.MIE`/`mie`/`mip` are the natural next CSRs to add, and
  the trap-entry path already generalizes." The real structural gap:
  `exception_taken` only ever fired for the instruction currently, actively
  sitting in EX — an asynchronous interrupt has no instruction to attach to
  and must be able to redirect on any cycle, including while `reg2_hold` is
  freezing the pipeline for an unrelated multi-cycle op.
- **The verification-safety problem was real, and worse than the plan
  assumed.** `docs/adr/0014` had already found `ecall`/`ebreak`/`mret`/
  illegal-instruction control flow unsafe to constrained-randomly generate
  (an uncontrolled redirect into a possibly-uninitialized `mtvec` risks
  non-termination). An asynchronous interrupt is a strict superset of that
  risk: it isn't represented in the instruction stream at all, so it can
  defeat `random_gen.py`'s forward-only-branches-plus-fixed-halt-loop
  termination guarantee regardless of program structure. **Correction to the
  plan's original premise**: `sim/tools/run_random_tests.py` does not use
  `sim/tb/bench_template.v`'s self-loop halt detector (that belongs to
  `bench_runner.py`) — it uses `sim/tb/dump_regs_template.v`, which has **no
  halt detection at all**, just a fixed-time-budget sample. And
  `sim/tools/iss.py` had **zero interrupt-timing model** — it only ever
  entered `trap()` synchronously, from inside `step()`, for the instruction
  currently being stepped. Any interrupt-aware random testing needed a
  scheme where the RTL and ISS **agree by construction** on when an
  interrupt fires, not one where each side tries to independently discover
  real timing.

Three scope decisions were made explicitly with the user before
implementation (via a planning-tool question, not assumed), all toward the
more ambitious option — consistent with Phase C's own full-RV32F/full-
forwarding choices:

1. **Two interrupt sources**: a timer (`mtime`/`mtimecmp`) *and* a UART
   RX-ready interrupt, not timer-only.
2. **Cycle-accurate UART timing**: real bit-shifted serial framing (start/
   8-data/stop bits, a fixed `CLKS_PER_BIT` divisor), not an instant
   behavioral stand-in.
3. **A named, extensible bus protocol**: a classic (non-pipelined)
   Wishbone-style handshake (`CYC`/`STB`/`WE`/`ADR`/`DAT_O`/`SEL`/`DAT_I`/
   `ACK`), not a minimal ad hoc two-region mux.

Two further scoping defaults were set without a separate question
(low-controversy, reversible, recorded here so they're visible): a **minimal
PLIC-lite** (`mip.MEIP` driven directly by "UART RX interrupt pending AND
UART's own RX-interrupt-enable bit," not a real multi-device claim/complete
PLIC — this phase has exactly one external device), and a **fixed
elaboration-time UART baud** (`CLKS_PER_BIT` parameter, not a
software-configurable divisor register).

This made Phase D larger than Phase C: twelve independently-verified steps
(D1–D12), each ending with the full suite passing again, per this project's
established convention.

## Design

### D1 — Bus protocol infrastructure, standalone

`design/wb_defs.vh` (the classic Wishbone signal convention, `` `WB_SEL_WIDTH``=4)
and `` `MMIO_BASE`` (`32'h1000_0000`, `riscv_defs.vh`) declared with no
consumers yet, mirroring Phase A1/C1's "declare state before consumers"
staging. `design/WbDecoder.v`: a purely combinational, `NUM_SLAVES`-
parameterized address decoder/mux (flattened `BASE`/`SIZE` buses, the same
convention Phase A5's `Forward.v`/`Hazard.v` generalization established) —
routes the LSU-side master's request to exactly one slave's range, ties
`m_ack` low forever for an address matching no slave (a visibly-hung bus,
not a silently-wrong read). Standalone-verified (`sim/tb/tb_wbdecoder_unit.v`)
against three dummy slave stubs with deliberately different ack timing plus
a deliberate address gap. No real bugs found.

### D2 — `RamWishboneAdapter.v`, standalone

A thin Wishbone slave wrapper around the existing, **unmodified**
`DataMemoryBRAM.v` — this project's repeated "wrap, don't touch a verified
module" pattern. One deliberate deviation from "pure" Wishbone: load
width *and signedness* (`lb` vs `lbu` address the same byte with the same
`sel` pattern but need different sign-extension) is threaded through as an
explicit side-band `funct3` tag, wired point-to-point rather than forcing
`DataMemoryBRAM.v` itself to change. **One real process-level lesson**: a
first version `` `include``d `DataMemoryBRAM.v` directly inside the adapter,
breaking the whole-tree zero-warning compile (duplicate module declaration).
This codebase's actual convention — confirmed by checking that
`riscvpipeline.v` itself has zero `` `include``s of sibling design files —
is module-name-only cross-references; fixed by adding the include to the
testbench's own list instead. Standalone-verified
(`sim/tb/tb_ramwishboneadapter_unit.v`). No RTL bugs found.

### D3 — Wire the bus live, RAM-only (highest-risk step #1)

Isolated alone, mirroring Phase A3/C6's risk profile: the step that changes
how every load/store reaches memory, with no new peripheral yet to justify
the risk on its own. **A real design trap found and avoided by tracing,
not by building and then discovering a bug**: the plan's own description
said `mem_stall` would "generalize to freeze while `!ack`." Hand-tracing a
concrete back-to-back-loads scenario before writing that generalization
showed it would silently reintroduce the exact bug class `docs/adr/0009`/
`0013` already fixed once — a bare level signal (`ack`) can't distinguish a
fresh request from a stale one, since both loads' `cyc`/`stb` stay
continuously asserted across the transition. **Fix: `mem_stall` was left
completely unchanged**, still keyed only off `memRead_regem`, with the new
bus's `ack` wired but deliberately not consumed — deferred until a
peripheral with genuinely different latency actually needs it (D5/D8), and
even then must preserve "track the transition event, not the raw level."
Four files' hierarchical references to `dut.m_DataMemory.data_memory[...]`
needed updating to `dut.m_DataMemory.m_ram.data_memory[...]` (one level
deeper now that `RamWishboneAdapter` wraps the real BRAM). Verified
bit-for-bit unchanged — 37/37 full suite, zero-warning compile, and the full
constrained-random corpus re-run clean across the default configuration and
both `HAZARD_STRATEGY`/`PIPELINE_PROFILE` alternates.

### D4 — `design/Uart.v`, standalone

Cycle-accurate UART — this phase's closest analog to Phase C's `FSqrt.v`,
genuinely novel to this codebase. Real 8N1 serial framing shifted one bit
per `CLKS_PER_BIT` cycles; RX samples each bit at its midpoint (standard
practice, avoiding transition jitter); native Wishbone slave with a
`TXDATA`/`RXDATA`/`STATUS`/`CONTROL` register map; `rx_irq = rx_ready &&
rx_irq_enable`, no consumer yet. **No RTL bugs found** — the one failure was
in the testbench itself, and it generalizes: `tb_uart_unit.v`'s first
version checked `STATUS.tx_busy` via a bus read immediately before calling
the task that waits for TX's start-bit falling edge — that read burns 2
clock cycles, enough to push the wait past the real edge into a later,
unintended transition mid-frame. **A verification helper that itself
consumes clock cycles can distort the very timing window it's trying to
observe** — fixed by checking `tx_busy` via a direct hierarchical reference
instead. Standalone-verified playing both roles a real external UART peer
would (receiver decoding `tx`, transmitter driving `rx`).

### D5 — Wire UART onto the live bus, polled only

`` `UART_BASE``/`` `UART_SIZE`` added; `PIPELINED` gained real `uart_tx`/
`uart_rx` pins (the same "tap for external use" shape `debug_x10` already
established) and a `UART_CLKS_PER_BIT` parameter. Mechanical fallout: every
existing testbench's `PIPELINED` instantiation needed `.uart_rx(1'b1)`
added (idle-high, matching a disconnected serial line). New directed test
(`tb_uart_polled.v`) exercises the entire live chain for the first time —
real `lw`/`sw` to the UART's MMIO address, real software polling loops, a
background process playing the external-receiver role concurrently with the
CPU's own loop (applying D4's timing lesson from the start, not retrofitted
after failing the same way again). No bugs found — passed on the first run.
60/60 fresh random cross-check confirmed UART's presence on the bus is
fully transparent to every program that never addresses it.

### D6 — `design/Timer.v`, standalone

A free-running CLINT-style `mtime`/`mtimecmp` peripheral, native Wishbone
slave. One deliberate simplification: 32-bit registers, not the real spec's
64-bit pair — this single-hart, simulation-focused core's actual
verification needs don't pay for the extra complexity, the same "minimal,
not maximal" spirit as the PLIC-lite decision. `pending` (`mtime >=
mtimecmp`) is plain combinational logic; writing `mtimecmp` re-arms the
comparison the standard way rather than forcing `pending` low as a special
case. No RTL bugs found — standalone-verified on the first run
(`tb_timer_unit.v`), including the "reset: pending true immediately" finding
(`mtime`=0 >= `mtimecmp`=0) that later mattered for D8's own test design.

### D7 — CSR extensions: `mie`/`mip`/`mcause`'s interrupt bit, no live redirect yet

`CSR.v` gains `mie`/`mip`, each with only two real bits
(`` `MIE_MTIE_BIT``=7, `` `MIE_MEIE_BIT``=11, mirroring `mstatus`'s own
MIE/MPIE-only precedent). `mip` is **read-only, hardware-driven** — not even
a `reg`, a plain combinational `wire` built from two new `timer_pending`/
`ext_pending` inputs (tied to `1'b0` by `riscvpipeline.v` for now — D8's job
is swapping the tie-off for real wires, with zero further `CSR.v` changes
needed at that point). Three new outputs (`mstatus_mie`, `mie_mtie`,
`mie_meie`) exposed with no consumer yet, so D9 wouldn't need to touch
`CSR.v`'s interface a third time. No RTL bugs found — new directed test
(`tb_mie_mip_csr.v`) covers masking, `csrrw`-replaces-vs-`csrrs`-ORs
semantics against two non-adjacent bit positions, and `mip`'s read-only
behavior.

### D8 — Wire `Timer.v`/UART pending bits onto `mip` live, still no redirect

Isolates "does real hardware state correctly reach `mip`" from "does the
CPU correctly act on it." `WbDecoder`'s `NUM_SLAVES` becomes 3 (RAM, UART,
Timer); `` `TIMER_BASE``/`` `TIMER_SIZE`` added, non-overlapping with UART's
window by construction. **A real, genuinely valuable pipeline-timing
finding, not an RTL bug**: an MMIO store commits at the MEM stage, one cycle
behind EX, but `mip`'s read-side view of a peripheral's pending state is
derived combinationally from that peripheral's *current* register contents
as EX sees them that same cycle — a `csrrs` reading `mip` immediately after
an `sw` meant to affect it races the store by one cycle. Diagnosed with a
throwaway debug testbench printing `Timer.v`'s live state via hierarchical
reference; fixed in the *test program* (two spacer instructions), not with
a new hardware interlock — this is a small, one-time settling delay between
two independent subsystems, the kind of ordering a real driver routinely
allows for, and D9's own interrupt-detection logic (which polls `mip`
continuously, not "immediately after a specific store") is not exposed to
the same race. New directed test (`tb_mip_live.v`) exercises the real, live
transitions this step is about. 42/42 full suite, 60/60 fresh random
cross-check.

### D9 — The interrupt redirect path (highest-risk step #2)

The plan's own flagged hardest single step. `riscvpipeline.v` gained a new
interrupt-detection point, reusing the existing `exception_taken`/
`unconditional_redirect`/`redirect_target` mux exactly as `docs/adr/0011`
anticipated: `interrupt_taken = mstatus_mie & (mei_pending | mti_pending) &
!pc_stall & !other_redirect_taken`, MEI-over-MTI priority via a simple
priority-ordered ternary. Two design properties distinguish this from every
existing redirect source:

- **`mepc` is the PC of the instruction that would have executed next**
  (`pc_o_regfd`, reg1's current output — squashed by this same redirect),
  not the exception path's `pc_o_regde` (EX's current occupant): unlike a
  synchronous exception, the instruction currently in EX did nothing wrong
  and is left to retire normally; only what comes after it is deferred.
- Gated on `!pc_stall` (the full pipeline-freeze condition), not just the
  plan's own literal wording of `!reg2_hold` — a real design finding, below.

**Two design findings, both caught by tracing before writing RTL**:

1. **`!reg2_hold` alone would have been insufficient.** `reg1.v`'s own
   squash-on-jump check runs *before* its stall check, so asserting an
   interrupt's `jump` into `reg1` during an ordinary Hazard.v load-use
   stall (`stall`, folded into `pc_stall` but not into `reg2_hold` — they
   are disjoint condition sets) would squash the very instruction that
   stall exists to hold in place. Fixed by gating on the full `!pc_stall`.
2. **`mepc` needs a bubble-detection fallback.** `pc_o_regfd` reads as a
   meaningless `0` on any cycle where reg1's current output is itself a
   squash-produced bubble rather than a real fetched instruction — reachable
   the cycle immediately after *any* other taken redirect, before the real
   post-redirect fetch reaches reg1's output. Fixed with a new register,
   `id_bubble_r`, mirroring `reg1.v`'s own priority ordering (squash >
   stall-hold > fresh-latch); `interrupt_mepc = id_bubble_r ? pc_o :
   pc_o_regfd` — falling back to IF's own live PC, provably correct in
   exactly this case since that's the address the earlier redirect already
   retargeted fetch to.

Five new directed tests cover the plan's full checklist — timer and UART
interrupts taken correctly (an N-iteration loop interrupted somewhere
mid-run, `mepc` range-checked against the loop's own address bounds rather
than pinned to one exact cycle, the final loop count exactly right either
way, proving no instruction is skipped or duplicated, and that `mret` needs
no software `+4` adjustment, unlike the ecall convention `tb_mret_return.v`
already covers); `mstatus.MIE=0` blocking a genuinely pending+enabled
source for an entire run; MEI-over-MTI priority when both sources are
pending simultaneously; and an interrupt correctly deferred, not dropped,
while `mstatus.MIE=0` mid-handler (event-waiting for a `0->1` transition on
`Timer.v`'s own `pending`, not a level-wait, since `Timer.v` resets with
`pending` already true). 47/47 full suite, 80/80 fresh random cross-check
confirming this step is fully invisible to every program that never touches
`mie`/`mstatus.MIE`.

### D10 — Verification-safety machinery

The plan's own flagged intellectually hardest step: making the RTL and ISS
**agree by construction** on interrupt timing rather than solving real
cycle-accurate co-simulation. **The core realization, once two real bugs
(below) were found and fixed**: the RTL's real hardware timing and the
ISS's own externally-scheduled firing point do *not* need to agree on the
exact instruction boundary. The injected handler is deliberately
architecturally inert (`csrrw x0, mie, x0` then `mret` — zero register/
memory footprint), and D9's own redirect logic already guarantees no
instruction is skipped or re-executed; so as long as the interrupt fires at
most once somewhere before the generated program's own halt loop, on each
side independently, the final compared state (regs/mem/fregs/fflags/frm —
CSR state was never part of the comparison) is identical regardless of
exactly which cycle it landed on. This let the timer source's own RTL-side
timing stay a *generous, not precise* `MTIMECMP` estimate rather than a
tight cycles-per-instruction calculation, and let the UART source rely on
the test rig directly driving a byte early and fast rather than timing it
against anything.

`sim/tools/iss.py` gained `schedule_interrupt(after_steps, cause)` and a
check in `run()`'s loop (steps-taken ≥ `after_steps`, and `mstatus.MIE`)
before the existing self-loop-halt detection, calling the existing `trap()`
unmodified — single-shot by construction. `sim/tools/random_gen.py`'s
`gen_program()` gained `mem_size=128` (threaded through every previously-
hardcoded `128`, fully backward compatible) and `interrupt=None`
(`"timer"`/`"uart"`), splicing an arming prefix and the inert handler around
the untouched core-program generation. `sim/tools/run_random_tests.py`
gained `--interrupt`/`--mem-size` plumbing and a new
`sim/tb/dump_regs_interrupt_template.v` sibling (`uart_rx`/`uart_tx` wiring
plus a driven-byte stimulus snippet) — the existing non-interrupt path and
its own template stayed completely untouched.

**Two real bugs found by running, not by design review**:

1. **The ISS had no MMIO model, and its memory-access helpers didn't know
   that.** `load_mem_byte`/`store_mem_byte` unconditionally masked every
   address into the small flat `self.mem` array, with no notion that
   `` `MMIO_BASE`` and above is real peripheral space on the RTL side,
   routed away from RAM entirely by `WbDecoder`. The interrupt-mode
   prefix's own `sw` to `TIMER_BASE`/UART's `CONTROL` register aliased
   straight into low RAM offsets on the ISS side only, corrupting the
   memory comparison on every seed. Fixed by making both helpers
   return/discard MMIO-range accesses without touching `self.mem` for
   them, the same convention `csr_read`/`csr_write` already use for
   unimplemented CSRs.
2. **A random instruction reading `mstatus`/`mepc`/`mcause` genuinely can't
   agree between RTL and ISS in interrupt-mode programs** — not a redirect
   bug, a real, unavoidable consequence of the two engines deliberately not
   agreeing on the exact firing cycle: these three CSRs are exactly the
   ones the interrupt itself mutates, so a `csrrs`/`csrrw` reading one of
   them lands on whichever side of "has this side's interrupt fired yet"
   each engine happens to be at. Fixed the same way this generator already
   excludes `ecall`/`ebreak`/`mret` from random generation — a restricted
   CSR-name pool used for random CSR instructions specifically in
   interrupt-mode programs.
3. A smaller, related finding: `Register.v`'s `SP_INIT` ties to
   `MEM_SIZE_BYTES` (`docs/adr/0015`), which the ISS had hardcoded to 128 —
   silently correct until interrupt mode actually varied it. Fixed by
   setting `self.regs[2] = mem_size`.

Verified: 47/47 full suite (untouched `design/*.v`), non-interrupt corpus
30/30 (confirming the refactor is fully backward compatible), timer-mode
60/60 across two seed ranges, uart-mode 55/55 across two seed ranges.

### D11 — The random cross-check sweep with interrupts enabled

A new `"both"` interrupt mode (both sources armed and pended
simultaneously, so the real interrupt taken must be the external one —
D9's already-proven MEI-over-MTI priority, now exercised under a random
program body rather than only a directed test). **Two more real bugs found
at real sweep volume**, neither surfaced by D9's directed tests or D10's
smaller initial samples:

1. **`mtvec` itself is unsafe for interrupt-mode random programs to
   read/write — a different hazard than D10's mstatus/mepc/mcause
   exclusion.** `mtvec` isn't mutated *by* the interrupt, but a random
   `csrrw`/`csrrs`/`csrrc` targeting it *writes* a new redirect target —
   and since the real interrupt only fires later, at a cycle the two
   engines don't agree on by construction, each side can still be holding
   a different mtvec value at its own firing moment, sending the
   interrupt to two different addresses and unraveling everything
   downstream. Fixed by adding `mtvec` to the same restricted CSR-name
   pool (only `mscratch`, genuinely inert, remains).
2. **A real bug in `CSR.v` itself**, found via a 100-seed uart-mode sweep
   (seed 544) and a throwaway hierarchical-reference debug testbench: an
   ordinary, unrelated CSR write legitimately retiring in EX the exact
   same cycle an interrupt is separately taken was **silently dropped**.
   `CSR.v`'s clocked block used one shared `if (trap_taken) ... else if
   (mret_taken) ... else if (csr_write_en) ...` priority chain covering
   every register at once — correct before D9, since `trap_taken` (then
   only ever a synchronous exception) was always tied to the exact same
   instruction `csr_write_en` would be, and an instruction is never both.
   D9's interrupt is independent of what's in EX by design, breaking that
   invariant: it can fire the same cycle an unrelated, perfectly
   legitimate `csrrX` instruction elsewhere in EX is retiring its own CSR
   write, and the shared chain silently suppressed that write whenever a
   same-cycle interrupt also happened to be taken. Fixed by splitting the
   shared chain into one independent if/else-if chain **per register**:
   `mie`/`mtvec`/`mscratch` (never touched by trap/mret at all) each stand
   alone now, no collision possible; `mepc`/`mcause`/`mstatus` (the
   registers trap_taken/mret_taken *do* also touch) keep their existing
   priority chain exactly as before, since for those a same-register
   collision is genuine and trap/mret correctly still wins.

Verified after both fixes: zero-warning compile, 47/47 full suite
(unaffected — a correctness fix to already-existing plumbing, not new
behavior for anything the directed suite exercises), non-interrupt corpus
300/300, timer-mode 150/150, uart-mode 150/150, both-mode 150/150 plus a
separate 50/50 at a larger per-program instruction count.

## Alternatives considered

- **A real multi-device PLIC** (claim/complete registers, per-device
  priority). Rejected: this phase has exactly one external device (UART
  RX) — building generic multi-device infrastructure with nothing but UART
  to exercise it would be the same over-engineering this project has
  avoided elsewhere (`docs/adr/0015`'s "named, not truly variable"
  convention is the closest precedent). Noted as future work if a second
  external device is ever added.
- **A software-configurable UART baud-rate register.** Rejected: the
  "cycle-accurate" decision was about real bit-by-bit shift timing being
  modeled at all, not about giving software a runtime divisor to program —
  extra interface surface with no verification value this phase needed.
- **Generalizing `mem_stall` to key off the bus's own `ack`** (D3).
  Rejected after hand-tracing showed it would reintroduce the exact
  "bare level signal can't distinguish fresh from stale" bug class
  `docs/adr/0009`/`0013` already fixed — the existing, event-tracking
  `mem_stall`/`mem_stall_done_r` mechanism stayed unmodified instead.
- **Deriving cycle-accurate co-simulation timing** for D10/D11's
  interrupt-injection mode (having the ISS model real mtime/UART-frame
  timing so RTL and ISS agree on the exact firing instruction). Rejected
  once the architecturally-inert-handler property was recognized: neither
  side needs to know or care exactly when the other fires, only that each
  fires at most once — a substantially simpler mechanism than real
  cycle-accurate modeling, and the one the plan's own Context section had
  hoped might be possible.
- **Re-deriving MEI-over-MTI priority inside `random_gen.py`/`iss.py`**
  for `"both"` mode instead of simply telling the ISS to expect the known
  external cause. Rejected: this project's established boundary is that
  the ISS independently checks RTL results, not re-implements the thing
  being checked (the same reasoning div/rem and float special cases
  already follow) — D9's directed tests already prove the priority logic
  itself; D11's job is exercising it under random program bodies, not
  re-verifying it a second, redundant way.

## Validation strategy

Every step ended with the full suite passing again before moving to the
next, the same discipline as every prior phase:

- **Full directed suite**: grew from Phase C's 35/35 baseline to 47/47 by
  the end of D9 (twelve new files: `tb_wbdecoder_unit.v`,
  `tb_ramwishboneadapter_unit.v`, `tb_uart_unit.v`, `tb_uart_polled.v`,
  `tb_timer_unit.v`, `tb_mie_mip_csr.v`, `tb_mip_live.v`,
  `tb_timer_interrupt.v`, `tb_uart_interrupt.v`, `tb_interrupt_mie_off.v`,
  `tb_interrupt_priority.v`, `tb_interrupt_during_handler.v`), unchanged
  through D10/D11 (correctness-only fixes to shared tooling/CSR logic, no
  new directed coverage).
- **Zero-warning `iverilog -Wall -g2005` compile** across all of
  `design/*.v`, confirmed after every step including both post-D9 bug
  fixes.
- **Constrained-random cross-checking**: the pre-existing non-interrupt
  corpus was re-confirmed clean after every bus-wiring step (D3, D5, D8:
  100/100, 60/60, 60/60) and after the D11 `CSR.v` fix (300/300) —
  confirming the bus/peripherals/interrupts are fully additive, never
  perturbing a program that doesn't address them. The new
  interrupt-injection mode (D10/D11): timer-only 210/210 total across
  several sweeps, uart-only 205/205 total, both-sources-simultaneously
  200/200 total (150 at the default instruction count, 50 at a larger
  one) — all fully clean once the bugs documented above were fixed.
- **Standalone module verification before pipeline integration** for
  every genuinely new module (`WbDecoder.v`, `RamWishboneAdapter.v`,
  `Uart.v`, `Timer.v`), mirroring `tb_divider_unit.v`/Phase C's own
  `tb_fregister_unit.v` precedent.

## Future improvements

- **A real multi-device PLIC** remains explicitly out of scope until a
  second external interrupt source exists — see Alternatives.
- **Software-configurable UART baud rate** remains out of scope — see
  Alternatives.
- **Real FPGA pin-level bring-up** (wiring `Uart.v`'s `tx`/`rx` to actual
  board pins in `fpga/top.v`, any clock-domain-crossing the UART might
  need) stays future work, matching how Phase A/C's own "real hardware
  validation" was consistently deferred rather than attempted mid-phase.
- **Software/inter-processor interrupts (`mip.MSIP`)** are not implemented
  and not faked — no second hart exists to send one.
- **U-mode/S-mode interrupt delegation** (`mideleg`/`medeleg`) remains out
  of scope — this core is M-mode only throughout, the same boundary
  `docs/adr/0011` already drew for exceptions.
- **A real 64-bit `mtime`/`mtimecmp`** (the actual CLINT spec shape,
  instead of this phase's documented 32-bit simplification) remains open
  if a real multi-hart or long-uptime scenario ever needs it.
- **A genuinely larger interrupt-injection random corpus** (more seeds,
  larger `n_instrs`, more `mem_size` headroom) is straightforward given
  D10/D11's machinery, just not exhaustively run here — the counts in
  Validation strategy are what this phase's own verification bar needed,
  not a ceiling on what the tooling supports.
