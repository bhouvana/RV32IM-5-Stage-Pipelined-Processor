# Stress EX/MEM forwarding: each add depends on the immediately preceding
# instruction's result (gap=1), so every operand must come from the
# EX/MEM forwarding path (Forward.v forwardA/B == 2'b10), never a stale
# register-file read.
addi x1, x0, 1
add  x1, x1, x1   # 1+1=2
add  x1, x1, x1   # 2+2=4
add  x1, x1, x1   # 4+4=8
add  x1, x1, x1   # 8+8=16
add  x1, x1, x1   # 16+16=32

fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
