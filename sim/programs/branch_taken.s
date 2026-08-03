# beq taken: the two sequentially-fetched instructions after the branch
# (poison #1, poison #2) land in IF/ID and ID/EX at branch-resolve time and
# must be squashed to nop by reg1/reg2. If squash were broken, x3 would end
# up 999 or 888 instead of the target's 42.
addi x1, x0, 5
addi x2, x0, 5
beq  x1, x2, target
addi x3, x0, 999    # poison #1 (must be squashed)
addi x3, x0, 888    # poison #2 (must be squashed)
target:
addi x3, x0, 42

# bne taken: coverage_report.py (docs/ROADMAP.md V-5) flagged bne as never
# exercised anywhere in the directed suite -- every other branch type had a
# directed test, this one didn't, purely by omission.
addi x4, x0, 5
addi x5, x0, 9
bne  x4, x5, target2
addi x6, x0, 999    # poison #1 (must be squashed)
addi x6, x0, 888    # poison #2 (must be squashed)
target2:
addi x6, x0, 42


fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
