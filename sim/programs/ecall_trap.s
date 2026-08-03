# ecall must trap with mcause = 11 (ECALL_FROM_M): mepc <- ecall's own
# address, pc <- mtvec. Same shape as illegal_instr.s/ebreak_trap.s -- only
# the trapping instruction and expected mcause differ. See
# docs/adr/0011-csr-and-exceptions.md.
addi  x5, x0, 20           # 0:  handler's address (must match the `handler:` label below)
csrrw x0, mtvec, x5        # 4:  mtvec <- 20
ecall                      # 8:  mepc <- 8, mcause <- 11, pc <- mtvec
addi  x9, x0, 111          # 12: skipped
addi  x9, x0, 222          # 16: skipped

handler:
addi x10, x0, 77           # 20: proves the trap handler ran
fence
halt:
jal x0, halt                # 24: spin
