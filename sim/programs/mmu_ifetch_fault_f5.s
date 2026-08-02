# docs/adr/00NN-mmu-sv32.md (Phase F5). Instruction page fault: satp is set
# to Sv32 with a deliberately EMPTY page table (data memory defaults to 0,
# so the level-1 PDE at address 0 reads as V=0 -- invalid, no level-0 walk
# even needed). Any translated fetch attempt from a non-M privilege must
# fault. Confirms mcause=12 (MCAUSE_INSTRUCTION_PAGE_FAULT), correct
# redirect to mtvec (trap_target_is_s is 0 here since medeleg defaults to
# 0, so the trap goes to M regardless of the faulting privilege being U),
# and mtval holds the faulting virtual address.
addi x1, x0, 1         # 0:  x1 = 1
slli x1, x1, 31         # 4:  x1 = 0x80000000 (satp: MODE=1(Sv32), PPN=0)
csrrw x0, 0x180, x1      # 8:  satp <- x1 -- table is all-zero/invalid, no entries ever written
addi x3, x0, 5             # 12: x3 = 5 (VPN0, arbitrary -- deliberately never mapped)
slli x3, x3, 12              # 16: x3 = 0x5000
csrrw x0, mepc, x3             # 20: mepc <- 0x5000 (a VA that will page-fault)
addi x4, x0, 36                  # 24: m_handler's address
csrrw x0, mtvec, x4                # 28: mtvec <- m_handler
mret                                  # 32: -> U mode, fetch at 0x5000 -> ITLB miss -> walk -> invalid PDE -> fault
m_handler:
csrrs x11, mcause, x0                   # 36: expect 12 (MCAUSE_INSTRUCTION_PAGE_FAULT)
csrrs x13, 0x343, x0                      # 40: mtval -- expect 0x5000 (the faulting VA)
halt:
jal x0, halt                                # 44
