# Full trap-and-return round trip: set MIE, take an ecall trap, have the
# handler advance mepc past the ecall (standard practice -- mepc points at
# the trapping instruction itself, not the next one) and mret back. Checks
# that execution actually resumes after the ecall rather than re-trapping,
# and that mstatus's MIE/MPIE stack round-trips correctly. See
# docs/adr/0011-csr-and-exceptions.md.
addi   x5, x0, 28           # 0:  handler's address (must match the `handler:` label below)
csrrw  x0, mtvec, x5        # 4:  mtvec <- 28
csrrsi x0, mstatus, 8       # 8:  mstatus.MIE (bit3) <- 1
ecall                       # 12: mepc <- 12, mcause <- 11, MPIE <- MIE(1), MIE <- 0, pc <- mtvec
addi   x9, x0, 111          # 16: NOT skipped this time -- mret below returns here
addi   x9, x0, 222          # 20: also runs
jal    x0, halt              # 24: done with the return path, go spin

handler:
addi   x11, x0, 55          # 28: proves the trap handler ran
csrrs  x12, mepc, x0        # 32: x12 <- mepc (12, the ecall's own address)
addi   x12, x12, 4          # 36: x12 <- 16 (skip past the ecall on return)
csrrw  x0, mepc, x12        # 40: mepc <- 16
mret                        # 44: pc <- mepc(16), MIE <- MPIE(1), MPIE <- 1
halt:
jal x0, halt                 # 48: spin
