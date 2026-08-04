# ADR 0035: Minimal Hand-Rolled M-Mode SBI Firmware + DTB (Generation 3, Phase S)

## Problem

Phase R (`docs/adr/0034`) made `Uart.v`/`Timer.v` real ns16550a/CLINT-compatible peripherals. Per
`docs/ROADMAP_VISION.md`'s Generation 3 sequence, Phase S is next: a hand-rolled minimal M-mode SBI
(Supervisor Binary Interface) firmware plus a device tree blob, buildable with the xPack bare-metal
`riscv-none-elf-gcc` cross-compiler Generation 2 confirmed obtainable — the piece that boots
firmware in M-mode, then jumps to a Linux kernel running in S-mode, the way every real RISC-V Linux
platform works (OpenSBI + kernel + DTB).

## Design

### Research findings that reshaped scope

Two research passes (existing-toolchain-scaffolding, and real SBI/DTB/boot-protocol facts) found:

- **`riscv-none-elf-gcc` (xPack, v15.2.0) is genuinely installed** at
  `C:\Python\xpack-riscv-none-elf-gcc-15.2.0-1\`, confirmed by running it directly — not just
  "obtainable" per Generation 2's own framing. `dtc` (device tree compiler) is **not** installed
  anywhere on this machine (confirmed by a real filesystem search) — this phase hand-rolls the real
  FDT binary format in Python instead (`sim/tools/gen_dtb.py`), matching this project's own
  established precedent (`asm.py`, `elf2mem.py`) rather than adding a new external dependency.
- **`sim/benchmarks/c/link.ld`/`crt0.S` and `sim/tools/elf2mem.py`** are real, already-proven bare-
  metal C tooling (Harvard IMEM/DMEM linker-script shape, real-ELF-little-endian→
  `InstructionMemory.v`-big-endian instruction-word swap) — reused directly (`elf2mem.py`, generalized,
  see below) rather than redesigned from scratch.
- **`UCanLinux/riscv64-sample`** (the kernel source `docs/ROADMAP_VISION.md` named as "obtainable,
  no-build-needed" for Phase T) turned out **stale** (last pushed 2019, Linux 4.20), boots via **BBL**
  (not OpenSBI), relies on **QEMU dynamically synthesizing its own DTB** (ships no portable DTB to
  adapt), and its rootfs is a **virtio-blk ext2 disk image**, not an initramfs. Presented to the user
  via `AskUserQuestion`: build the real firmware now, verified against a self-written S-mode test
  program, fully decoupled from whichever specific kernel Phase T eventually sources — not blocked on
  further kernel research, and not simply reusing UCanLinux's own BBL as a substitute for writing real
  firmware.
- **Real SBI boot-protocol facts** (cited for Phase T's own future benefit): kernel/payload entry
  convention is `a0`=hart id, `a1`=DTB physical address, `satp`=0 (Bare) required at entry,
  `mstatus.MPP`=S before the firmware's own `mret`. A real Linux kernel calls the Base extension's
  `GET_SPEC_VERSION` unconditionally at boot — reporting spec version 0 is the real "legacy v0.1,
  don't bother probing individual extensions" signal, letting the kernel wire up the simpler legacy
  EIDs directly. Legacy `SET_TIMER` (EID 0) is genuinely required for a working scheduler tick, since
  `mtimecmp` is M-mode-only CLINT state S-mode cannot touch directly. Console (legacy EID 1/2) is
  *not* required once a real ns16550a DT node exists (Phase R) — a real kernel uses its own 8250
  driver directly — but implemented anyway (cheap, given Phase R's own register map, and gives this
  phase's own test independent visible output). IPI/RFENCE (EID 3-7) are real spec-legal no-ops for a
  genuinely single-hart system.

### A real architectural gap found while designing the timer round trip

While designing how to verify the SBI TIME extension's own real mechanism (M-mode intercepts the real
machine-timer interrupt, masks it, synthesizes a "virtual" supervisor-timer interrupt via `mip.STIP`,
returns), direct reading of `riscvpipeline.v` found `interrupt_taken` was **exclusively** gated by
`mstatus_mie & (mei_pending | msi_pending | mti_pending)` — every term keyed to *machine*-level `mie`
bits and raw hardware pending signals. Nothing anywhere checked `mip.STIP`/`sie.STIE`/`sstatus.SIE`.
`mideleg`'s own `trap_target_is_s` only steers *where* an already-machine-recognized trap redirects
(`stvec` vs `mtvec`) — it doesn't add a new way for a *software-synthesized* interrupt to fire at all.
`mip.STIP`/`sie`/`sstatus.SIE` were real CSR storage since Phase F, but the pipeline's own trap-taking
condition was never extended to act on them — meaning a real Linux kernel could never get a working
preemptive scheduler tick on this core, independent of anything Phase S/T do with firmware/kernels.

Presented to the user via `AskUserQuestion` (fix now vs. defer to polling): **fix now**, as scoped RTL
work within this phase. Extended `interrupt_taken` with a genuine supervisor-interrupt term:

```verilog
wire ssi_pending = mstatus_sie & mie_ssie & mip_ssip & (priv_mode_w == `PRIV_S);
wire sti_pending = mstatus_sie & mie_stie & mip_stip & (priv_mode_w == `PRIV_S);
wire interrupt_taken = ((mstatus_mie & (mei_pending | msi_pending | mti_pending)) | ssi_pending | sti_pending)
                        & !pc_stall & !other_redirect_taken;
```

Deliberately **not** gated by `mstatus_mie` (real spec precedence: a supervisor-targeted interrupt is
gated by `sstatus.SIE`, not M's own global enable, and only valid while executing at S). Priority
extended to the real spec ordering **MEI > MSI > MTI > SSI > STI**. New `mcause`/`scause` constants
`MCAUSE_INT_SUPERVISOR_SOFTWARE`(1)/`MCAUSE_INT_SUPERVISOR_TIMER`(5). `CSR.v` gained four new output
ports (`mie_ssie`/`mie_stie`/`mip_ssip`/`mip_stip`, mirroring the existing `mie_mtie`/`timer_pending`
idiom exactly) and gave `mstatus_sie` (previously formal-verification-only, per Phase L's own
comment) a real, live consumer. This new supervisor-interrupt path reuses `mideleg`'s **existing**
delegation/scause/sstatus-swap machinery entirely unmodified — firmware just needs to set `mideleg`
bits 1/5 (SSIE/STIE) at boot, and the pre-existing Phase F delegation logic (built for real, hardware-
delegatable interrupts) correctly routes this software-synthesized case too, since it doesn't care
*why* a cause is pending, only that it's genuinely delegatable.

### Firmware structure

`sim/firmware/`: `link_sbi.ld` (Harvard IMEM/DMEM, two fixed-VMA code regions — `.text.boot` at VMA 0,
this core's real PC reset value, and `.text.payload` at `PAYLOAD_BASE`=`0x2000`, since this core has
no ELF loader and both firmware and the S-mode test payload must already be real, fetchable bytes in
one combined `InstructionMemory.v` image), `boot.S` (M-mode entry: zero `.bss`, set `mtvec`/
`mscratch`, `mideleg`, `mie.MTIE`, `mstatus.MPP=S`/`MPIE=1`, `mepc`=`PAYLOAD_BASE`, `satp=0`, `a0`=0/
`a1`=DTB address, `mret`), `trap_entry.S` (hand-written — chosen over GCC's `__attribute__((interrupt))`
specifically because it must reliably forward arbitrary `a0-a7` SBI ecall arguments to C, which the
attribute-based approach can't do without risky register-pinning tricks; verified separately that GCC's
interrupt attribute genuinely works correctly for the *simpler*, no-argument S-mode trap handler, used
there instead), `sbi.c`/`sbi.h`/`uart_mmio.h` (ecall dispatch + timer forwarding), `payload_start.S` +
`payload.c` (the S-mode test payload). `sim/tools/build_sbi_firmware.py` drives the build (compile each
source to an explicitly-named object first, then link — see Real bugs/findings), `sim/tools/gen_dtb.py`
emits the DTB (with a real, independent-parser round-trip self-check, not just re-running the same
builder), `sim/tools/elf2mem.py` is reused for ELF→`.mem` conversion (generalized, see below).

## Real bugs/findings

Six real bugs found by running (not anticipated by design/reading alone), roughly in the order this
phase's own debugging uncovered them:

1. **`elf2mem.py`'s IMEM extraction was hardcoded to sections literally named `.text.init`/`.text`**,
   concatenated assuming contiguity — correct only for `sim/benchmarks/c/link.ld`'s own single-region
   layout. `link_sbi.ld`'s two non-contiguous, differently-named regions (`.text.boot`/`.text.payload`)
   matched neither name, so `imem.mem` silently came out all-zero. Found immediately (the very first
   build attempt produced a program that couldn't even execute its first instruction correctly).
   **Fixed as a real, generic tool improvement**, not a one-off: added `get_section_vma()` (reads a
   section's real VMA from `objdump -h`, the same "extract by real address, not by naive
   concatenation" idiom `.rodata`/`.data` already used) and a new `--imem-sections` flag (comma-
   separated, each section placed independently by VMA) defaulting to the old `.text.init,.text`
   value — confirmed bit-identical behavior for `build_c_bench.py`'s own existing use (re-ran
   `smoke_test.c`, still returns 360) before trusting the generalization.
2. **GCC compiles multiple source files passed to one `gcc ... -o elf` invocation through unnamed
   temporary objects**, silently breaking `link_sbi.ld`'s own `*sbi.o(.text*)`/`*payload.o(.text*)`
   file-name-based section selectors (needed to route each C file's compiler-generated code into the
   right fixed-VMA region). Found by checking `nm`'s own symbol addresses after the first build —
   `_payload_start` landed at `0x1b0`, not `PAYLOAD_BASE`(`0x2000`). Fixed by compiling each source
   to an explicitly-named object first, then linking those together.
3. **A plain `. = PAYLOAD_BASE;` location-counter assignment between two `> IMEM`-placed output
   sections does not reposition IMEM's own region cursor** — GNU ld tracks memory-region placement
   independently of the location counter used for regionless placement. Found by reading the actual
   `objdump -h` section headers after fix #2 still showed `.text.payload` landing right after
   `.text.boot` ended, not at `0x2000`. Fixed with the correct idiom: an explicit address directly
   after the section name (`.text.payload PAYLOAD_BASE : { ... } > IMEM`), keeping `> IMEM` for its
   own real value (bounds checking).
4. **`trap_entry.S`'s ecall-adjustment logic reused `t0`/`t1` as scratch registers — but `t0` IS
   `x5`, the handler's own scratch-base pointer for the entire register save/restore sequence.**
   `csrr t0, mepc` (part of "is this an ecall, if so `mepc += 4`") silently clobbered `x5` right
   before every single subsequent register-restore load used it as a base address. The single most
   consequential bug this phase found: the *first* ecall (`GET_SPEC_VERSION`) appeared to succeed
   (its own trap correctly entered/returned, `mepc+4` correctly applied), but its own "restore"
   silently read from garbage offsets derived from `mepc`'s own value instead of `trap_scratch`'s
   real base — corrupting essentially every register `payload_main` depended on, invisible until the
   *second* ecall retrapped from a corrupted return address instead of ever reaching straight-line
   code after the first one. Found only by an extremely granular per-cycle trace of `x5`/`mscratch`/
   `pc` (register-level snapshots and even live memory-write monitoring were both too coarse to catch
   it — the actual root cause only became visible watching `x5`'s value cycle-by-cycle across the
   exact instruction that clobbered it). Fixed by using `t1`/`t2` for the mepc-adjustment scratch work
   instead (safe: both get correctly overwritten by their own real restored values moments later
   regardless of this throwaway use).
5. **`mie.MTIE` (the real machine-level timer-interrupt enable) was never set anywhere in the
   firmware**, and **`mstatus.MPIE` was never set before `boot.S`'s own `mret`** (leaving
   `mstatus.MIE` at its reset value, 0, once in S-mode, since `mret` restores `MIE` from `MPIE`). Not
   an RTL bug — a real firmware-design gap: M-mode's whole SBI TIME-extension design depends on
   *always* intercepting the real hardware timer interrupt (to mask it and synthesize `STIP`), which
   structurally cannot happen if the machine-level interrupt is masked by construction. Found once bug
   #4 was fixed and the console loop finally ran to completion, but the timer round trip still never
   observed — a targeted trace of `mie`/`mstatus`/`mtimecmp`/`mtime` showed `mstatus.MIE=0` throughout.
   Fixed by having `boot.S` set both `mie.MTIE` and `mstatus.MPIE` explicitly before its own `mret`.
6. **A `$readmemb`/pipeline-stage timing gotcha in this phase's own early debug testbenches**
   (register-value snapshots at the wrong pipeline stage produced misleading "0 == default, not
   proof of a real write" false positives) cost real debugging time before switching to a live
   write-port monitor (tapping `DataMemoryBRAM.v`'s own `memWrite`/`address`/`writeData` ports
   directly) and eventually a per-cycle register trace — not a bug in the design under test, but a
   real methodology lesson: **prefer live signal monitoring over snapshot-based memory dumps when
   debugging a suspected register-corruption issue**, since a snapshot can't distinguish "correctly
   wrote zero" from "never wrote at all."

Zero RTL bugs found *by running* in this phase (the one real RTL change, `interrupt_taken`'s
supervisor-interrupt extension, was found and fixed *before* writing any firmware code, via careful
reading — the same rarer-but-real pattern Phase R's own `mie_masked` finding established) — every bug
this phase's own execution surfaced was in firmware assembly or Python tooling.

## Alternatives considered

**GCC's `__attribute__((interrupt))` for the M-mode trap handler too** (not just S-mode's). Rejected:
verified directly that it generates a correctly-scoped save/restore (only registers the function body
actually clobbers, using the current stack) — genuinely simpler and safer than hand-rolled assembly —
but it gives the handler no argument-passing mechanism, and the M-mode SBI handler must reliably
forward arbitrary `a0-a7` ecall arguments to its own dispatch logic. Reading raw ABI registers via
GCC's register-pinning idiom (`register unsigned long r __asm__("a0")`) was considered and rejected as
too fragile to trust without extensive verification for this specific, argument-heavy use case: used
instead for S-mode's own trap handler, where no argument-passing is needed at all.

**Reusing UCanLinux's own `bbl`+`vmlinux` blob directly**, crafting only a DTB to redirect it at this
core's own hardware. Rejected via `AskUserQuestion` (see Design's own research-findings section) — it
would couple this phase's own firmware design to BBL's legacy v0.1-only SBI shape and an unverified
assumption that a 2019-era kernel build makes no hardware assumptions beyond what DT describes,
undermining the actual point of building real, testable firmware this phase can independently verify.

**Delegating the real machine-timer interrupt via `mideleg` directly** (skipping the mask-and-
synthesize dance entirely). Rejected: this is exactly what M-mode's own SBI TIME-extension design
exists to avoid — a real S-mode OS should never touch `mtimecmp` directly (real spec convention,
matches every real platform's own OpenSBI-mediated timer model), and this core's own CLINT is
genuinely M-mode-only-writable MMIO, not something S-mode can access after translation is enabled
regardless.

## Validation strategy

`sim/tools/gen_dtb.py`'s own independent-parser round-trip self-check (header field consistency,
balanced `BEGIN_NODE`/`END_NODE`, every `PROP`'s `nameoff` within bounds, real `FDT_END` termination)
runs on every build, not just once by construction. New `sim/tb/tb_sbi_firmware_s7.v` runs the real,
built firmware+payload through Icarus end-to-end: the M→S mode switch itself (`a0`/`a1` landing
correctly), the DTB blob's real magic number read back correctly from S-mode via a manual big-endian
reconstruction (`DataMemoryBRAM.v`'s own real little-endian loads, confirmed via `elf2mem.py`'s own
prior documented finding, would otherwise byte-swap a naive read), the Base extension's
`GET_SPEC_VERSION` ecall round-tripping through `trap_entry.S`/`sbi_dispatch`, `CONSOLE_PUTCHAR`'s
real UART output decoded off `uart_tx` (mirrors `tb_uart_polled.v`'s own background-decoder-task
approach), and the real machine-timer-interrupt-forwarding round trip (mask `mtimecmp`, synthesize
`mip.STIP`, `riscvpipeline.v`'s own new `sti_pending` path retrapping directly into S-mode's own
`s_trap_handler`) — the one check this phase's own new RTL fix makes possible at all. All seven
checks pass on the final build.

Full closing bar, re-run after every change to confirm nothing else regressed: **90/90 directed
tests** (up from 89/89 — the new `sbi_firmware_s7` test), zero-warning `iverilog -Wall -g2005 -I
design -tnull design/*.v` compile, constrained-random cross-check clean at every existing axis (60/60
default, 60/60 XLEN=64 non-MMU, 60/60 Sv32-MMU, 60/60 Sv39-MMU) plus 30/30 each of the four
interrupt-injection modes (confirming `interrupt_taken`'s restructuring didn't disturb the existing
MEI/MSI/MTI paths), plus a `build_c_bench.py`/`smoke_test.c` regression check (still returns 360)
confirming `elf2mem.py`'s generalization is bit-identical for its original caller.

## Future improvements

Phase S's own firmware is deliberately minimal: `SHUTDOWN` just spins forever (no real power-down
signal exists on this core), `SEND_IPI`'s legacy hart-mask-pointer dereference is real/spec-shaped
but genuinely untested (nothing in this phase's own single-hart test ever calls it), and
`GET_IMPL_ID`/`GET_MVENDORID`/etc report placeholder/zero values (spec-legal, but not meaningful
identifiers). The DTB's `clock-frequency`/`timebase-frequency` values are round placeholders, not
derived from any real timing relationship to `CLKS_PER_BIT`/the simulated clock period — fine for this
phase's own payload (which never depends on real wall-clock baud timing), a real prerequisite to get
right before Phase T's own kernel needs a working UART console at a specific baud rate. `sim/formal/`'s
own frozen `CSR.v`/`riscvpipeline.v` copies (Phase L) remain further unsynced with this phase's own
`interrupt_taken` extension — the same pre-existing, non-regressing gap every phase since M has left
widening. Generation 3, Phase T (load a real riscv64 Linux kernel + rootfs and attempt boot) is next —
its own kernel-sourcing question is real, open research this phase deliberately did not resolve
(UCanLinux's own staleness, confirmed here, is real context for that search, not a solved problem).
