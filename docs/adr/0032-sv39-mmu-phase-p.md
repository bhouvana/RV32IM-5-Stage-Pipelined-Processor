# ADR 0032: Sv39 MMU/TLB/PTW (Generation 3, Phase P)

## Problem

Phase O (`docs/adr/0031`) did the RV64/Sv39 CSR-side groundwork — `mstatus.UXL/SXL` fixed-2
read-mux constants, `satp`'s MODE/ASID/PPN decode made genuinely XLEN-conditional — with a
deliberate, explicit constraint: **zero live translation-behavior change**. `translate_enable`
stayed gated `(XLEN==32) && ...`, so Sv39 didn't exist as real hardware yet. Per
`docs/ROADMAP_VISION.md`'s own framing, Generation 3's MMU work is explicitly a **new design**
against RV64/Sv39, not a port of the existing Sv32 `Tlb.v`/`Ptw.v` (Phase F, `docs/adr/0022`):
Sv39 is a real 3-level walk over 8-byte PTEs with two possible superpage leaf points (a 1GB
gigapage at level 2, a 2MB megapage at level 1), versus Sv32's 2-level/4-byte-PTE/single-megapage
shape. Phase P is that new design, plus wiring it live, plus the full verification-tooling stack
(ISS walker, MMU-aware random generator) the original Sv32 MMU needed across its own F1-F9 arc.

Three scope questions confirmed via `AskUserQuestion` (all recommended/most-ambitious options,
matching this project's own repeated precedent from every prior phase):

1. **Full 3-level walk with real gigapage/megapage leaf support**, not a 4KB-leaf-only walker.
2. **Separate new modules** (`Tlb39.v`/`Ptw39.v`, XLEN-selected) rather than folding Sv39 into the
   existing Sv32 `Tlb.v`/`Ptw.v` — zero regression risk to the existing Sv32 MMU corpus.
3. **Truncate this walker's own formed addresses** to what the core's real (tiny) memory can hold,
   exactly mirroring Phase F4's Sv32 decision — PTEs/roots still decoded at full spec width; only
   the addresses the walker itself forms (table addresses, final translated PPN) truncate to 20
   bits, since this core's actual physical memory is tens of KB, not gigabytes.

## Design

Sequenced into six sub-phases, deliberately mirroring Phase F's own F4→F5→F6→F7→F8→F9 arc (standalone
modules → wire live → ISS walker → MMU-aware generator → volume sweep → docs), since that arc was
this project's own proven template for building a page-table walker safely.

### P1-P2: `design/Tlb39.v` + `design/Ptw39.v`, standalone

**`Tlb39.v`** is a structural copy of `Tlb.v` (unified, tagged, direct-mapped, two independent
combinational read ports, `NUM_ENTRIES=16` default, synchronous fill, unconditional `flush_all`) —
the only change is a wider 27-bit VPN tag (`va[38:12]`, Sv39's three 9-bit VPN fields concatenated)
versus Sv32's 20-bit `va[31:12]`.

**`Ptw39.v`** extends `Ptw.v`'s `busy`/`start`/`done`-pulse state machine from 2 levels to 3
(`S_IDLE → S_L2_WAIT/DECODE → S_L1_WAIT/DECODE → S_L0_WAIT/DECODE`). The load-bearing design
insight, worked out by hand before any RTL: the low-20-bits-truncated PPN slice (`pte[29:10]`) sits
at the **identical bit position** in both the 32-bit Sv32 PTE and the 64-bit Sv39 PTE, since PPN
starts at bit 10 in both formats regardless of total width — the truncation machinery itself needed
zero format-specific logic. Only the superpage *reconstruction* built on top of that slice differs
per leaf level:

- Level-0 leaf (4KB page): the slice is the answer as-is, identical to `Ptw.v`'s own case.
- Level-1 leaf (2MB megapage): alignment requires real PPN[0] (`pte[18:10]`) be zero; result is
  `{pte_ppn20[19:9], vpn0}`.
- Level-2 leaf (1GB gigapage): alignment requires real PPN[1:0] (`pte[27:10]`) be zero; result is
  `{pte_ppn20[19:18], vpn1, vpn0}`.

Sv39's 8-byte PTEs mean each level's table index stride is `vpn*8` (`{vpn, 3'b000}`), not Sv32's
`vpn*4`. Permission checks are the identical 2-part test `Ptw.v` uses at every leaf point
(`(fetch?X:store?W:R) && (priv_is_u?U:!U)`, no SUM).

### P3: wired live into fetch and load/store

A research pass (an `Explore` agent mapping every Sv32 wiring site in `riscvpipeline.v`/`CSR.v`)
found a real structural gift before any RTL changed: every miss/fault/permission/latch signal
downstream of the `Tlb`/`Ptw` instantiations (`itlb_hit`, `ls_hit`, `ptw_busy`, `ptw_done`, the
`dtlb_vaddr_r`/`dtlb_store_data_r` forwarding-drift-avoidance latches, `ptw_abandoned_r`, the
shared-bus mux) is written purely in terms of plain wire names, never referencing `Tlb`/`Ptw` by
module name — so wiring Sv39 live needed **zero changes** to that ~350-line block. Only the
instantiation sites themselves needed an XLEN-selected `generate if (XLEN==32) ... else ...`
(mirroring `CACHE_MODE`'s own "unselected branch costs nothing" convention).

Two narrow wiring gaps found by design/research, not by running:

1. `CSR.v`'s `satp_ppn_val` port was 22 bits (Sv32's real PPN width, deliberately left unwidened
   by Phase O). Widened to 44 bits: XLEN=32 zero-extends its existing value (bit-exact), XLEN=64
   decodes the full 44-bit field with no truncation at the CSR layer (`satp`'s PPN is a root
   pointer, not an address the CSR itself forms — `Ptw39.v` does its own low-20-bits truncation
   internally).
2. The `wb_m_funct3` bus force (Phase F5's own bug #4 fix, forcing `lw`'s `3'b010` onto the bus
   during any Ptw read, since `RamWishboneAdapter`'s `funct3` side-band otherwise reflects the real
   LSU's stale value) needed a Sv39 twin: Sv39 PTEs are 8 bytes, needing `F3_LOAD_LD` (`3'b011`)
   instead — made XLEN-conditional at both bus-mux `generate` branches (`CACHE_NONE`/
   `CACHE_WRITEBACK_SETASSOC`).

## Real bugs/findings

1. **Icarus scopes a generate-if body even without an explicit label** (an unlabeled one just gets
   an implicit `genblk#` name) — three existing testbenches (`tb_mmu_translate_f5.v`,
   `tb_csr_rv64_priv_o4.v`, `tb_mmu_disabled_rv64_m7.v`) tap `dut.m_Ptw.done` directly as a
   walk-count debug probe, which broke once the `Ptw`/`Ptw39` instantiation moved inside a generate
   block. Fixed with stable explicit branch names (`gen_mmu_ptw_sv32`/`gen_mmu_ptw_sv39`, etc.) and
   updated the three taps to the correct scope-qualified path.
2. **One test's own premise was invalidated by this phase, not broken by it**: `tb_csr_rv64_priv_o4.v`/
   `csr_rv64_priv_o4.s` (Phase O's own regression test) specifically proved `translate_enable`
   stayed force-disabled at XLEN=64 even with a live-looking Sv39 `satp` pattern — a guarantee
   Phase P3 intentionally removes. Updated the program to leave `satp` genuinely at Bare (MODE=0)
   before its final section instead of restoring the old look-alike pattern; the test's remaining
   valid purpose (CSR-decode groundwork + ordinary Bare-mode+U-mode untranslated execution) is
   unaffected. `tb_mmu_disabled_rv64_m7.v`/`.s` needed no logic change — its own `satp` pattern
   (`MODE=1` at Sv32's old bit-31 position) still correctly decodes as Bare under Sv39's real
   bit[63:60] field, now for the right structural reason instead of an XLEN gate.
3. **The new end-to-end integration test's own fixed `#500` wait** (`mmu_translate_sv39_p3.v`,
   copied from `mmu_translate_f5.s`'s own budget) cut a real D-side 3-level walk off mid-flight at
   `S_L1_DECODE`, confirmed via a direct debug tap on `m_Ptw.state` — a genuine 3-level walk takes
   more cycles per walk than Sv32's 2-level one, and this program has more setup instructions
   before its D-side access than F5's does. Fixed by widening the budget to `#700`.
4. **`sim/tools/iss.py`'s own `store_mem_byte`/`load_mem_byte` mask addresses with `mem_size - 1`**,
   whose own header comment documents "`mem_size` is always a power of 2" — a real, pre-existing
   assumption this phase's own P5 generator work violated by choosing `mem_size=12288` (3×4KB, not
   a power of 2) for the Sv39 MMU-aware random generator's page-table-plus-random-body budget.
   `12288 & (12288-1)` silently produces the wrong mask (e.g. address `0x1000` maps to physical
   index `0`, not `0x1000` — bit 12 isn't set in `0x2FFF`), corrupting every store/load beyond the
   first table write. Found immediately by the first 5-seed smoke sweep (0/5, all failing
   identically), root-caused by single-stepping the ISS through the exact prefix instruction
   sequence and comparing against the RTL's own correct behavior. Fixed by using `16384` (4×4KB, a
   real power of 2) instead — one spare page of headroom, same margin Sv32's own 8192 (2×4KB) has.

No RTL bugs were found in `Tlb39.v`/`Ptw39.v`/the P3 wiring itself — a genuine first for this
project's "wire a new subsystem live" bug class (every prior instance, including Phase F5's own six
bugs, found its problems only by running). Both real bugs in this phase's *tooling* (findings 3-4
above) were found by running, consistent with the project's established pattern for that side.

### P4: `sim/tools/iss.py` Sv39 walker

`translate()` became a dispatcher (Sv32 at XLEN=32, Sv39 at XLEN=64, M-mode/Bare-mode bypass at
either) delegating to a renamed `_translate_sv32` (previously `translate`'s own body, unchanged)
and a new `_translate_sv39`, matching `Ptw39.v`'s bit-for-bit logic including the identical
truncation/reconstruction algebra described above. A new `_read_pte64` helper reads the 8-byte PTE
(little-endian, matching `_read_pte`'s own 4-byte convention). Manually verified against the exact
page-table scenario `mmu_translate_sv39_p3.s`'s own RTL run already proved correct (fetch, store,
load round-trip, and a deliberate permission-fault case checked for the right `mcause`) before
trusting it in the random-test harness — the same "verify against a known-correct RTL scenario
first" discipline Phase F6 used for Sv32's own ISS walker.

### P5: `random_gen.py`/`run_random_tests.py` Sv39-aware generator

Mirrors Phase F7's own "generator-guaranteed-valid identity mapping" philosophy exactly: `mmu=True`
at `xlen>=64` builds a real, M-mode-constructed, always-valid 3-level Sv39 identity mapping (VA==PA
everywhere, `satp_ppn=0`, one PDE/PTE per level, all index 0, permissions `V|R|W|X|U`) before
`mret`-ing to U-mode, so every random instruction that follows is a genuinely translated access with
nothing for a page fault to legitimately hit. The 64-bit `satp` constant (`8<<60`, Sv39's MODE field
at bit 60) uses `const64_to_reg_instrs`, not the 32-bit-only `const_to_reg_instrs` Sv32's own prefix
uses. The `--xlen 64 --mmu` mutual-exclusion guard `run_random_tests.py` had carried since Phase M7
(when Sv39 didn't exist) was removed.

### P6: volume random sweep

100/100 fresh Sv39-MMU-enabled seeds (`--mmu --xlen 64`) clean, on top of the regression sweeps
already run for P3-P4 (100/100 XLEN=32 non-MMU, 60/60 XLEN=64 non-MMU, 60/60 Sv32-MMU-enabled — the
last re-run after the `iss.py` `translate()` refactor specifically to confirm the Sv32 path's
behavior was preserved byte-for-byte by the dispatcher change).

## Alternatives considered

**Reuse/re-parameterize `Tlb.v`/`Ptw.v` for both Sv32 and Sv39** (e.g. an XLEN-conditional
`generate` inside the existing modules) instead of building `Tlb39.v`/`Ptw39.v` as separate files.
Rejected (confirmed via `AskUserQuestion`): two genuinely different walk depths/PTE layouts crammed
into one module via `generate` risks exactly the class of subtle X-propagation/priority bug this
project keeps finding when one module tries to serve two shapes at once, and offers zero benefit
over two small, independently-testable modules — matching this project's own `CACHE_MODE`/
`PIPELINE_PROFILE`/`BRANCH_PREDICTOR` precedent of a distinct module per swappable-subsystem mode
rather than one module with two internal shapes.

**A 4KB-leaf-only Sv39 walker** (no gigapage/megapage support), simpler and lower bug-surface.
Rejected (confirmed via `AskUserQuestion`) in favor of full 3-level + superpage support, matching
this project's own repeated "most ambitious option" precedent — and because a Sv39 MMU without any
superpage support would be a poor foundation for the eventual Linux boot (Generation 3's own stated
goal) a real kernel's own page tables are likely to use superpages for.

**Widen every relevant bus signal to the real 56-bit Sv39 physical address space now**, instead of
truncating the walker's own formed addresses to 20 bits. Rejected (confirmed via `AskUserQuestion`):
this core's actual physical memory is tens of KB, nowhere near needing more than 32 bits of real
address space; a full-width change would be large and invasive ahead of Phase Q (memory-capacity
scale-up), which is explicitly where address-width growth is already scheduled to happen.

## Validation strategy

New unit tests `tb_tlb39_unit.v` (23 checks, mirrors `tb_tlb_unit.v`'s case list at the wider VPN)
and `tb_ptw39_unit.v` (42 checks, mirrors `tb_ptw_unit.v`'s structure, extended for gigapage/
megapage success and misalignment cases). New integration test `mmu_translate_sv39_p3.s`/`.v` (a
real 3-level walk on both fetch and load/store, live through the pipeline, walk-count-tapped to
confirm exactly 2 real walks with TLB reuse thereafter). `tb_csr_rv64_priv_o4.v`/
`tb_mmu_disabled_rv64_m7.v` updated for this phase's own removal of Phase O's "stays off regardless"
guarantee (see Real bugs/findings above).

Full bar: **87/87 directed tests** (`bash sim/run_tests.sh`, up from 84/84), zero-warning
`iverilog -Wall -g2005 -I design -tnull design/*.v` compile across the whole tree, 100/100
constrained-random cross-check at XLEN=32 (non-MMU regression), 60/60 at XLEN=64 (non-MMU
regression, `--n-instrs 8` — the default 16 overflows the 128-byte program budget once XLEN=64's
larger constant-building overhead is accounted for, a pre-existing characteristic of this XLEN
unrelated to this phase's own changes), 60/60 Sv32-MMU-enabled (`--mmu`, XLEN=32, re-run after the
`iss.py` refactor to confirm zero behavior change to the existing path), and 100/100 Sv39-MMU-enabled
(`--mmu --xlen 64`) — Phase P6's own volume sweep.

## Future improvements

Phase Q (memory-capacity scale-up — real MBs for an actual kernel image, per
`docs/ROADMAP_VISION.md`) is next; it's the natural place to revisit this phase's own 20-bit PPN
truncation once the core's real memory actually needs more than that. `sfence.vma`'s TLB flush and
its own privilege check are wired identically for Sv39 as Sv32 (unconditional whole-TLB flush, S/M
only) — not re-verified with a Sv39-specific directed test this phase, since the mechanism itself
(the `flush_all` pulse, `sfence_priv_violation`) is entirely XLEN-independent and already covered by
Sv32's own tests; worth a dedicated Sv39 `sfence.vma` test if a future phase's work depends on it
specifically. No selective ASID invalidation, no SUM/MXR, no A/D auto-set — all inherited unchanged
from Sv32's own scoping defaults (`docs/adr/0022`), not re-litigated here.
