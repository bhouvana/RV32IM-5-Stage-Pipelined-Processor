# Verifies that a multi-cycle division's result reaches an immediately-
# dependent next instruction correctly via ordinary EX/MEM forwarding, with
# no special-case correction needed (unlike jal/jalr's pc_plus4 override,
# docs/adr/0001) -- because ex_result (riscvpipeline.v) already substitutes
# the divider's output for ALUOut before reg3 latches it, Forward.v's
# existing exmem_fwd_val path sees the correct value with no changes.
# See docs/adr/0009-multicycle-divider.md.
addi x1, x0, 17
addi x2, x0, 5
div  x3, x1, x2       # x3 = 3, takes ~33 cycles (pipeline stalls throughout)
add  x4, x3, x3        # immediately dependent -- must forward div's real result, not garbage

fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
