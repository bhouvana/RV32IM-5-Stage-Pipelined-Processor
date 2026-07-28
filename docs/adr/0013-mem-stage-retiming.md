# ADR 0013: MEM-stage retiming — wiring the synchronous-read BRAM into the live pipeline

## Problem

`docs/adr/0012` built and unit-tested `design/DataMemoryBRAM.v`, a
synchronous-read (BRAM-inferable) replacement for the combinational-read
`DataMemory.v`, but deliberately stopped short of wiring it into the live
pipeline: a registered read makes a load's result available one cycle later
than before, which ripples into every pipeline register between EX/MEM and
writeback. That ADR scoped the actual retiming as its own future milestone,
comparable to the multi-cycle divider integration (`docs/adr/0009`), and
`docs/ROADMAP.md` named it the largest remaining Phase 7 item. This ADR does
that retiming.

## Design

### The interlock shape

`docs/adr/0009` established a three-way split for the divider's multi-cycle
EX stage: freeze PC/`reg1`, `hold` `reg2` (the register sitting just *before*
the slow computation), and feed a bubble into `reg3` (the register sitting
just *after* it) every intermediate cycle. The MEM-stage retiming needs the
exact same shape, one stage later: the slow computation (`DataMemoryBRAM`'s
registered read) now sits between `reg3` (EX/MEM) and `reg4` (MEM/WB), so the
freeze/hold boundary shifts down by one register.

`mem_stall` is true for exactly the one extra cycle a fresh load spends in
`reg3` before its result is valid:

```verilog
wire mem_stall = memRead_regem && !mem_stall_done_r;
```

`mem_stall_done_r` tracks "has the load currently latched in `reg3` already
had its one stall cycle," reset to 0 whenever `mem_stall` was 0 last cycle —
which is exactly when `reg3` is about to accept a new occupant (fresh load or
otherwise). This feeds:

- **`pc_stall`** (PC/`reg1`) and **`reg2`'s `hold`**: both extended from
  `stall | div_stall` to also include `mem_stall`, so nothing advances past
  `reg2` while `reg3` isn't ready to accept it.
- **`reg3`'s `hold`** (new port, same empty-branch idiom `docs/adr/0009` used
  for `reg2`): freezes `reg3` itself while the load it's holding hasn't come
  back from memory yet — without this, `reg2`'s next instruction would
  overwrite `reg3` before the load's address/control had done their job.
- **`reg4`'s `hold`** (new port, same idiom again): see below — this is
  *not* the bubble-based approach `docs/adr/0009` used for `reg3`, and that
  difference is the interesting part of this ADR.

No changes were needed to `Hazard.v` or `Forward.v`. The existing 1-cycle
load-use stall (`Hazard.v`) combined with `reg2`'s new `mem_stall`-driven
hold composes automatically into the 2-cycle delay a load-dependent
instruction now needs: the load-use bubble already parks the dependent
instruction one cycle before the load reaches `reg3`; `reg2`'s hold (for the
*load's own* `mem_stall`, one cycle later) transparently adds the second
cycle by freezing whatever `reg2` currently holds — bubble or real
instruction — without needing to know why. This was verified directly
(`sim/programs/load_use_stall.s` still passes unmodified), not just assumed.

### Why `reg4` needed a hold, not a bubble

The first attempt mirrored `docs/adr/0009`'s `reg3_bubble` pattern exactly:
feed `reg4` a bubble (zeroed `regWrite`/`memtoReg`/destination register)
during `mem_stall`, reasoning that this prevents `reg4` from latching a
load's not-yet-valid `readData` prematurely — the same reasoning that made
`reg3_bubble` correct for the divider.

This is wrong here for a reason that doesn't apply to the divider case:
`reg4` (MEM/WB) is also the sole source of `writeData_regwb` for
MEM/WB forwarding. When `reg2` is held during `mem_stall` (waiting for a
load in `reg3` to finish, for a completely unrelated reason), whatever
instruction `reg2` is holding may itself depend on forwarding a value that
happens to currently be sitting in `reg4` — and a bubble fed into `reg4`
*every* `mem_stall` cycle evicts that value one cycle before the held
instruction actually needs it, replacing a real, valid MEM/WB-forwardable
result with a zeroed bubble. `reg3_bubble` never has this problem because
`reg3`'s only consumers are EX/MEM forwarding (which only ever wants
`reg3`'s *current* occupant, not something it held earlier) and `reg4`
itself; `reg4` uniquely needs to keep presenting an old value for forwarding
purposes even while the pipeline behind it is stalled.

Fixed by giving `reg4` a genuine `hold` input instead — the same
empty-branch idiom as `reg2`/`reg3`, freezing `reg4`'s output completely
during `mem_stall` rather than replacing it with a bubble. This means
`reg4` may present the *same* completed instruction's `regWrite`/
`writeData` for two consecutive cycles when a load is stalling — harmless,
since it's a repeated write of the identical value to the identical
register (not a distinct spurious write the way an *unbubbled* `reg3`
would have been in the divider case), and `reg4` only ever actually holds a
load's real completed data starting the exact cycle it's valid (`mem_stall`
guarantees this), so no not-yet-valid `readData` is ever latched either.

## Two real bugs found during verification

Both found by actually running the suite, not by reasoning about the design
statically — consistent with this project's verification standard.

### 1. Back-to-back loads defeat a memory-sourced "valid" signal

The first implementation derived `mem_stall` from a new `readDataValid`
output added to `DataMemoryBRAM.v` (mirroring its internal `mem_read_r`
register: "was a read requested last cycle"), instead of tracking readiness
in the pipeline itself. This passed the full directed suite except
`mem_bytes.s`: a zero-extending load (`lbu`/`lhu`) immediately following a
sign-extending load (`lb`/`lh`) at the same address came back with the
*sign-extended* value from the previous load instead of correctly
zero-extending its own.

Root cause: a load held in `reg3` for its stall cycle keeps `memRead`
asserted for two consecutive cycles. When the *next* load freshly arrives in
`reg3` right after, `DataMemoryBRAM`'s `mem_read_r` is still reporting the
*previous* load's read as having just completed — it has no way to
distinguish "the same request, still in flight" from "a new request that
happens to look the same," because it only ever saw a continuously-asserted
`memRead` across the boundary. This let the new load's `mem_stall` evaluate
to false on its very first cycle, causing `reg4` to latch its (not yet
funct3-extended) data one cycle early — using the *previous* load's
still-registered `funct3_r`.

This is exactly the class of bug `docs/adr/0009` documented for the
divider's `busy`/`done` re-triggering ("an edge case at the boundary between
'still busy' and 'idle again,' missed because a bare level signal can't
distinguish 'still the same request' from 'a new request that happens to
look the same'"), recurring here for the same underlying reason. Fixed by
reverting `DataMemoryBRAM.v` to its original, unmodified form (removing the
`readDataValid` port entirely) and tracking readiness with a
pipeline-local register (`mem_stall_done_r`, described above) keyed to
`reg3`'s own occupancy rather than the memory's raw request history.

### 2. A bubbled `reg4` evicts an unrelated instruction's forwardable result

Covered in detail above ("Why `reg4` needed a hold, not a bubble"). Passed
the entire directed suite (including the new bug-1 fix) but failed
constrained-random cross-checking at seed 39: `ori x1,x21,38` followed by an
unrelated load (`lh x27,...`, no register overlap with `x1`) followed by
`sll x12,x1,x4` computed `x12=0` instead of the correct `0x26` — `sll`
needed `x1` forwarded from MEM/WB, but the bubble fed into `reg4` during the
intervening load's `mem_stall` had already zeroed out `ori`'s still-needed
result one cycle before `sll` actually reached EX (delayed exactly one cycle
by the same `mem_stall` holding `reg2`).

This is the more interesting of the two bugs: it has nothing to do with
load-use hazards in the traditional sense (`Hazard.v` never fires here,
correctly — `sll` doesn't depend on the load at all) and would never surface
from a directed test written with load-use hazards in mind, only from an
instruction sequence where something *unrelated* to a load happens to be
riding out that load's stall cycle in `reg2` while depending on something in
`reg4`. This is exactly the kind of interaction constrained-random testing
(`docs/adr/0010`) exists to find. A permanent directed regression test
(`sim/programs/mem_stall_forward.s` / `tb_mem_stall_forward.v`) reproduces
this exact shape so it can't regress silently; confirmed to actually fail
without the `reg4` hold fix (verified directly, not just by removing the
fix and assuming the test would catch it).

## Alternatives considered

- **Derive `mem_stall` from a memory-provided valid signal** (bug 1's first
  attempt). Rejected once it demonstrably failed on back-to-back loads — see
  above. Tracking readiness against the *consuming* register's occupancy,
  not the memory's own request history, is the more robust layering and
  avoids a second piece of state (the memory's) that can drift out of sync
  with what the pipeline actually needs to know.
- **Bubble `reg4` instead of holding it** (bug 2's first attempt). Rejected
  once it demonstrably failed via random cross-checking — see above.
- **Extend `Hazard.v`'s load-use stall to 2 cycles explicitly**, rather than
  relying on the emergent composition of the existing 1-cycle stall with
  `reg2`'s new `mem_stall`-driven hold. Rejected: the emergent behavior is
  correct (verified by `load_use_stall.s` passing unmodified) and needs no
  new logic in `Hazard.v` at all; an explicit 2-cycle stall would duplicate
  information `reg2`'s hold already encodes and would need its own separate
  justification for why 2 (rather than some other number) is right, whereas
  the composition falls out directly from the interlock's structure.

## Validation strategy

- Full directed suite: 23/23 tests, 128 checks (22 pre-existing tests, 122
  checks, plus the new `mem_stall_forward.s`, 3 checks) — including
  `mem_bytes.s` (back-to-back loads, caught bug 1) and `load_use_stall.s`
  (unmodified, confirms the load-use composition claim above) and
  `store_load.s` (basic round trip through the new synchronous memory).
- Constrained-random cross-check against the independent ISS reference
  model: 200/200 at the default program length, plus 150/150 at 24
  instructions/program across a disjoint seed range (caught bug 2 at the
  default length before this expanded run). ISS itself needed no changes —
  it checks final architectural state, which this retiming doesn't alter,
  only timing.
- `sim/tools/coverage_report.py`: run clean after the change, no new gaps
  introduced (the pre-existing branch-direction and `ALUCTL_ILLEGAL` gaps
  are unrelated and unchanged).
- `iverilog -Wall -g2005 -I design -tnull design/*.v`: clean, zero warnings
  — incidentally also removes the `@* is sensitive to all 128 words in
  array` warnings the old `DataMemory.v` produced, since it's now deleted.
- `design/DataMemory.v` deleted: fully superseded, unreferenced by any
  `` `include`` or instantiation once every `sim/tb/*.v` file was updated to
  `DataMemoryBRAM.v` (confirmed by grep before deleting), matching this
  project's established practice of removing dead code once it's genuinely
  dead rather than leaving it as an unused historical artifact.

## Future improvements

- `InstructionMemory.v`'s fetch-stage read is still combinational, the same
  BRAM-inference gap `docs/adr/0012` flagged for data memory — untouched by
  this ADR. Retiming it would need an analogous interlock one stage earlier
  in the pipe (freezing PC itself for a cycle on every fetch, or a fetch
  buffer), a different shape than this one since there's no `reg` upstream
  of PC to hold.
- The MEM-stage interlock adds exactly one stall cycle per load,
  unconditionally, regardless of whether the following instructions
  actually depend on it — a deliberate simplicity/performance tradeoff (see
  Design), consistent with this project's existing divider (a 32-cycle
  restoring divider, not the fastest possible algorithm). Revisit if real
  Fmax/IPC numbers ever motivate reducing the per-load penalty.
- Real hardware validation (`docs/adr/0012`'s remaining item) is now
  unblocked at the RTL-integration level -- `DataMemoryBRAM.v` is wired into
  the live pipeline and verified in simulation, but nothing has touched an
  actual board yet.
