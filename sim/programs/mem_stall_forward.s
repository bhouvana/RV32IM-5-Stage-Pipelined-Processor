# Regression test for a real bug found integrating DataMemoryBRAM's
# synchronous read (docs/adr/0013-mem-stage-retiming.md): an unrelated load
# sitting between a producer and consumer must not disturb the consumer's
# MEM/WB forwarding, even though the load stalls the pipeline for a cycle
# while its own result comes back from memory.
#
# `addi x1,x0,38` (producer) and `add x8,x1,x1` (consumer) are NOT
# load-use-hazard related to the `lw` in between -- it loads into x7, from an
# address that has nothing to do with x1. An initial ("bubble") design of the
# new MEM-stage interlock evicted x1's still-needed MEM/WB-forwardable value
# out of reg4 one cycle too early to make room for the load's own stall,
# because reg4 has no `hold` of its own advancing unconditionally every
# cycle -- caught by constrained-random cross-checking (seed 39, not by any
# directed test), reproduced here directly so it can't regress silently.
addi x5, x0, 32     # scratch address
addi x6, x0, 99
sw   x6, 0(x5)
nop
nop
nop
nop                 # let the setup store fully drain before the timed part begins
addi x1, x0, 38     # producer: x1 = 38
lw   x7, 0(x5)      # unrelated load -- must not disturb x1's forwarding to the next line
add  x8, x1, x1     # consumer: needs x1 forwarded from MEM/WB (2 instructions back, across
                    # the load's own stall cycle) -- would be wrong if that forwarding broke

halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
