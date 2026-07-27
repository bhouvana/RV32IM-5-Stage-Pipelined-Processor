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
nop
nop
nop
nop
nop
