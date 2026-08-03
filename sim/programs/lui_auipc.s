# lui: rd = imm (upper 20 bits, lower 12 zero). auipc: rd = PC + imm.
lui   x1, 0x12345      # x1 = 0x12345000
auipc x2, 0              # x2 = PC(this instr, =4) + 0 = 4
auipc x3, 1              # x3 = PC(this instr, =8) + 0x1000 = 0x1008

fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
