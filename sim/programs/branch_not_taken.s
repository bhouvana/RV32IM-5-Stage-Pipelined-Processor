# beq not taken: sequential fetch was already the correct guess, so nothing
# should be squashed and the fallthrough instruction should execute exactly
# once. If the branch were wrongly resolved taken, x3 would end up 999
# instead of the fallthrough's 42.
addi x1, x0, 5
addi x2, x0, 9
beq  x1, x2, target
addi x3, x0, 42     # fallthrough -- must execute
jal  x0, end        # skip over the target block (sequential fetch would
                     # otherwise fall into it regardless of the branch)
target:
addi x3, x0, 999    # must NOT execute
end:

# bne not taken: coverage_report.py (docs/ROADMAP.md V-5) flagged bne as
# never exercised anywhere in the directed suite.
addi x4, x0, 5
addi x5, x0, 5
bne  x4, x5, target2
addi x6, x0, 42     # fallthrough -- must execute
jal  x0, end2
target2:
addi x6, x0, 999    # must NOT execute
end2:


fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
