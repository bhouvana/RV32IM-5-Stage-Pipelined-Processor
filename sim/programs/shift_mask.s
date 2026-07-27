# Regression test for a bug constrained-random testing found (docs/adr/0010):
# R-type sll/srl/sra must use only rs2[4:0] as the shift amount (per spec),
# but ALU.v used the raw rs2 value directly -- harmless whenever the shift
# register happened to already hold a small value (every hand-written
# directed test did, by chance), and silently wrong (Verilog shifts by >=32
# discard every bit) whenever it held anything else, which is the ordinary
# case for a real register.
addi x1, x0, 35        # shift amount register holds 35 (>31) -- masked to 35&0x1F=3
addi x2, x0, 1
sll  x3, x2, x1          # 1<<3=8, NOT 1<<35 (which would be 0)
addi x4, x0, -8           # 0xFFFFFFF8
srl  x5, x4, x1             # logical: 0xFFFFFFF8>>3 = 0x1FFFFFFF
sra  x6, x4, x1              # arithmetic: -8>>>3 = -1 (0xFFFFFFFF), sign preserved
nop
nop
nop
nop
nop
