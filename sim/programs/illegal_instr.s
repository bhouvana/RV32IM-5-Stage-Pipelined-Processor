# An unimplemented opcode (0x7F, not any opcode this core decodes) must trap:
# mepc <- the trapping instruction's own address, mcause <- 2 (illegal
# instruction), pc <- mtvec. x9 must never be written (the two addi's right
# after the trapping word are skipped by the redirect); x10 proves the
# handler at mtvec actually ran. See docs/adr/0011-csr-and-exceptions.md.
addi  x5, x0, 20           # 0:  handler's address (must match the `handler:` label below)
csrrw x0, mtvec, x5        # 4:  mtvec <- 20
word  0xFFFFFFFF           # 8:  opcode 0x7F -- not implemented -> illegal-instruction trap
addi  x9, x0, 111          # 12: skipped (redirected away before this is fetched-and-committed)
addi  x9, x0, 222          # 16: skipped

handler:
addi x10, x0, 77           # 20: proves the trap handler ran
halt:
jal x0, halt                # 24: spin
