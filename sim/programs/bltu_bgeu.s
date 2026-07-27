# bltu/bgeu are the unsigned counterparts of blt/bge -- this specifically
# needs a value that's negative as signed but large as unsigned (0xFFFFFFFF)
# to distinguish "correctly unsigned" from "accidentally signed" (which is
# exactly the class of bug docs/adr/0004 found elsewhere in this ALU).
addi x1, x0, -1        # 0xFFFFFFFF
addi x2, x0, 1

bltu x1, x2, bad_a      # unsigned: 0xFFFFFFFF is NOT < 1 -> must NOT be taken
addi x3, x0, 1          # correct path
jal  x0, after_a
bad_a:
addi x3, x0, 999        # must not execute
after_a:

bgeu x1, x2, good_b     # unsigned: 0xFFFFFFFF IS >= 1 -> must be taken
addi x4, x0, 999        # poison #1 (must be squashed)
addi x4, x0, 888        # poison #2 (must be squashed)
good_b:
addi x4, x0, 1          # correct path

# Same x1=-1,x2=1 setup also regression-tests docs/adr/0004 (slt/blt/bge/
# ble/bgt need $signed() or they silently compare unsigned like bltu/bgeu
# above) -- signed: -1 < 1 and -1 <= 1 are both true; -1 >= 1 and -1 > 1 are
# both false. The opposite of every bltu/bgeu outcome above, on the exact
# same bit pattern -- this is the whole point of the signed/unsigned split.
blt  x1, x2, good_c     # signed: -1 < 1 -> must be taken
addi x7, x0, 999
addi x7, x0, 888
good_c:
addi x7, x0, 1

bge  x1, x2, bad_d      # signed: -1 >= 1 is false -> must NOT be taken
addi x8, x0, 1
jal  x0, after_d
bad_d:
addi x8, x0, 999
after_d:

ble  x1, x2, good_e     # signed: -1 <= 1 -> must be taken (custom op)
addi x9, x0, 999
addi x9, x0, 888
good_e:
addi x9, x0, 1

bgt  x1, x2, bad_f      # signed: -1 > 1 is false -> must NOT be taken (custom op)
addi x10, x0, 1
jal  x0, after_f
bad_f:
addi x10, x0, 999
after_f:


halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
