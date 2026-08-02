# docs/adr/00NN-mmu-sv32.md (Phase F5). Closes a real gap this phase's own
# hand-trace found in F3's csr_priv_violation logic: reg3_bubble (today:
# div_stall|fp_stall) did not include exception_taken, so a privileged
# CSR's real value could still reach rd via reg3/reg4 one cycle before the
# trap redirect became visible anywhere else. Fixed by folding
# exception_taken into reg3_bubble (see riscvpipeline.v). No MMU/satp
# involvement needed -- csr_priv_violation is a pure privilege check,
# independent of address translation.
#
# M-mode poisons mscratch with a distinctive value, drops to U (mstatus's
# reset-default MPP), then U attempts csrrs on mscratch (M-only -- CSR
# address bits[9:8]==11) -- a real privilege violation. Confirms both that
# the trap fires with the right cause AND that rd (x10) never actually
# received mscratch's real value.
addi x2, x0, 999      # 0:  poison value
csrrw x0, mscratch, x2  # 4:  mscratch <- 999
addi x4, x0, 36           # 8:  m_handler's address
csrrw x0, mtvec, x4         # 12: mtvec <- m_handler
addi x3, x0, 28               # 16: u_code's address
csrrw x0, mepc, x3               # 20: mepc <- u_code
mret                                # 24: -> U mode (mstatus reset-default MPP=U), PC <- u_code
u_code:
csrrs x10, mscratch, x0               # 28: PRIVILEGE VIOLATION (U attempting an M-only CSR read) --
                                        #     x10 must NOT end up with 999 (mscratch's real value)
jal x0, halt                             # 32: unreachable if the trap fires correctly
m_handler:
csrrs x11, mcause, x0                      # 36: expect 2 (MCAUSE_ILLEGAL_INSTRUCTION)
halt:
jal x0, halt                                 # 40
