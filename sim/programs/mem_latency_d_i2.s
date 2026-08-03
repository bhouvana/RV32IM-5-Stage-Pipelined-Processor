# docs/adr/0024-variable-latency-memory.md (Phase I2). A word store then a
# word load at two distinct addresses, run under MEM_LATENCY_D>0 by
# tb_mem_latency_d_i2.v -- proves real multi-cycle D-side wait-states
# produce correct data (not just correct timing), for both a write-then-
# readback and a fresh read.
addi x5, x0, 40
addi x6, x0, 123
sw   x6, 0(x5)
lw   x7, 0(x5)
addi x8, x0, 456
sw   x8, 4(x5)
lw   x9, 4(x5)

fence
halt:
jal x0, halt
