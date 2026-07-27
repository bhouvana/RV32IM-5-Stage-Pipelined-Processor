# sw immediately followed by lw to the same address. DataMemory's write
# commits synchronously at the end of sw's MEM-stage cycle, one cycle before
# lw performs its own (combinational) MEM-stage read, so this needs no extra
# hazard handling -- this test exists to prove that ordering, not to test a
# hazard unit.
addi x5, x0, 16
addi x6, x0, 1234
sw   x6, 0(x5)
lw   x7, 0(x5)

halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
