# docs/adr/00NN-mmu-sv32.md (Phase F5). Happy-path integration test: M-mode
# (physical addressing throughout -- M always bypasses translation, even
# after satp is set to Sv32 partway through this program) builds a real
# 2-level Sv32 page table, then mret drops to U-mode at a VIRTUAL address
# to prove I-side translation live; the translated code then stores and
# loads through a SEPARATE virtual data mapping to prove D-side translation
# both directions, then halts -- still executing translated code the whole
# time, so every fetch after the first exercises TLB-hit reuse for free
# (checked in the testbench via a walk-count tap on m_Ptw.done, not
# architecturally).
#
# Layout: satp_ppn=0 (level-1 table at DATA address 0 -- one PDE, index
# VPN1=0), level-0 table at DATA PPN=1 (address 0x1000), data destination
# at DATA PPN=2 (address 0x2000). Fetch destination maps back to
# INSTRUCTION-memory PPN=0 -- this SAME program's own code (a separate
# address space from the data-memory page table, so no collision) --
# deliberately NOT VPN0=0 (which would make VA==PA numerically and not
# meaningfully exercise translation); VPN0=5 is used instead, so
# VA_fetch=0x5048 while u_code's real physical address is 72.
# VA_data uses VPN0=1 (VA=0x1004), mapped to DATA PPN=2.
addi x1, x0, 1          # 0:  x1 = 1
slli x1, x1, 12         # 4:  x1 = 0x1000 (level-0 table base, reused as sw base reg)
addi x2, x0, 0x401       # 8:  level-1 PDE value: PPN=1 (level-0 table), V=1, non-leaf (R=W=X=0)
sw   x2, 0(x0)             # 12: level-1[VPN1=0] <- PDE  (satp_ppn=0, table at addr 0)
addi x2, x0, 0x1B            # 16: fetch PTE value: PPN=0, V|R|X|U (0x1|0x2|0x8|0x10=0x1B)
sw   x2, 20(x1)                # 20: level-0[VPN0=5] <- fetch PTE  (5*4=20)
addi x2, x0, 2                   # 24: x2 = 2 (data destination PPN)
slli x2, x2, 10                    # 28: x2 = 0x800
ori  x2, x2, 0x17                    # 32: x2 = 0x817 -- data PTE value: PPN=2, V|R|W|U
sw   x2, 4(x1)                         # 36: level-0[VPN0=1] <- data PTE  (1*4=4)
addi x3, x0, 1                           # 40: x3 = 1
slli x3, x3, 31                            # 44: x3 = 0x80000000 (satp: MODE=1(Sv32), PPN=0)
csrrw x0, 0x180, x3                          # 48: satp <- x3 -- M-mode still bypasses from here on
addi x4, x0, 5                                 # 52: x4 = 5 (VPN0 for the fetch mapping)
slli x4, x4, 12                                  # 56: x4 = 0x5000
ori  x4, x4, 72                                    # 60: x4 = 0x5048 = VA_fetch (u_code's real PA is 72)
csrrw x0, mepc, x4                                   # 64: mepc <- VA_fetch
mret                                                   # 68: -> U mode, PC <- VA_fetch (I-side translation live)
u_code:
addi x10, x0, 111                                        # 72: marker -- proves fetch translation landed here
addi x6, x0, 1                                              # 76: x6 = 1 (VPN0 for the data mapping)
slli x6, x6, 12                                               # 80: x6 = 0x1000
ori  x6, x6, 4                                                  # 84: x6 = 0x1004 = VA_data
addi x11, x0, 777                                                 # 88: value to store
sw   x11, 0(x6)                                                      # 92: D-side STORE translation
lw   x12, 0(x6)                                                        # 96: D-side LOAD translation (round trip)
fence
halt:
jal x0, halt                                                             # 100
