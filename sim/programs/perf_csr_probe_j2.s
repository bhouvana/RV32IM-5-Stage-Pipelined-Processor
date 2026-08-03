# docs/adr/0025-hpc-performance-csrs.md (Phase J2). Read/write/masking
# correctness for the new mcountinhibit/minstret/mhpmcounter3-11/
# mhpmevent3-11 storage -- pure storage as of J2, no live event-pulse
# consumers yet (J3-J6 wire those live). Deliberately never checks mcycle's
# absolute value here (this program's own mcountinhibit round-trip briefly
# sets bit0/CY, which would invalidate a wall-clock-derived expected
# count) -- that check lives in the separate, minimal
# sim/programs/perf_mcycle_j2.s instead.
addi x1, x0, -1           # x1 = 0xFFFFFFFF, this test's "write all-ones" value

# mcountinhibit: only bits 0,2-11 are real (bit1 and bits12+ hardwired 0).
csrrw x2, 0x320, x1        # x2 = old mcountinhibit (0, reset default)
csrrs x3, 0x320, x0        # x3 = readback, masked to 0xFFD
csrrw x4, 0x320, x0        # clear back to 0 (re-enable every counter)

# minstret/minstreth: minstret_lo is genuinely live now (Phase J3), so its
# "old" value here is a real, moving retirement count -- not checked
# precisely (see tb_perf_csr_probe_j2.v's own comment).
csrrw x5, 0xB02, x1        # x5 = old minstret_lo (a small live count, not checked)
csrrs x6, 0xB02, x0        # x6 = readback (0xFFFFFFFF, the write took)
csrrw x7, 0xB82, x1        # x7 = old minstret_hi (0)
csrrs x8, 0xB82, x0        # x8 = readback (0xFFFFFFFF)

# mhpmcounter3/mhpmcounter3h: plain read-write storage. mhpmevent3's reset
# default (event 1) has its pulse tied to 0 until J4, so no live increment
# races this write.
csrrw x9, 0xB03, x1        # x9 = old mhpmcounter3 (0)
csrrs x10, 0xB03, x0       # x10 = readback (0xFFFFFFFF)
csrrw x11, 0xB83, x1       # x11 = old mhpmcounter3h (0)
csrrs x12, 0xB83, x0       # x12 = readback (0xFFFFFFFF)

# mhpmevent3: reset default is event index 1; only the low 4 bits are real.
csrrs x13, 0x323, x0       # x13 = reset default (1)
csrrw x14, 0x323, x1       # write all-ones
csrrs x15, 0x323, x0       # readback (0xF, only low 4 bits survive)

# mhpmcounter11/mhpmevent11: top of the 9-entry range -- confirms the
# range-decode arithmetic doesn't off-by-one at the boundary.
csrrs x16, 0x32B, x0       # x16 = mhpmevent11 reset default (9)
csrrw x17, 0xB0B, x1       # x17 = old mhpmcounter11 (0)
csrrs x18, 0xB0B, x0       # x18 = readback (0xFFFFFFFF)
csrrw x19, 0xB8B, x1       # x19 = old mhpmcounter11h (0)
csrrs x20, 0xB8B, x0       # x20 = readback (0xFFFFFFFF)

fence
halt:
jal x0, halt
