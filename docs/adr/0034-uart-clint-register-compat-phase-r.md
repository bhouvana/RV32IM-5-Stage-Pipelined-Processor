# ADR 0034: UART/CLINT Register-Layout Redesign for Linux Driver Compatibility (Generation 3, Phase R)

## Problem

Phase Q (`docs/adr/0033`) closed out real, verified 64MB `MEM_SIZE_BYTES` — real MBs for an actual
kernel image. Per `docs/ROADMAP_VISION.md`'s Generation 3 sequence, Phase R is next: `Uart.v`'s
original 4-register map and `Timer.v`'s original 32-bit 2-register map (both docs/adr/0020, Phase
D4-D8) are entirely custom to this project — no real Linux driver speaks them. Phase T's eventual
goal (a real riscv64 Linux kernel + BusyBox boot attempt) needs a stock kernel's own `8250`
(ns16550a) serial driver and `timer-clint.c` CLINT timer driver to work against this core's real
peripherals with no kernel patch — only a matching device tree, which Phase S will write.

Two scope questions confirmed via `AskUserQuestion` (research-first, per this project's own
established phase workflow — both the recommended/most-ambitious options, consistent with every
prior phase):

1. **Full ns16550a IER/IIR interrupt-cause encoding for the UART**, not just a polling-sufficient
   register map — real `IER`/`IIR` semantics (RX-data-available and THR-empty causes, correct
   priority), not just the byte offsets a polled-only driver would need.
2. **A real CLINT `msip` register + new `mip.MSIP`/machine-software-interrupt CSR support**, not
   just `mtime`/`mtimecmp` — full CLINT-region compatibility (`msip`/`mtimecmp`/`mtime` all present
   at their real offsets), even though this core is still single-hart and nothing but a hart
   interrupting itself will ever set it.

## Design

### Research findings that shaped the design

- **This core's bus is exclusively full-word Wishbone transactions** — `s_sel` was (and remains) a
  declared-but-dead port on both peripherals; neither ever did byte-level access. Kept that
  convention: every new register gets its own **word** offset (`reg-shift=2`/`reg-io-width=4` in DT
  terms — a real, driver-supported combination, not invented for this project), not the literal
  byte-adjacent layout a byte-wide bus would use.
- **`compatible = "ns16550a"` triggers `UPF_FIXED_TYPE` in Linux's `8250_of.c`**, which skips the
  driver's entire legacy `autoconfig()` probe (SCR loopback test, IIR FIFO-encoding test, etc.) — so
  this phase only needed to implement the register *semantics* the driver's ordinary start/TX/RX/
  interrupt code paths actually touch, not full 16550A hardware-detection fidelity.
- **Real CLINT byte offsets are fixed by Linux's own driver source, not by our device tree** —
  `drivers/clocksource/timer-clint.c` hardcodes `msip`@`+0x0000`, `mtimecmp`@`+0x4000`, `mtime`@
  `+0xBFF8` relative to whatever base the DT's `reg` property gives. Only the *base address* is a
  free choice; the three offsets are not.
- **`WbDecoder.v` does a plain `(addr >= BASE) && (addr < BASE+SIZE)` range compare** — a large
  `SIZE` (CLINT's real 64KB region) costs nothing extra in hardware or simulation time.

### Address-map placement

UART stays at `MMIO_BASE` (`0x1000_0000`) unchanged — a free, lucky property: this already matches
QEMU-virt's own literal UART address. `UART_SIZE` grows 16→32 bytes (8 word-registers). CLINT gets a
fresh, **0x10000-aligned** base, `TIMER_BASE = MMIO_BASE + 0x0010_0000 = 0x1010_0000`, `TIMER_SIZE =
0x1_0000` (64KB, matching the real SiFive/QEMU-virt CLINT region size) — the alignment lets
`Timer.v` decode the three real offsets directly off the low 16 bits of the absolute system address,
mirroring `Uart.v`'s own "decode raw address bits, no BASE parameter inside the module" idiom.
Deliberately **not** QEMU-virt's own literal CLINT address (`0x0200_0000`) — that address is below
this project's own RAM ceiling (RAM starts at 0, up to `MEM_SIZE_BYTES`, now 64MB per Phase Q) and
would collide, since this core's memory map shape (RAM-at-0, MMIO far above) differs from
QEMU-virt's own (RAM-at-`0x8000_0000`). Since Phase S writes this core's own device tree from
scratch, exact address values are a free choice — they only need to be internally consistent, not
match any real board's map.

### `Uart.v`: 8-register ns16550a-compatible map, DLAB-gated

| Word offset | DLAB=0 | DLAB=1 |
|---|---|---|
| 0x00 | RBR(read)/THR(write) | DLL (R/W, inert storage) |
| 0x04 | IER (R/W) | DLM (R/W, inert storage) |
| 0x08 | IIR (read) / FCR (write, no-op sink) | same |
| 0x0C | LCR (R/W, bit7=DLAB) | same |
| 0x10 | MCR (R/W, inert storage) | same |
| 0x14 | LSR (read-only) | same |
| 0x18 | MSR (read-only, hardwired 0) | same |
| 0x1C | SCR (R/W, inert storage) | same |

TX/RX serial framing state machines are unchanged from Phase D — only the register *decode* changed.
`LSR` (bit0=DR, bit5=THRE, bit6=TEMT — identical to THRE, no separate FIFO shift-vs-hold distinction)
and `IIR` (priority RX-data-available over THR-empty, matching real spec priority: `0001`=none,
`0100`=RX available, `0010`=THR empty) are new combinational logic. `irq` (renamed from `rx_irq`,
now covers both causes) is level-triggered and self-clearing on the same natural state transitions
that already cleared `rx_ready` before (an RBR read; a THR write re-asserting `tx_busy`) — no new
"IIR read clears the cause" side effect needed.

### `Timer.v`: real CLINT `msip`/`mtimecmp`/`mtime`, genuinely 64-bit

`mtime`/`mtimecmp` are now real 64-bit registers (were 32-bit) at the real CLINT byte offsets,
decoded on `s_addr[15:0]` directly. A new 32-bit `msip` register (bit0 only meaningful) sits at
offset `0x0000`. **XLEN-conditional write width**, reusing `DataMemoryBRAM.v`'s own established
`if (XLEN >= 64)` idiom (cited directly in Phase O's own design notes as reusable precedent) rather
than a runtime-width ternary (avoids a `-Wall` width-mismatch warning): at `XLEN>=64`, a bus write
exactly at the `mtimecmp`/`mtime` offset writes the full 64-bit register in one shot — what a real
single `sd` from a 64-bit Linux kernel driver does (`timer-clint.c` `writeq`s directly at RV64, not
two 32-bit halves, confirmed via research). At `XLEN<64`, the same offset only ever carries the low
32 bits, and the separate `+4` high-half offsets are independently writable/readable — the real
two-32-bit-half access pattern an RV32 kernel driver uses. `msip` is always a plain 32-bit access
regardless of XLEN (real CLINT drivers use `writel`/`readl` for `msip` specifically, even at RV64).

### `mip.MSIP`: a third real hardware interrupt source

New `MIE_MSIE_BIT`(3)/`MCAUSE_INT_MACHINE_SOFTWARE`(3) constants. `CSR.v` gained a `msip_pending`
input (alongside the existing `timer_pending`/`ext_pending`) and a `mie_msie` output, mirroring
`mie_mtie`/`mie_meie` exactly. `riscvpipeline.v`'s interrupt-priority mux extends from MEI-over-MTI
to the real spec ordering **MEI > MSI > MTI** (MSI's spec bit position, 3, sits between MTI's 7 and
MEI's 11 in the real priority table too — this isn't an arbitrary insertion point).

## Real bugs/findings

Unlike the RTL-side "zero bugs" pattern Phase Q's own Q1/Q2 established for a cost-bounding-only
phase, this phase found **two real bugs by careful reading before running** (a rarer class for this
project — every prior phase's own bugs were found only by execution) and confirmed the fixes were
necessary via the directed suite afterward:

1. **`mie_masked`'s write-gate was missing the new `MIE_MSIE_BIT`.** `CSR.v`'s `mie_masked` (the
   mask gating which bits a `csrrX mie,...` write can actually set) enumerated the pre-existing real
   bits (`MTIE`/`MEIE`/`SSIE`/`STIE`/`SEIE`) but not the new `MSIE` — meaning software could never
   actually *enable* the new machine-software interrupt via `mie`, silently defeating the entire
   feature even though `mip.MSIP` itself was wired correctly. Found by tracing the write path before
   trusting it, not by a failing test. The identical gap existed in `mideleg_masked` (S-mode
   delegation of the new source) and in `sim/tools/iss.py`'s own independent mirror of both masks
   (`CSR_MIE`/`CSR_MIDELEG` write handling) — all three fixed together, since a mismatch between any
   pair would have shown up as a real RTL-vs-ISS divergence in the random cross-check, exactly the
   class of bug Phase O's own `mstatus.UXL/SXL` CSR-read-mux finding warned about ("a CSR
   read/write-mask override is real architectural behavior the ISS must mirror too").
2. **Two existing directed tests had stale expected-value literals that the `MSIE` mask fix made
   wrong.** `tb_mmu_csr_f1.v`/`sim/programs/mmu_csr_f1.s` and `tb_mie_mip_csr.v`/`sim/programs/
   mie_mip_csr.s` both write broad bitmasks (`-1`, `0x7f`) to `mie`/`mideleg` and check the readback
   against a hardcoded expected value — every one of those literals was computed assuming only the
   pre-Phase-R real bits existed. Once `MIE_MSIE_BIT`(3) became real, `-1` and `0x7f` (which both
   already include bit 3) now also set it, changing four expected values (`0xAA2`→`0xAAA` twice in
   `tb_mmu_csr_f1.v`, `0x880`→`0x888` once, and `0x22`→`0x2A` once in `tb_mie_mip_csr.v`). Found by
   hand-deriving the new expected bit patterns from the mask change itself before running — confirmed
   correct by the full suite passing on the first run afterward, not discovered as failures needing
   a second pass.

No bugs were found by running that weren't already anticipated by this careful-reading pass — the
full 89/89 directed suite, zero-warning compile, and every random-regression axis (including two
brand-new interrupt-injection modes, see Validation strategy) all passed on the first full run.

## Alternatives considered

**Real byte-level bus access** (honoring `s_sel`, matching a literal byte-adjacent ns16550a layout).
Rejected: this core's bus has never done byte-level peripheral access (`s_sel` was already dead on
both modules before this phase), and DT's `reg-shift`/`reg-io-width` properties already let a
word-addressed peripheral describe itself correctly to Linux's 8250 driver — adding real byte-enable
plumbing would be a second, unrelated bus redesign with no payoff for this phase's actual goal.

**Software-programmable UART baud rate** (making `DLL`/`DLM` drive a real runtime divisor, replacing
the fixed elaboration-time `CLKS_PER_BIT` parameter). Rejected as out of scope: Phase D's own
original design deliberately fixed baud rate at elaboration time ("cycle-accurate... doesn't mean
software gets to program a baud-rate divisor register"), and this phase's stated goal is register
*layout* compatibility, not a new baud-rate-generation hardware feature. `DLL`/`DLM` are
software-visible storage but functionally inert, the same "declared, no live consumer yet" pattern
this project used for Phase O's `mstatus.UXL/SXL`.

**QEMU-virt's own literal CLINT address** (`0x0200_0000`). Rejected — see Design's Address-map
placement section: it would collide with this core's own RAM region at large `MEM_SIZE_BYTES`.

**Real 16550A loopback/modem-control mode, framing-error/overrun detection.** Rejected — none of
these are needed for `UPF_FIXED_TYPE`'s DT-bypassed probe path or ordinary driver TX/RX/interrupt
operation; each is real, documented, out-of-scope simplification, not an oversight (see the Future
improvements section of `Uart.v`'s own header comment).

## Validation strategy

Every existing UART/Timer-touching directed test and the constrained-random interrupt-injection
generator (`random_gen.py`'s `--interrupt timer/uart/both` prefixes) poked the *old* register
offsets by literal immediate — each was updated in lockstep with the RTL redesign, not left to fail
first: `uart_polled.s`, `uart_interrupt.s`, `timer_interrupt.s`(+`tb_timer_interrupt.v`'s own mepc
range check), `mip_live.s`, `interrupt_priority.s`, `interrupt_during_handler.s`,
`interrupt_mie_off.s` (dead reference, updated for accuracy only), `mmu_csr_f1.s`, `mie_mip_csr.s`.
Several of these needed a real address-layout recompute, not just an offset-literal swap: removing
the old 2-instruction `TIMER_BASE`-then-offset(4) computation in favor of a single `lui` directly to
the real CLINT `mtimecmp` address (its low 12 bits are 0) shrinks several programs by one
instruction, shifting every address after that point by 4 bytes — re-derived by actually assembling
each program and cross-checking against the testbench's own register/mepc-range checks, not by hand
arithmetic alone (the project's own established "hand-trace, then verify by running" discipline,
applied here to address layout specifically). `tb_uart_unit.v`/`tb_timer_unit.v` were rewritten
wholesale for the new register maps, extended with real new coverage (`tb_timer_unit.v` now
exercises both the XLEN=32 split-half and XLEN=64 single-write CLINT paths side-by-side, mirroring
`tb_alu_wordop_unit.v`'s own multi-parameter structure; `tb_uart_unit.v` gained IIR-cause-priority
and DLAB/DLL/DLM round-trip checks that didn't exist before).

New directed test `sim/programs/msi_interrupt_r7.s` + `sim/tb/tb_msi_interrupt_r7.v` (mirrors
`timer_interrupt.s`'s own shape exactly) proves the new `mip.MSIP` path end-to-end: arm `mie.MSIE` +
CLINT `msip`, confirm the redirect happens with `mcause=0x80000003`, handler clears `msip` before
`mret`. New `random_gen.py --interrupt msi` mode (mirrors `"uart"`'s own shape) plus extending
`"both"`'s own priority-check reasoning to the three-source ordering.

Full closing bar: **89/89 directed tests** (up from 88/88 — the new `msi_interrupt_r7` test), zero-
warning `iverilog -Wall -g2005 -I design -tnull design/*.v` compile, and constrained-random
cross-check clean at every axis: 60/60 default (XLEN=32), 60/60 XLEN=64 non-MMU (`--n-instrs 8` — a
pre-existing, Phase-P3-documented budget quirk at this XLEN, unrelated to this phase), 60/60
Sv32-MMU, 60/60 Sv39-MMU, 40/40 each of the four interrupt-injection modes (`timer`/`uart`/`msi`/
`both`), plus 30/30 at the real 64MB `MEM_SIZE_BYTES` target (Phase Q's own bar, confirming the new
`TIMER_SIZE`/`TIMER_BASE` don't collide with anything at scale).

## Future improvements

`DLL`/`DLM` staying functionally inert (no software-programmable baud rate) — a real prerequisite if
a future phase ever wants a genuinely configurable UART. No real `MCR` loopback mode; `MSR` hardwired
to 0 (no modem-control DT properties supported) — fine for a serial console, would need real work for
anything relying on hardware flow control. `msip` is only ever self-targetable today (this core is
still single-hart) — real multi-hart IPI usage is Generation 5's own scope (`docs/ROADMAP_VISION.md`
Multicore SoC), not attempted here. `sim/formal/`'s own frozen `CSR.v`/`riscvpipeline.v` copies
(Phase L, `docs/adr/0027`) have not been kept in sync with `design/`'s own changes since Phase L
closed — Phases M/N/O/P/Q already left them stale through RV64 migration, the branch-encoding swap,
and the Sv39 MMU; this phase's new `mip.MSIP`/CLINT changes widen that same pre-existing gap further,
not a regression this phase introduces alone. Generation 3, Phase S (a hand-rolled minimal SBI
firmware + DTB, per `docs/ROADMAP_VISION.md`) is next.
