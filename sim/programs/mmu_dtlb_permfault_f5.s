# docs/adr/00NN-mmu-sv32.md (Phase F7). D-side permission violation: a
# guaranteed store to a page mapped READ-ONLY (V|R|U, no W). Closes a gap
# flagged as deferred in F5's own handoff notes and matches the phase
# plan's own F7 ask ("one guaranteed permission violation" directed test).
# Confirms mcause=15 (MCAUSE_STORE_PAGE_FAULT) and mtval=the faulting VA.
#
# Layout: satp_ppn=0 (level-1 table @ data addr 0), level-0 table @ PPN=1
# (0x1000). VPN0=0 maps u_code itself back to instruction-memory PPN=0
# (V|R|X|U -- fetch needs translation too, once priv=U and satp.MODE=Sv32
# are both live, exactly like F5's own mmu_translate_f5.s). VPN0=1 maps a
# read-only data page (PPN=2, V|R|U, no W).
addi x1, x0, 1          # 0:  x1 = 1
slli x1, x1, 12         # 4:  x1 = 0x1000 (level-0 table base)
addi x2, x0, 0x401       # 8:  level-1 PDE: PPN=1, V=1
sw   x2, 0(x0)             # 12: level-1[VPN1=0] <- PDE
addi x2, x0, 0x1B            # 16: fetch PTE value: PPN=0 (identity), V|R|X|U
sw   x2, 0(x1)                  # 20: level-0[VPN0=0] <- fetch PTE (maps u_code back to itself)
addi x2, x0, 2                    # 24: x2 = 2 (read-only page PPN)
slli x2, x2, 10                     # 28: x2 = 0x800
ori  x2, x2, 0x13                     # 32: x2 = 0x813 -- PPN=2, V|R|U (no W -- read-only)
sw   x2, 4(x1)                          # 36: level-0[VPN0=1] <- read-only PTE
addi x3, x0, 1                            # 40: x3 = 1
slli x3, x3, 31                             # 44: x3 = 0x80000000 (satp: Sv32, ppn=0)
csrrw x0, 0x180, x3                           # 48: satp <- x3
addi x4, x0, 96                                 # 52: m_handler's address
csrrw x0, mtvec, x4                               # 56: mtvec <- m_handler
addi x5, x0, 72                                     # 60: u_code's address
csrrw x0, mepc, x5                                    # 64: mepc <- u_code
mret                                                    # 68: -> U mode, PC <- u_code (I-side translation live)
u_code:
addi x6, x0, 1                                            # 72: x6 = 1 (VPN0 for the mapped data)
slli x6, x6, 12                                             # 76: x6 = 0x1000
ori  x6, x6, 4                                                # 80: x6 = 0x1004 = VA_data (read-only)
addi x7, x0, 999                                                # 84: value to (attempt to) store
sw   x7, 0(x6)                                                    # 88: STORE to read-only page -> STORE_PAGE_FAULT
jal x0, halt                                                        # 92: unreachable if the trap fires correctly
m_handler:
csrrs x11, mcause, x0                                                 # 96: expect 15 (MCAUSE_STORE_PAGE_FAULT)
csrrs x13, 0x343, x0                                                    # 100: mtval -- expect 0x1004
halt:
jal x0, halt                                                              # 104
