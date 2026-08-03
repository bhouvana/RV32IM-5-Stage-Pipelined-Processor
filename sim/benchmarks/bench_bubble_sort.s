# Benchmark kernel (docs/ROADMAP.md Phase 10): bubble sort, 6 elements,
# initialized reverse-sorted (worst case -- every compare is also a swap).
# Nested loops + a data-dependent branch (ble, custom op) + back-to-back
# loads immediately followed by a compare -- the load-use-heaviest of the
# three kernels. Needs more than the default 128-byte memory (32
# instructions), so bench_runner.py runs this one with a larger
# MEM_SIZE_BYTES (docs/adr/0015's parameterization is what makes that a
# one-line runner change instead of an RTL one).
addi x9, x0, 64        # array base address
addi x1, x0, 6
sw   x1, 0(x9)
addi x1, x0, 5
sw   x1, 4(x9)
addi x1, x0, 4
sw   x1, 8(x9)
addi x1, x0, 3
sw   x1, 12(x9)
addi x1, x0, 2
sw   x1, 16(x9)
addi x1, x0, 1
sw   x1, 20(x9)

addi x2, x0, 6         # n
addi x3, x0, 0         # i

outer:
bge  x3, x2, done_sort
addi x4, x0, 0          # j = 0
sub  x11, x2, x3          # limit = n - i
addi x11, x11, -1          # limit = n - i - 1

inner:
bge  x4, x11, inner_done
slli x12, x4, 2           # byte offset = j*4
add  x13, x9, x12          # &arr[j]
lw   x14, 0(x13)            # arr[j]
lw   x15, 4(x13)             # arr[j+1]
ble  x14, x15, no_swap        # already in order -> skip
sw   x15, 0(x13)
sw   x14, 4(x13)
no_swap:
addi x4, x4, 1
jal  x0, inner

inner_done:
addi x3, x3, 1
jal  x0, outer

done_sort:
lw   x10, 0(x9)        # smallest element (should be 1) -> x10/a0

fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
