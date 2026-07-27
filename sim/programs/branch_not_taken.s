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
nop
nop
nop
nop
nop
