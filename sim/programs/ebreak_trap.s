# ebreak must trap with mcause = 3 (BREAKPOINT): mepc <- ebreak's own
# address, pc <- mtvec. Same shape as ecall_trap.s/illegal_instr.s -- only
# the trapping instruction and expected mcause differ. See
# docs/adr/0011-csr-and-exceptions.md.
addi  x5, x0, 20           # 0:  handler's address (must match the `handler:` label below)
csrrw x0, mtvec, x5        # 4:  mtvec <- 20
ebreak                     # 8:  mepc <- 8, mcause <- 3, pc <- mtvec
addi  x9, x0, 111          # 12: skipped
addi  x9, x0, 222          # 16: skipped

handler:
addi x10, x0, 77           # 20: proves the trap handler ran
halt:
jal x0, halt                # 24: spin
