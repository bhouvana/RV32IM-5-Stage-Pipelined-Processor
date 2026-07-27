# lui: rd = imm (upper 20 bits, lower 12 zero). auipc: rd = PC + imm.
lui   x1, 0x12345      # x1 = 0x12345000
auipc x2, 0              # x2 = PC(this instr, =4) + 0 = 4
auipc x3, 1              # x3 = PC(this instr, =8) + 0x1000 = 0x1008
nop
nop
nop
nop
nop
