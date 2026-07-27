# Load-use hazard: `add x8,x7,x7` immediately follows `lw x7,...` (gap=1 with
# a load producer). Forwarding alone can't supply this in time -- Hazard.v
# must assert stall/flush to bubble one cycle. If the stall unit were broken,
# x8 would compute from x7's pre-load (reset) value of 0, giving x8=0 instead
# of the correct 154.
addi x5, x0, 32     # scratch address for setup (well within the 128-byte data memory)
addi x6, x0, 77
sw   x6, 0(x5)
nop
nop
nop
nop                 # let the setup store fully drain before the timed part begins
lw   x7, 0(x5)      # load-use hazard starts here
add  x8, x7, x7     # must stall one cycle to get the correct (post-load) x7

halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
