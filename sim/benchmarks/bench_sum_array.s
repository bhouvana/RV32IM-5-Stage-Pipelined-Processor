# Benchmark kernel (docs/ROADMAP.md Phase 10): fill a 16-element array then
# sum it. Memory-access-heavy -- exercises the docs/adr/0013 MEM-stage
# interlock (one store or load nearly every loop iteration) rather than
# bench_fib.s's pure-ALU pattern.
addi x9, x0, 32       # array base address
addi x6, x0, 16       # element count
addi x7, x0, 1        # fill value (1, 2, 3, ...)
addi x8, x0, 0        # fill index

fill_loop:
sw   x7, 0(x9)
addi x9, x9, 4
addi x7, x7, 1
addi x8, x8, 1
bne  x8, x6, fill_loop

addi x9, x0, 32       # reset pointer to array base
addi x5, x0, 0        # accumulator
addi x8, x0, 0        # sum index

sum_loop:
lw   x10, 0(x9)
add  x5, x5, x10
addi x9, x9, 4
addi x8, x8, 1
bne  x8, x6, sum_loop

add x10, x5, x0       # result (1+2+...+16 = 136) -> x10/a0

fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
