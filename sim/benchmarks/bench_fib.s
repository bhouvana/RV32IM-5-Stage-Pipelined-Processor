# Benchmark kernel (docs/ROADMAP.md Phase 10): iterative Fibonacci, 30
# iterations. ALU/branch-heavy, no memory access, no RV32M -- the "pure
# integer core" baseline the other two kernels contrast against.
addi x1, x0, 0       # a = fib(0)
addi x2, x0, 1       # b = fib(1)
addi x3, x0, 30      # iteration counter

loop:
add  x4, x1, x2      # tmp = a + b
add  x1, x0, x2      # a = b
add  x2, x0, x4      # b = tmp
addi x3, x3, -1
bne  x3, x0, loop

add x10, x1, x0      # result (fib(30) mod 2^32) -> x10/a0, debug_x10's tap

fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
