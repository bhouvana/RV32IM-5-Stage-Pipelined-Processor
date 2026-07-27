# ADR 0012: FPGA readiness — memory parameterization, a standalone BRAM-friendly memory, and a bring-up top level

## Problem

`docs/ARCHITECTURE.md` §9 and `docs/ROADMAP.md` Phase 7 both flagged the same
blocker: `DataMemory.v`'s read is combinational (`always @(*)`), which
simulates fine but is not directly BRAM-inferable on Xilinx/Intel/Lattice
toolchains, which want a registered read for single-cycle timing closure.
Phase 7 also named two smaller, previously-unaddressed gaps: every memory
size in the design is a literal `128` rather than a `parameter` (blocking
even trying a larger memory on a real board), and there was no top-level
wrapper or constraints file at all -- nothing to actually load onto hardware.

## Scope decision: what this ADR does and does not do

The full fix for the combinational-read problem is retiming
`riscvpipeline.v`'s MEM stage: a registered read makes load data available
one cycle later than today, which ripples into `Forward.v` (a new forwarding
source), `Hazard.v` (loads would need a stall/bubble the way `docs/adr/0009`
added for div/rem, not just the existing load-use case), and `reg4`'s
timing. That is real, invasive, pipeline-wide work -- comparable in scope to
the multi-cycle divider integration, and, unlike that integration, would be
retrofitted onto a MEM stage every existing test already depends on timing-
wise. Attempting it as a drive-by change alongside CSR/exceptions and other
Phase-5-adjacent work, without a dedicated verification pass built around
the new timing, would risk regressing a core that is currently 22/22 (114
checks) directed and 60/60 random-cross-checked clean. That risk isn't
justified by "readiness" scope, so this ADR deliberately stops short of it.

What this ADR does deliver, all of it low-risk and independently useful:

1. **Memory size parameterization** (`DataMemory.v`, `InstructionMemory.v`,
   threaded through `PIPELINED`'s new `MEM_SIZE_BYTES` parameter). Every
   existing test's default (128 bytes) is unchanged; this only removes a
   hardcoded literal that blocked ever trying a different size, for FPGA or
   for the Phase 6 research-platform goal alike. `DataMemory.v`'s reset
   block also lost 128 lines of unrolled per-index assignments in favor of
   a `for` loop over the new `SIZE_BYTES` parameter -- same reset values,
   less code, and no longer hardcoded to exactly 128 entries.
2. **`DataMemoryBRAM.v`**: a new, standalone synchronous-read data memory,
   proven correct by its own unit test (`sim/tb/tb_data_memory_bram.v`,
   8 checks) but *not* wired into `PIPELINED` -- see Scope decision above.
   It exists as the concrete building block the eventual retiming work
   would integrate, validated in isolation first rather than left as an
   unverified sketch in an ADR's prose.
3. **`debug_x10`**: a new read-only output port on `PIPELINED`, tapping
   `x10`/`a0` (the standard RISC-V calling-convention "result" register) via
   `m_Register.regs[10]`. Purely additive -- every existing testbench
   leaves it unconnected, which is valid Verilog and changes nothing about
   simulated behavior. Without *some* way to observe CPU state from outside,
   a bring-up top level has nothing to show on an LED.
4. **`fpga/top.v`** + **`fpga/constraints_template.xdc`**: a vendor-neutral
   bring-up wrapper (reset synchronizer, a heartbeat LED independent of the
   CPU so a blank board vs. a broken core are distinguishable, `leds` driven
   from `debug_x10`) and a generic, explicitly-not-board-specific Xilinx XDC
   template with placeholder pin names and instructions to copy-and-fill
   rather than edit in place.

## A compile-time-only bug this surfaced

Adding `debug_x10` as a new output port broke every existing testbench's
`PIPELINED #(...) dut(clk, start);` positional instantiation -- Icarus
Verilog's elaborator requires an exact positional port count match ("Wrong
number of ports. Expecting 3, got 2"), rather than silently leaving the new
trailing output unconnected the way some tools/flows allow. Fixed by
converting all 23 occurrences (every `sim/tb/*.v` file, plus
`sim/tb/gen_trace.v` and `sim/tb/dump_regs_template.v`) to named port
connections (`dut(.clk(clk), .start(start))`), which are immune to this
class of break entirely -- worth treating as the default instantiation style
going forward, not just a one-off fix, since positional instantiation of a
multi-port module is exactly the kind of thing that breaks silently (or, as
here, loudly but broadly) the next time the module's port list changes.

## Alternatives considered

- **Do the full MEM-stage retiming now.** Rejected for this pass -- see
  Scope decision. Flagged as the natural next FPGA-track milestone, not
  abandoned.
- **Skip the standalone `DataMemoryBRAM.v` entirely and just describe the
  retiming in prose**, since it isn't wired in yet anyway. Rejected: an ADR
  section describing an untested design is exactly the kind of claim this
  project's verification-first practice (`docs/adr/0007`, `0010`) exists to
  avoid making. Building and unit-testing the module now means the eventual
  integration work starts from a proven component, not a paper design.
- **Hierarchical reference from `fpga/top.v` straight into
  `dut.m_Register.regs[10]`** instead of adding `debug_x10` as a real port.
  Rejected: works in simulation (as `check_reg` in `sim/tb/check_tasks.vh`
  already relies on for exactly this reason) but is not something every
  synthesis flow is guaranteed to support the same way, and a bring-up
  wrapper is specifically the file where "will this actually synthesize"
  matters most. A real port is the portable choice.

## Validation strategy

- `sim/tb/tb_data_memory_bram.v`: standalone unit test for the new module --
  reset-clears-memory, `sb`/`sh`/`sw` round trips through every
  signed/unsigned/width combination `DataMemory.v`'s own directed test
  (`mem_bytes.s`) covers, plus an explicit pair of checks demonstrating the
  1-cycle read latency itself (not just that reads eventually return the
  right value, but that they return the *previous* state until the DUT has
  actually seen a posedge with the new request presented).
- `fpga/top.v` elaborated cleanly against the full `design/*.v` set via
  Icarus (`iverilog -Wall -g2005 -I design -tnull design/*.v fpga/top.v`) --
  not a synthesis or timing-closure guarantee (Icarus doesn't do either),
  but confirms the port list, instance connections, and module hierarchy are
  self-consistent before anyone tries a real vendor toolchain against it.
- Full suite: 22/22 directed tests (114 checks, +8 from
  `tb_data_memory_bram.v`) and 30/30 random cross-check programs passing
  after every change in this ADR, including the `debug_x10`
  port-list-mismatch fix.

## Future improvements

- The actual MEM-stage retiming to integrate `DataMemoryBRAM.v` (or
  `InstructionMemory.v`'s equivalent -- fetch's combinational read has the
  exact same BRAM-inference problem and wasn't touched here either) is the
  real remaining Phase 7 work. Scope it as its own ADR when undertaken, with
  its own dedicated `Forward.v`/`Hazard.v` verification pass, the same way
  `docs/adr/0009` treated the divider's interlock as first-class design work
  rather than an incidental detail.
- `DataMemory.v`'s (and, by inheritance, `DataMemoryBRAM.v`'s) reset
  behavior -- clearing every byte in one cycle via a `for` loop -- is
  simulation-correct but not itself how a real BRAM primitive works (block
  RAM generally has no "clear every location this cycle" port); most flows
  will either take a large area/Fmax hit turning this into distributed logic
  instead of a real BRAM, or (Vivado, in practice) still infer BRAM but only
  respect the `initial`-block content, silently dropping the synchronous
  clear-on-reset behavior for the memory *array* itself. `InstructionMemory.
  v`'s `initial`-block-only load (no runtime reset path for the array) is
  the safer pattern for this reason; `DataMemory.v` needs a documented,
  board-verified decision here before real hardware bring-up rather than an
  assumption inherited from the simulation-only design.
- No real board has run any of this yet -- `fpga/constraints_template.xdc`
  is Xilinx/XDC-syntax only, and the whole `fpga/` directory is unverified
  beyond Icarus elaboration. First real hardware bring-up is the natural
  next milestone, and will very likely surface toolchain-specific issues
  (BRAM inference behavior chief among them, per above) this ADR can only
  predict, not confirm.
