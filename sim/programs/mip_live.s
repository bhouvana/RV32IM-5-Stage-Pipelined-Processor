# docs/adr/0020-soc-integration.md (Phase D8): confirms mip.MTIP/MEIP
# track Timer.v's/Uart.v's real, live hardware state as it actually
# changes over time -- not just a static snapshot. No interrupt redirect
# exists yet (D9); this is CSR-read-side only, via csrrs polling loops.

lui x1, 0x10000        # x1 = UART_BASE  = 0x10000000
lui x2, 0x10104         # x2 = TIMER_BASE + CLINT_OFF_MTIMECMP = 0x1010_4000 (MTIMECMP low, Phase R)

# Timer: MTIMECMP = 50 (small, reachable quickly). Confirm NOT pending
# immediately after setting a compare value still far ahead of mtime.
addi x3, x0, 50
sw x3, 0(x2)             # MTIMECMP(low) = 50
# An MMIO store commits at the MEM stage (one cycle behind EX); mip's
# read-side view of Timer.v's pending is derived from mtimecmp as EX
# sees it *this* cycle. A csrrs immediately following the sw would race
# it -- it resolves in EX only one cycle after the store did, before the
# store's own MEM-stage commit has propagated into Timer.v (found by
# tracing an early version of this test that read MTIP as already
# pending here, since it caught mtimecmp still at its reset value of 0
# for one cycle). Two spacer instructions give the write time to land
# before anything depends on having observed it -- no interlock exists
# for this (nor should one: this is an inherent, small, one-time settling
# delay between two independent subsystems, the same kind of thing a
# real driver/programmer would allow for, not a correctness bug).
addi x0, x0, 0
addi x0, x0, 0
csrrs x4, 0x344, x0      # mip
andi x5, x4, 0x80        # MTIP -- expect 0

timer_poll:
csrrs x6, 0x344, x0
andi x7, x6, 0x80
beq x7, x0, timer_poll   # loop until MTIP sets (mtime free-runs up to 50)

# UART: enable IER.ERBFI, then poll for a byte the testbench drives into rx
# (byte reception itself doesn't depend on IER.ERBFI -- only whether
# irq/MEIP asserts once it's ready does, so this works regardless of
# exactly when the testbench's stimulus and this enable-write interleave).
addi x8, x0, 1
sw x8, 4(x1)             # IER.ERBFI = 1

uart_poll:
csrrs x9, 0x344, x0
andi x10, x9, -2048     # 0x800 (MEIP) -- andi's imm is signed 12-bit, so the raw 0x800 bit pattern must be passed as its negative two's-complement equivalent; harmless here since mip's upper bits are always 0, so the sign-extended mask's extra 1-bits AND to 0 regardless
beq x10, x0, uart_poll    # loop until MEIP sets

# Both bits pending simultaneously at this point.
csrrs x11, 0x344, x0
andi x12, x11, -1920      # 0x880 (MTIP|MEIP) -- same signed-immediate note as above

# Reading RBR clears LSR.DR -> MEIP clears. MTIP has no software
# clear except reprogramming MTIMECMP past the current mtime, so it stays.
lw x13, 0(x1)             # RBR
csrrs x14, 0x344, x0
andi x15, x14, -2048       # 0x800 (MEIP) -- expect 0 (cleared); same signed-immediate note as above
andi x16, x14, 0x80        # expect 0x80 (MTIP still set)

self:
jal x0, self
