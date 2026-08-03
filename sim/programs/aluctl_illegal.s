# A *recognized* opcode (R-type, 0110011) with an unrecognized funct7/funct3
# combination must also trap -- distinct from illegal_instr.s, which covers
# an entirely unrecognized opcode (illegalOpcode_regde, caught by Control.v
# at decode time). This is ALUCtl==ALUCTL_ILLEGAL (design/ALUCtrl.v's
# `default` arm), only known after ALUCtrl has decoded a recognized opcode's
# funct7/funct3 and found no valid operation -- resolved one cycle later in
# EX, but reuses the exact same trap machinery (see docs/adr/0011-csr-and-
# exceptions.md). `word 0x40001033` is funct7=0100000 (the ALT block, which
# only defines sub/sra/ctz) with funct3=001 -- a combination ALUCtrl.v's
# case statement has no arm for.
addi  x5, x0, 20           # 0:  handler's address (must match the `handler:` label below)
csrrw x0, mtvec, x5        # 4:  mtvec <- 20
word  0x40001033           # 8:  R-type, funct7=ALT/funct3=001 -- no such op -> illegal trap
addi  x9, x0, 111          # 12: skipped (redirected away before this is fetched-and-committed)
addi  x9, x0, 222          # 16: skipped

handler:
addi x10, x0, 77           # 20: proves the trap handler ran
fence
halt:
jal x0, halt                # 24: spin
