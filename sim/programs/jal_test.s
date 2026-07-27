# jal: verifies (1) target computation/squash -- the two poison instructions
# after jal must never execute, (2) link value -- x1 must equal jal's own
# PC+4, and (3) the EX/MEM forwarding correction for jal's result (the
# instruction right after the target depends immediately on x1, forcing the
# forwarding unit down the path that must hand out PC+4, not the jal
# instruction's meaningless raw ALU output).
jal  x1, target
addi x2, x0, 999    # poison #1 (must be squashed)
addi x2, x0, 888    # poison #2 (must be squashed)
target:
add  x3, x1, x1     # depends on jal's link register with a 1-instruction gap

halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
