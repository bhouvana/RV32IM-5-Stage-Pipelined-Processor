# ADR 0031: RV64/Sv39 privilege-CSR groundwork (Generation 3, Phase O)

## Problem

Generation 2 ("RV64IMAF Processor v2.0") closed out with Phase N (`docs/adr/0030`), which fixed
this core's branch-instruction encoding — the more fundamental of the two prerequisites Generation
3 needed. `docs/ROADMAP_VISION.md` calls for Generation 3 next: a Linux-capable RV64 core, needing
M/S/U privilege re-verified for RV64, a from-scratch Sv39 MMU (the existing Sv32 MMU is force-
disabled at XLEN=64 since Phase M, and Sv39's 3-level/64-bit-PTE layout is explicitly documented
as a new design, not a port), and eventually a real Linux boot attempt.

Feasibility research done before any RTL work found two real findings shaping the whole rest of
Generation 3: (1) a real riscv64 Linux kernel+rootfs is obtainable prebuilt with no build needed
(`UCanLinux/riscv64-sample`), but targets QEMU-virt-shaped devices (16550 UART, CLINT timer) this
core's bespoke `Uart.v`/`Timer.v` don't match; (2) getting a custom kernel driver in would need a
real `riscv64-linux-gnu` (glibc) cross toolchain, not confirmed obtainable on native Windows (the
same blocker class as Generation 2's Spike/Sail problem). The path that avoids a kernel rebuild —
redesigning the peripherals to be register-compatible with existing Linux drivers/bindings, plus a
hand-rolled minimal SBI firmware and a DTB — reshapes Generation 3 into a longer phase sequence:
**O** (this phase, privilege/CSR groundwork) → P (Sv39 MMU/TLB/PTW) → Q (memory scale-up) → R
(UART/Timer compatibility redesign) → S (SBI firmware + DTB) → T (load the kernel, attempt boot).

Phase O's own scope: three research agents (current CSR.v privilege-machinery audit, RISC-V
Privileged spec Sv39 research, verification-tooling MMU-coupling audit) confirmed most of `CSR.v`'s
M/S/U privilege/delegation/CSR-access-check machinery is already XLEN-agnostic (every real
`mstatus`/`mie`/`mip` bit sits at identical positions in RV32 and RV64 per spec) — the only genuine
RV32-shaped state is `satp`'s bit layout (hardcoded to Sv32's single-bit MODE at bit 31, unconditional
on `XLEN`) and the complete absence of RV64's `mstatus.UXL`/`SXL` fields. `translate_enable`
(`riscvpipeline.v`) already deliberately gates on `XLEN==32` as a stopgap, documented in a comment as
"deliberately deferred" pending a real RV64 layout — Phase O is that deferred item.

## Design

Scoped narrowly, mirroring this project's own established "declare state, no live consumers yet"
pattern (the original Sv32 MMU's own Phase F1): make the CSR-side `satp`/`mstatus` layout genuinely
correct and spec-shaped for RV64/Sv39, **without changing any live translation behavior** —
`translate_enable`'s `(XLEN==32) && ...` gate stays byte-for-byte unchanged; Sv39 doesn't exist as
real hardware until Phase P's own new `Tlb.v`/`Ptw.v`.

### `mstatus.UXL`/`SXL` — read-mux constants, not real storage

This core has no real 32-bit U/S sub-mode planned, so RV64's `UXL`/`SXL` fields (2 bits each, at
33:32/35:34, encoding the effective XLEN visible to U-mode/S-mode) are fixed WARL-to-2 ("64-bit")
values applied at the CSR read mux — `mstatus`/`mstatus_masked` are never touched, so nothing here
is ever writable, the same "view, not storage" relationship `sstatus`/`fcsr` already have to their
backing registers. Implemented as a guarded part-select in the read `always @(*)` block, directly
reusing `DataMemoryBRAM.v`'s own proven `if (XLEN >= 64) begin ... end` idiom (confirmed there,
per `docs/adr/0028`, to dead-code-eliminate cleanly under `iverilog -Wall` at XLEN=32 — the branch
is constant-folded away entirely rather than eliciting an out-of-range-slice warning).

### `satp` MODE/ASID/PPN decode — genuinely XLEN-conditional

Sv39's `satp` layout is completely different from Sv32's: MODE is a 4-bit field at 63:60 (Sv39=8,
Bare=0; Sv48/Sv57 not implemented), ASID is 16 bits at 59:44, PPN is 44 bits at 43:0 — versus
Sv32's 1-bit MODE at bit 31, 9-bit ASID at 30:22, 22-bit PPN at 21:0. `CSR.v`'s `satp_mode_val`/
`satp_ppn_val` outputs changed from continuous `assign`s to `output reg` + a procedural
`always @(*)` with a plain `if (XLEN == 32) ... else ...` picking the right layout — the same
proven procedural-`if` idiom as the UXL/SXL override, not a ternary (a ternary's out-of-declared-
range part-select on the Sv39 side, at `satp`'s XLEN=32-shaped 32-bit width, is genuinely untested
territory in this codebase; the procedural form is the one this project has already confirmed safe).
Port shapes are unchanged (`satp_mode_val` still 1 bit, `satp_ppn_val` still 22 bits) — every
existing caller (`riscvpipeline.v`) needed zero edits. `satp_mode_val`'s meaning generalizes
correctly at both XLENs: "a real, non-Bare translation mode is selected."

`satp_ppn_val`'s width is deliberately **not** widened this phase — its only consumer is `Ptw.v`'s
hardcoded `input [21:0] satp_ppn` (Sv32-shaped), entirely Phase P's own job to rewrite. Widening it
now would force a matching wire-width change in `riscvpipeline.v` for no live benefit, splitting one
conceptual change (widen `Ptw.v` for Sv39) across two phases for no reason. At XLEN==64 the decode
truncates to the low 22 bits of the real 44-bit PPN field rather than a hardwired 0, so it reflects
real (if truncated) data on the rare chance anything reads it before Phase P — but this is provably
unreachable today since `translate_enable`'s own `(XLEN==32) &&` term means nothing in the live
pipeline ever consumes it at XLEN==64, regardless of what `satp_mode_val`/`satp_ppn_val` compute.

### Sv39 VPN/PTE-PPN bit-position constants — pre-declared, inert

`riscv_defs.vh` also gained the Sv39 VA decomposition (`SV39_VPN2/1/0_HI/LO`) and PTE PPN
sub-field (`SV39_PTE_PPN2/1/0_HI/LO`) constants, spec-correct, consumed by **nothing** yet —
mirroring Phase F1's own precedent of pre-declaring the Sv32 equivalents before F3/F4 actually used
them. Zero marginal risk (pure `` `define``s, no wiring), and saves Phase P from re-deriving the
same bit positions this phase's own research pass already confirmed against the spec. The
sign-extension check (`VA[63:39] == VA[38]`) and the megapage/gigapage misalignment rules are
deliberately **not** pre-encoded — those are logic Phase P should design fresh against its own
walker structure, not field offsets Phase O should guess the shape of.

## Real bugs/findings

None in the RTL — this phase's own testbench (`tb_csr_rv64_priv_o4.v`) passed on the first full run
once its own test-sequencing issues (below) were fixed. Two real bugs were found in the *test*,
worth recording since they're easy to repeat in a future phase's own directed test against this
same CSR:

1. **Checking a derived signal (`satp_mode_w`/`satp_ppn_w`) against a fixed simulation-time delay,
   when the CSR it derives from (`satp`) is deliberately overwritten multiple times later in the
   same program.** The first version of this test waited a flat `#600` then checked every signal at
   once — `satp_mode_w`/`satp_ppn_w` were checked against their *first* write's expected values, but
   by t=600 `satp` had already been overwritten twice more (a Bare-mode write, then the final
   Sv39-look-alike pattern for the `mret` check), so both checks failed against stale expectations.
   Fixed by synchronizing on the exact architectural register (`wait (dut.m_Register.regs[N] ===
   <expected>)`) that the same instruction sequence writes immediately after each `satp` write, then
   sampling the derived signals that same cycle — before the next `satp`-changing instruction can
   run. (A first attempt at this fix used `wait (regs[N] !== 64'bx)` instead of the exact expected
   value — wrong, since this core's register file resets to a defined 0, not X, so that condition
   was already true at time 0 and fired before the real write ever happened.)
2. **`mret` returning to M instead of U.** The test's own `mstatus` all-1s write (exercising the new
   UXL/SXL override) also sets `MPP`=3 (M) as a side effect, since `MPP` is one of the existing real
   `mstatus` fields an all-1s write touches — and `mret` correctly honors whatever `MPP` says
   regardless of anything else in the test. The later `mret` (meant to drop to U-mode, mirroring
   `tb_mmu_disabled_rv64_m7.v`'s own "MMU forced off" proof) therefore returned to M, not U — a
   weaker proof than intended, since M-mode already bypasses translation unconditionally regardless
   of this phase's own `translate_enable` gate. Fixed by explicitly clearing `mstatus` (`csrrw x0,
   mstatus, x0`) right before the final `mret`, so `MPP`=0 (U) going in — this core's own `mstatus`
   is never checked again after the earlier UXL/SXL readback, so a full clear is safe.

## Alternatives considered

**Widen `satp_ppn_val` to 44 bits now, matching Sv39's real PPN width.** Rejected: its only
consumer (`Ptw.v`'s port) is Sv32-shaped and entirely Phase P's own job to rewrite; widening the
wire today without a matching consumer just moves the same conceptual change earlier for no benefit,
and risks a real port-width-mismatch warning against `Ptw.v`'s still-22-bit-wide formal port.

**A continuous-assignment ternary for the XLEN-conditional `satp` decode**, instead of a procedural
`if`. Rejected in favor of the proven idiom: `DataMemoryBRAM.v`'s own precedent (`docs/adr/0028`)
specifically confirmed the procedural-`if`-around-an-out-of-range-slice form compiles warning-free;
a ternary's two branches don't have the same "one side is genuinely never elaborated" property in
every simulator, and this codebase has never tested that specific shape.

**Pre-encoding the Sv39 sign-extension check or megapage/gigapage alignment logic as constants now**,
alongside the VPN/PTE-PPN bit positions. Rejected: those are real walker *logic*, not field offsets
— Phase P should design them fresh against its own new `Ptw.v` structure, matching how `docs/
adr/0022`'s own Phase F4 designed Sv32's megapage check as part of building `Ptw.v` itself, not as
a pre-declared constant from an earlier phase.

## Validation strategy

New directed test `tb_csr_rv64_priv_o4.v` (`sim/programs/csr_rv64_priv_o4.s`), `XLEN(64)`: mstatus
UXL/SXL read back as 2 alongside the existing real low-bit fields; `satp`'s raw storage is unmasked
at full 64-bit width and its derived `satp_mode_w`/`satp_ppn_w` correctly decode a real Sv39-shaped
MODE/ASID/PPN pattern (not Sv32's old bit-31 read); a second write with MODE=0 (Bare) in the same
field position correctly decodes `satp_mode_w=0`, proving the decode tracks the actual field rather
than a "satp is nonzero" heuristic; and — the phase's own central safety property — even with a
real Sv39-look-alike `satp` pattern live and privilege genuinely dropped to U via `mret`, the
fetch/store/load sequence proceeds fully untranslated and zero real `Ptw.v` walks occur, confirming
`translate_enable`'s `XLEN==32` gate is unaffected by `satp_mode_w` now correctly reading 1 for a
pattern that used to read 0 under the old Sv32-only decode.

Full bar: 84/84 directed tests (`bash sim/run_tests.sh`, one new), zero-warning `iverilog -Wall
-g2005 -I design -tnull design/*.v` compile, constrained-random cross-check clean at XLEN=32 with
`--mmu` (real Sv32 regression, confirming this phase's `satp`-decode change is genuinely
XLEN-conditional and doesn't disturb the Sv32 path) and at XLEN=64 (confirming zero behavior
change). No `sim/tools/iss.py`/`random_gen.py`/`run_random_tests.py` changes were needed: their
MMU/privilege logic is reached only at `xlen==32` (confirmed by direct research-pass file reads),
entirely unaffected by this phase's RTL, and the existing `--xlen 64 --mmu` mutual-exclusion guard
already prevents the untested combination from ever running.

`translate_enable`'s own expression at `riscvpipeline.v` is confirmed byte-for-byte unchanged by
this phase (`(XLEN == 32) && satp_mode_w && (priv_mode_w != \`PRIV_M)`) — the phase's own directed
test exercises this directly (zero `Ptw.v` walks with a live Sv39-look-alike `satp` and U-mode
privilege), not just by inspection.

## Future improvements

Phase P (Sv39 MMU/TLB/PTW, a genuinely new design against RV64/Sv39 — not a port of the existing
Sv32 `Tlb.v`/`Ptw.v`, per `docs/ROADMAP_VISION.md`'s own explicit framing) is next. It will finally
consume this phase's pre-declared VPN/PTE-PPN constants, widen `satp_ppn_val`/`Ptw.v`'s own port
atomically together, and flip `translate_enable`'s gate from `XLEN==32` to a real Sv39 MODE check —
none of which this phase attempts. `sstatus`'s own UXL mirror (real per spec, distinct from
`mstatus`'s own fixed value) remains unbuilt since nothing needs it yet; add it if/when a future
phase does. Generation 3's later phases (Q: memory scale-up, R: UART/Timer Linux-driver
compatibility redesign, S: hand-rolled SBI firmware + DTB, T: load `UCanLinux/riscv64-sample`'s
prebuilt kernel+rootfs and attempt boot) are unblocked to start once Phase P closes.
