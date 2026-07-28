# Closes ARCHITECTURE.md/ROADMAP's documented gap: bltu_bgeu.s exercises
# blt/bge/ble/bgt/bltu/bgeu but each only in one branch direction (taken or
# not-taken, never both). Same x1=-1(0xFFFFFFFF)/x2=1 bit pattern as
# bltu_bgeu.s, but every comparison here has rs1/rs2 *swapped* relative to
# that file -- since none of these are the equality case, swapping the
# operands always flips the outcome, so this exercises exactly the direction
# bltu_bgeu.s didn't.
addi x1, x0, -1        # 0xFFFFFFFF
addi x2, x0, 1

bltu x2, x1, good_a     # unsigned: 1 IS < 0xFFFFFFFF -> must be taken (bltu_bgeu.s only covers not-taken)
addi x3, x0, 999
addi x3, x0, 888
good_a:
addi x3, x0, 1

bgeu x2, x1, bad_b      # unsigned: 1 is NOT >= 0xFFFFFFFF -> must NOT be taken (bltu_bgeu.s only covers taken)
addi x4, x0, 1
jal  x0, after_b
bad_b:
addi x4, x0, 999
after_b:

blt  x2, x1, bad_c      # signed: 1 is NOT < -1 -> must NOT be taken (bltu_bgeu.s only covers taken)
addi x5, x0, 1
jal  x0, after_c
bad_c:
addi x5, x0, 999
after_c:

bge  x2, x1, good_d     # signed: 1 IS >= -1 -> must be taken (bltu_bgeu.s only covers not-taken)
addi x6, x0, 999
addi x6, x0, 888
good_d:
addi x6, x0, 1

ble  x2, x1, bad_e      # signed: 1 is NOT <= -1 -> must NOT be taken, custom op (bltu_bgeu.s only covers taken)
addi x7, x0, 1
jal  x0, after_e
bad_e:
addi x7, x0, 999
after_e:

bgt  x2, x1, good_f     # signed: 1 IS > -1 -> must be taken, custom op (bltu_bgeu.s only covers not-taken)
addi x8, x0, 999
addi x8, x0, 888
good_f:
addi x8, x0, 1

halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
