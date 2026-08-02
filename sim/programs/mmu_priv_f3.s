# docs/adr/00NN-mmu-sv32.md (Phase F3). End-to-end privilege-aware trap
# integration test: M sets up stvec/mtvec/medeleg, mret drops to U (MPP's
# reset-default value, never explicitly set -- mstatus starts at 0), a
# U-mode ecall is correctly delegated to S (medeleg bit 8 set), and an
# illegal mret attempted from S (mret requires M) correctly traps back to
# M as an ordinary undelegated illegal-instruction exception (medeleg bit 2
# is deliberately left clear).
# Layout: m_handler2=48, s_handler=40, u_code=36, halt=56.
addi x2, x0, 48        # 0: x2 = m_handler2's address
csrrw x0, mtvec, x2     # 4: mtvec <- m_handler2
addi x2, x0, 40          # 8: x2 = s_handler's address
csrrw x0, 0x105, x2       # 12: stvec <- s_handler
addi x3, x0, 0x100         # 16: bit8 = MCAUSE_ECALL_FROM_U
csrrw x0, 0x302, x3          # 20: medeleg <- delegate ecall-from-U to S (bit2, illegal instr, deliberately NOT delegated)
addi x5, x0, 36               # 24: x5 = u_code's address
csrrw x0, mepc, x5              # 28: mepc <- u_code
mret                              # 32: -> priv_mode <- MPP (U, mstatus's reset-default MPP), PC <- u_code
u_code:
ecall                              # 36: priv=U, delegated (medeleg[8]=1) -> traps to S via stvec
s_handler:
csrrs x20, 0x142, x0                 # 40: x20 = scause (expect 8 = MCAUSE_ECALL_FROM_U)
mret                                  # 44: priv=S != M -> illegal-instruction violation, NOT a real mret --
                                        #     traps to M (undelegated: medeleg bit2 is clear)
m_handler2:
csrrs x21, mcause, x0                   # 48: x21 = mcause (expect 2 = MCAUSE_ILLEGAL_INSTRUCTION)
csrrs x22, mstatus, x0                    # 52: x22 = mstatus (expect MPP=S=01 at bits[12:11] -> 0x800)

halt:
jal x0, halt                                # 56
