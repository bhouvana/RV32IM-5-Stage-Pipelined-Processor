# ADR 0036: Real Linux Boot Attempt Infrastructure (Generation 3, Phase T)

## Problem

Phase S (`docs/adr/0035`) built and verified real M-mode SBI firmware against a self-written S-mode
test payload. Per `docs/ROADMAP_VISION.md`'s Generation 3 sequence, Phase T is next: source a real
riscv64 Linux kernel + rootfs and attempt an actual boot. Icarus Verilog's own event-driven interpreter
is far too slow for this — a real kernel needs tens of millions of instructions just to reach its own
first console line, days of wall-clock time under Icarus by extrapolation from this project's own
existing test throughput. The user explicitly asked to include Verilator in this phase's own scope
specifically so a genuinely full boot attempt (not just "first console output") was achievable.

## Design

### Verilator bootstrap

No `verilator`/`make` on this machine, but OSS CAD Suite (already installed for Phase L formal
verification) bundles `verilator_bin.exe` directly — the `verilator` perl-wrapper script fails
(missing `Pod::Usage`), but the real binary works standalone. `VERILATOR_ROOT` must be set explicitly
(`share/verilator`, not auto-detected). `sim/verilator/sim_main.cpp`: a plain cycle-driven C++ harness
(no DPI/UVM) — toggles `clk`, drives `start` like every existing testbench's own reset convention, and
decodes `uart_tx` live via a background state machine mirroring `tb_uart_polled.v`'s own approach,
re-expressed in cycle units. `sim/tools/build_kernel_boot.py` drives verilate→g++ compile, bypassing
Verilator's own generated Makefile (no `make`) by invoking g++ directly on the generated sources. Real
gotchas found by running: `-I<dir>` must be one concatenated argv token, not two separate list elements
(Verilator's own arg parser otherwise treats the directory as a positional module-file argument);
forward-slash-normalized, `os.path.normpath`-resolved paths throughout (backslashes and unresolved
`..` segments both silently broke internal include resolution); static linking
(`-static-libgcc -static-libstdc++ -static`) is required, not optional — a first attempt without it
produced a real, silently-broken executable (exit 127) from a missing MinGW runtime DLL. Verified
byte-for-byte against Phase S's own known-good firmware before trusting it for anything real (identical
"OK" output, confirming the harness itself is correct). Measured throughput: ~1.4M cycles/sec, roughly
1000x faster than Icarus estimates for this scale of program.

### SBI extended to real v0.2+

Phase S's own firmware answers legacy SBI v0.1 only (`GET_SPEC_VERSION` → 0). Research found a real,
concrete gotcha: a modern (post-2021) Linux kernel builds with `CONFIG_RISCV_SBI_V01=n` by default,
meaning the legacy EIDs are compiled out entirely — without real v0.2+ TIME/IPI/RFENCE extensions, the
kernel's own timer never works at all (no scheduling tick, hangs past early init). `sim/firmware/sbi.c`
now answers both v0.1 and v0.2+ concurrently (a build-time `SPEC_VERSION_TO_REPORT` constant selects
which `GET_SPEC_VERSION` reports — real spec-legal behavior, matching what real OpenSBI itself does for
backward compat), with `SET_TIMER`'s underlying logic (write `mtimecmp`, clear `mip.STIP`) factored into
one shared helper used by both the legacy EID and the real `TIME`/FID0 call. HSM deliberately NOT
implemented: research confirmed a single-hart kernel falls back to `RISCV_BOOT_SPINWAIT` when HSM's own
probe fails, and with nothing to bring up, HSM's absence never blocks a genuinely single-hart boot.
Phase S's own `tb_sbi_firmware_s7.v` (spec_version=0) re-verified bit-exact; a spec_version=2 build
compiles clean.

### Kernel/initramfs sourcing

Phase S's own flagged research gap (`UCanLinux/riscv64-sample` stale, BBL-based, no portable DTB) turned
out worse than expected on closer investigation: Debian's own riscv64 kernel package mirror has no
`pool-riscv64/main/l/` directory at all (confirmed via direct directory browsing, 404 on every mirror);
Alpine's `linux-lts` package downloads cleanly but contains no actual `vmlinuz` binary at all, only
config/System.map/device-tree blobs for real hardware — a real packaging gap in this very-new riscv64
port. `ayushbansal323/riscv64-sample` (a different GitHub repo than the one Phase S found stale) has
real, committed `Image` (9,548,896 bytes) and `initramfs.cpio.gz` (4,568,431 bytes) binaries — verified
genuine by decoding the `Image` header byte-by-byte (real `text_offset`=0x200000, `image_size` matching
the file's own actual size exactly, real magic strings) before trusting it for anything.

### Memory-init scaling gap

Phase Q's own `ZERO_INIT_LIMIT` (`docs/adr/0033`) bounds `InstructionMemory.v`/`DataMemoryBRAM.v`'s own
zero-init cost to 64KB regardless of `SIZE_BYTES`, since every prior test program's own footprint always
stayed within that window — but a real kernel loaded at a multi-MB offset needs far more of the array
actually populated from `INIT_FILE` than that cap allows. Added `ZERO_INIT_LIMIT_OVERRIDE` (0 default,
bit-exact with every existing test; nonzero explicit override for this build) to both modules and
threaded it through `RamWishboneAdapter.v`/`riscvpipeline.v` — a real, deliberately narrow-scoped
parameter addition, not a change to the shared default.

### Memory layout and placement

`sim/tools/build_linux_boot.py`: builds a combined flat memory image — M-mode firmware (real v0.2 SBI,
no S-mode test payload this time, `boot.S`'s own `KERNEL_ENTRY`/`KERNEL_DTB_ADDR` macros retarget
`mepc`/`a1` at the real kernel instead of Phase S's `PAYLOAD_BASE`/`DTB_ADDR` defaults) at low IMEM
addresses, kernel Image at `0x200000` (matching its own header's `text_offset`), initramfs at `0x1000000`,
DTB at `0x1500000` — each placement explicitly bounds-checked against its neighbor. `sim/tools/gen_dtb.py`
extended with real `/chosen` `linux,initrd-start`/`linux,initrd-end` properties and a bootargs override
(`earlycon=uart8250,mmio,<UART_BASE>` — bypasses SBI console entirely for first output, since Phase R's
own UART is already real ns16550a-compatible).

## Real bugs/findings

1. **A genuine, proven-by-contradiction Harvard-architecture limitation for raw binary content.** This
   core's `InstructionMemory.v`/`DataMemoryBRAM.v` are two disjoint byte arrays with zero cross-
   visibility (confirmed by reading both modules directly) — fine for this project's own ELF-compiled
   firmware (`elf2mem.py` already splits `.text` into IMEM and `.rodata`/`.data` into DMEM by real VMA),
   but a real kernel `Image` is a flat binary mixing code and initialized data with no section table to
   split by. Mitigated by mirroring the kernel Image's raw bytes into both IMEM and DMEM at the same
   address (data loads see initialized `.data`/`.rodata` from the DMEM copy, instruction fetches see
   `.text` from the IMEM copy) — a real, accepted, explicitly-documented ceiling: this does NOT cover
   genuine runtime self-modifying code (`jump_label`/`ftrace`/`alternatives` patching, kernel module
   loading), where a STORE only updates the DMEM copy and a later FETCH from IMEM still sees stale
   bytes. Not yet hit in practice as of this phase's own closing point.
2. **The kernel's own compressed-instruction (`c.j`) header trampoline is not decodable at all** — this
   core has zero RVC ("C" extension) support, and virtually every real-world prebuilt RISC-V kernel
   Image is built with RVC enabled for code density. This is the real, hard blocker this phase's own
   research/implementation work closes on. Confirmed via granular PC/`mcause`/register tracing (new
   `debug_pc`/`debug_priv_mode`/`debug_mcause` taps added to `riscvpipeline.v`, same "unconnected
   changes nothing" shape as the existing `debug_x10`): the very first kernel instruction traps illegal
   with `mcause=2`, and the raw bytes decode as a real `c.j` per the RVC spec's own C1-quadrant encoding
   — not a corrupted/misread fetch.

## Alternatives considered

**Sourcing/building a kernel Image without RVC** (`CONFIG_RISCV_ISA_C=n`), once the RVC gap was found.
Deferred to Phase U's own scope decision (`AskUserQuestion`) rather than assumed — real RVC decode
support was judged more valuable long-term (this core will need it for essentially any future
real-world binary) than a workaround specific to one kernel build, and no from-source kernel build
environment exists on this machine regardless.

## Validation strategy

Verilator harness verified byte-for-byte against Phase S's own known-good firmware (`sim/firmware/build/`)
before any kernel-specific work — same discipline as every prior phase's "prove the plumbing is inert
before anything uses it." `gen_dtb.py`'s own independent-parser round-trip self-check re-run after the
initrd/bootargs extension. `ZERO_INIT_LIMIT_OVERRIDE` defaults to 0 everywhere; every existing test's
own `.mem` generation and Icarus-based regression path is untouched by construction, not just by claim.

## Future improvements

The Harvard-split mirroring ceiling (self-modifying code) is real and unaddressed — a future phase
adding genuine RVC/self-patch support would need to either unify the two memories at the RTL level or
teach the mirroring step to detect and replay writes into both copies at runtime. Kernel/initramfs
sourcing depended on a third-party GitHub repo, not an official distro release — a real, open
robustness gap if that repo ever disappears. Generation 3's own kernel-boot goal continues in Phase U
(RVC support) and Phase V (A-extension support) — see those ADRs for the real continuation.
