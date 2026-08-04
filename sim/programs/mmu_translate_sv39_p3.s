# docs/adr/00NN-sv39-mmu-phase-p.md (Phase P3). Happy-path integration test,
# the Sv39 analog of mmu_translate_f5.s (Phase F5's own Sv32 equivalent): M-
# mode (physical addressing throughout -- M always bypasses translation,
# even after satp is set to Sv39 partway through this program) builds a
# real 3-level Sv39 page table, then mret drops to U-mode at a VIRTUAL
# address to prove I-side translation live; the translated code then stores
# and loads through a SEPARATE virtual data mapping to prove D-side
# translation both directions, then halts -- still executing translated
# code the whole time, so every fetch after the first exercises TLB-hit
# reuse for free (checked in the testbench via a walk-count tap on
# m_Ptw.done, not architecturally).
#
# Layout: satp_ppn=0 (level-2 table at DATA address 0 -- one PDE, index
# VPN2=0) -> level-1 table at DATA PPN=1 (address 0x1000, one PDE, index
# VPN1=0) -> level-0 table at DATA PPN=2 (address 0x2000). Data destination
# at DATA PPN=3 (address 0x3000). Fetch destination maps back to
# INSTRUCTION-memory PPN=0 -- this SAME program's own code (a separate
# address space from the data-memory page table, so no collision) -- via a
# level-0 (ordinary 4KB) leaf at VPN0=5 (deliberately not 0, which would
# make VA==PA numerically and not meaningfully exercise translation, since
# a leaf's OWN ppn field -- not the VPN0 table index used to reach it --
# is what determines the resulting physical page). Page-offset equals
# u_code's own real physical address (92), so the translated fetch lands
# exactly there: VA_fetch=0x505C, u_code's real PA is 92.
# VA_data uses VPN0=1 (VA=0x1004), mapped to DATA PPN=3. VPN2=VPN1=0 for
# both mappings (only one entry needed at each of those two levels), so the
# numeric VA values end up identical in their low 21 bits to what Sv32's
# own equivalent VPN0/offset fields would produce -- Sv39's VPN0 sits at
# the same [20:12] bit position Sv32's own VPN0 does.
#
# PTE values reuse the exact same low-order-bit encoding Sv32's own test
# used (PPN<<10 | flags) -- PPN starts at bit 10 in both PTE formats
# regardless of total width (Ptw39.v's own header documents this), and
# every PPN/flag value here is small enough to fit entirely within a PTE's
# low 32 bits, so a single `sw` (not two, one for each 32-bit half of the
# real 8-byte PTE) suffices per PTE -- the upper 4 bytes stay at their
# already-zeroed reset value (DataMemoryBRAM.v zeros all of `data_memory`
# on reset), which is exactly the all-0 upper half a small PPN needs.
# Kept to exactly 32 instructions (this project's directed-test 128-byte
# instruction-memory budget, docs/adr/0014's own documented ceiling): the
# level-1 PDE value (0x801=2049) would overflow addi's 12-bit signed
# immediate range if built from scratch, so it's derived from x1 (already
# 0x1000) via `srli x1,1` instead, and the level-0 table's own base (x1<<1)
# reuses x1 rather than a fresh register+addi+slli pair.
addi x1, x0, 1          # 0:  x1 = 1
slli x1, x1, 12         # 4:  x1 = 0x1000 (level-1 table base)
addi x2, x0, 0x401       # 8:  level-2 PDE value: PPN=1 (level-1 table), V=1, non-leaf (R=W=X=0)
sw   x2, 0(x0)             # 12: level-2[VPN2=0] <- PDE  (satp_ppn=0, table at addr 0)
srli x2, x1, 1                # 16: x2 = 0x800 (= x1>>1 -- level-1 PDE's own PPN=2 part, built from x1 instead of from scratch)
ori  x2, x2, 1                  # 20: x2 = 0x801 -- level-1 PDE value: PPN=2 (level-0 table), V=1, non-leaf
sw   x2, 0(x1)                    # 24: level-1[VPN1=0] <- PDE  (table at addr 0x1000)
slli x1, x1, 1                      # 28: x1 = 0x2000 (level-0 table base, reusing x1)
addi x2, x0, 0x1B                     # 32: fetch PTE value: PPN=0, V|R|X|U (0x1|0x2|0x8|0x10=0x1B)
sw   x2, 40(x1)                         # 36: level-0[VPN0=5] <- fetch PTE  (5*8=40)
addi x2, x0, 3                            # 40: x2 = 3 (data destination PPN)
slli x2, x2, 10                             # 44: x2 = 0xC00
ori  x2, x2, 0x17                             # 48: x2 = 0xC17 -- data PTE value: PPN=3, V|R|W|U
sw   x2, 8(x1)                                  # 52: level-0[VPN0=1] <- data PTE  (1*8=8)
addi x3, x0, 8                                    # 56: x3 = 8
slli x3, x3, 30                                     # 60: (1/2) partial shift (5-bit shamt encoding limit)
slli x3, x3, 30                                       # 64: (2/2) x3 = 8<<60 = 0x8000000000000000 (satp: MODE=8/Sv39, PPN=0)
csrrw x0, 0x180, x3                                     # 68: satp <- x3 -- M-mode still bypasses from here on
addi x4, x0, 5                                            # 72: x4 = 5 (VPN0 for the fetch mapping)
slli x4, x4, 12                                             # 76: x4 = 0x5000
ori  x4, x4, 92                                               # 80: x4 = 0x505C = VA_fetch (u_code's real PA is 92)
csrrw x0, mepc, x4                                              # 84: mepc <- VA_fetch
mret                                                              # 88: -> U mode, PC <- VA_fetch (I-side translation live)
u_code:
addi x10, x0, 111                                                   # 92: marker -- proves fetch translation landed here
addi x6, x0, 1                                                        # 96: x6 = 1 (VPN0 for the data mapping)
slli x6, x6, 12                                                         # 100: x6 = 0x1000
ori  x6, x6, 4                                                            # 104: x6 = 0x1004 = VA_data
addi x11, x0, 777                                                           # 108: value to store
sw   x11, 0(x6)                                                               # 112: D-side STORE translation
lw   x12, 0(x6)                                                                 # 116: D-side LOAD translation (round trip)
fence
halt:
jal x0, halt                                                                      # 124
