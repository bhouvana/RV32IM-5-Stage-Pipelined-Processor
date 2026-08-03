# RV32M coverage: all 8 ops plus the edge cases the spec defines explicit
# behavior for (division by zero, signed overflow) rather than leaving
# undefined. Expected values precomputed in Python, not by hand -- see the
# session notes in docs/adr/0006-rv32m.md.
addi x1, x0, 6
addi x2, x0, 7
mul  x3, x1, x2         # 6*7=42

addi x4, x0, -1
mul   x5, x4, x4         # low 32 bits of (-1)*(-1)=1 -> 1
mulh  x6, x4, x4          # signed upper bits -> 0
mulhu x7, x4, x4           # unsigned upper bits of 0xFFFFFFFF*0xFFFFFFFF -> 0xFFFFFFFE
mulhsu x8, x4, x4           # signed(-1) * unsigned(0xFFFFFFFF) upper bits -> 0xFFFFFFFF

addi x9, x0, 17
addi x10, x0, 5
div  x11, x9, x10        # 17/5=3
rem  x12, x9, x10         # 17%5=2
divu x13, x9, x10          # unsigned, same operands are positive -> 3
remu x14, x9, x10           # -> 2

addi x15, x0, -7
addi x16, x0, 2
div  x17, x15, x16       # -7/2 truncates toward zero -> -3
rem  x18, x15, x16        # -7 - (-3*2) -> -1

addi x19, x0, 5
addi x20, x0, 0
div  x21, x19, x20       # divide by zero -> -1 (0xFFFFFFFF), per spec
rem  x22, x19, x20        # divide by zero -> dividend (5), per spec
divu x23, x19, x20         # -> 0xFFFFFFFF
remu x24, x19, x20          # -> 5

lui  x25, 0x80000        # INT_MIN = 0x80000000
addi x26, x0, -1
div  x27, x25, x26       # signed overflow (INT_MIN/-1) -> INT_MIN, per spec
rem  x28, x25, x26        # signed overflow -> 0, per spec


fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
