# docs/adr/0026-performance-profiler.md (Phase K1). itlb_miss (event 15) +
# dtlb_miss (event 16) under a real Sv32 translation, mirroring
# sim/programs/mmu_translate_f5.s's own page-table shape (level-1 PDE at
# DATA addr 0, level-0 table at DATA PPN=1, data destination at DATA PPN=2,
# fetch destination mapped back to INSTRUCTION PPN=0 -- this same program's
# own code). Unlike mmu_translate_f5.s, this program's own preamble isn't
# label-driven for the fetch mapping (the PTE's physical-page mapping is
# numeric, not symbolic), so mhpmevent reprogramming is placed FIRST and
# u_code's own VA page-offset (0x050 = 80) is computed by hand to match its
# real physical byte address (20 preamble instructions * 4 bytes = 80),
# same technique F5 itself used.
csrrwi x0, 0x323, 15   # mhpmevent3 = event 15 (stall_itlb_pulse)
csrrwi x0, 0x324, 16   # mhpmevent4 = event 16 (stall_dtlb_pulse)

addi x1, x0, 1
slli x1, x1, 12          # x1 = 0x1000 (level-0 table base)
addi x2, x0, 0x401        # level-1 PDE: PPN=1, V=1, non-leaf
sw   x2, 0(x0)              # level-1[VPN1=0] <- PDE (satp_ppn=0, table at addr 0)
addi x2, x0, 0x1B            # fetch PTE: PPN=0, V|R|X|U
sw   x2, 20(x1)                # level-0[VPN0=5] <- fetch PTE (5*4=20)
addi x2, x0, 2                  # data destination PPN=2
slli x2, x2, 10                   # x2 = 0x800
ori  x2, x2, 0x17                   # data PTE: PPN=2, V|R|W|U
sw   x2, 4(x1)                        # level-0[VPN0=1] <- data PTE (1*4=4)
addi x3, x0, 1
slli x3, x3, 31                        # x3 = 0x80000000 (satp: MODE=1(Sv32), PPN=0)
csrrw x0, 0x180, x3                     # satp <- x3 -- M-mode still bypasses from here
addi x4, x0, 5                           # VPN0 for the fetch mapping
slli x4, x4, 12                           # x4 = 0x5000
ori  x4, x4, 80                            # x4 = 0x5050 = VA_fetch (u_code's real PA is 80)
csrrw x0, mepc, x4                          # mepc <- VA_fetch
mret                                          # -> U mode, PC <- VA_fetch (I-side translation live)
u_code:
addi x10, x0, 111                              # marker: fetch translation landed here (1 itlb_miss)
addi x6, x0, 1                                   # VPN0 for the data mapping
slli x6, x6, 12                                    # x6 = 0x1000
ori  x6, x6, 4                                       # VA_data = 0x1004
addi x11, x0, 777
sw   x11, 0(x6)                                        # D-side STORE translation (1 dtlb_miss)
lw   x12, 0(x6)                                          # D-side LOAD (TLB warm, should HIT, no 2nd dtlb_miss)
fence
halt:
jal x0, halt
