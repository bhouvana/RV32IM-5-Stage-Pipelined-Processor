# Visualization demo program: deliberately exercises EX/MEM forwarding, a
# load-use stall, and a taken branch in one short trace so the pipeline
# viewer (docs/pipeline-viewer or sim/tools/gen_trace.py) has something
# visually interesting to show.
addi x1, x0, 5
addi x2, x0, 3
add  x3, x1, x2
addi x5, x0, 20
sw   x3, 0(x5)
lw   x6, 0(x5)
add  x7, x6, x6      # load-use stall
beq  x1, x1, target  # always taken
addi x8, x0, 999      # poison (squashed)
addi x8, x0, 888      # poison (squashed)
target:
addi x8, x0, 42

fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
