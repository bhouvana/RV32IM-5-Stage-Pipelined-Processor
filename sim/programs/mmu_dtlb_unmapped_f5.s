# docs/adr/00NN-mmu-sv32.md (Phase F7). D-side unmapped access: the D-side
# sibling of F5's own mmu_ifetch_fault_f5.s, matching the phase plan's own
# F7 ask ("one guaranteed-unmapped access" directed test). satp is set to
# Sv32 with a real (not empty) page table -- u_code itself needs a real
# fetch mapping (VPN0=0, identity, V|R|X|U) once priv=U and satp.MODE=Sv32
# are both live, exactly like mmu_dtlb_permfault_f5.s -- but the load
# target's own VPN0 (5, a different index in the SAME level-0 table) is
# deliberately left unmapped (V=0, unwritten memory reads 0). Confirms
# mcause=13 (MCAUSE_LOAD_PAGE_FAULT) and mtval=the faulting VA.
addi x1, x0, 1          # 0:  x1 = 1
slli x1, x1, 12         # 4:  x1 = 0x1000 (level-0 table base)
addi x2, x0, 0x401       # 8:  level-1 PDE: PPN=1, V=1
sw   x2, 0(x0)             # 12: level-1[VPN1=0] <- PDE
addi x2, x0, 0x1B            # 16: fetch PTE value: PPN=0 (identity), V|R|X|U
sw   x2, 0(x1)                  # 20: level-0[VPN0=0] <- fetch PTE (maps u_code back to itself)
addi x3, x0, 1                    # 24: x3 = 1
slli x3, x3, 31                     # 28: x3 = 0x80000000 (satp: Sv32, ppn=0)
csrrw x0, 0x180, x3                   # 32: satp <- x3
addi x4, x0, 72                         # 36: m_handler's address
csrrw x0, mtvec, x4                       # 40: mtvec <- m_handler
addi x5, x0, 56                             # 44: u_code's address
csrrw x0, mepc, x5                            # 48: mepc <- u_code
mret                                            # 52: -> U mode, PC <- u_code (I-side translation live)
u_code:
addi x6, x0, 5                                    # 56: x6 = 5 (VPN0, arbitrary -- deliberately never mapped)
slli x6, x6, 12                                     # 60: x6 = 0x5000
lw x10, 0(x6)                                         # 64: LOAD from unmapped VA -> DTLB miss -> walk -> invalid PTE -> fault
jal x0, halt                                            # 68: unreachable if the trap fires correctly
m_handler:
csrrs x11, mcause, x0                                     # 72: expect 13 (MCAUSE_LOAD_PAGE_FAULT)
csrrs x13, 0x343, x0                                        # 76: mtval -- expect 0x5000 (the faulting VA)
halt:
jal x0, halt                                                  # 80
