# csrrw/csrrs/csrrc(+i variants) against mscratch (a CSR with no special
# side effects, safe to use as a plain scratch register for this test).
# Each op checks both the destination register (old CSR value) and the
# CSR's value after the op via the testbench's hierarchical check_val.
addi   x1, x0, 5
csrrw  x2, mscratch, x1     # mscratch: 0 -> 5,  x2 = old (0)
csrrs  x3, mscratch, x0     # set with src=0: no change, x3 = old (5)
addi   x4, x0, 3
csrrs  x5, mscratch, x4     # mscratch: 5 -> 5|3=7,  x5 = old (5)
addi   x6, x0, 1
csrrc  x7, mscratch, x6     # mscratch: 7 -> 7&~1=6, x7 = old (7)
csrrwi x8, mscratch, 10     # mscratch: 6 -> 10,     x8 = old (6)
csrrsi x9, mscratch, 5      # mscratch: 10 -> 10|5=15, x9 = old (10)
csrrci x10, mscratch, 2     # mscratch: 15 -> 15&~2=13, x10 = old (15)

fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
