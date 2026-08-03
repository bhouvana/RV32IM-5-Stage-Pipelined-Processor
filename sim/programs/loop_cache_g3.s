# docs/adr/0023-caches.md (Phase G3). Directed regression: a taken-branch
# loop whose body (10 instructions, 40 bytes) exceeds a deliberately small
# I$ (2-way/32B/8B lines -- 4 lines total, see tb_icache_live_g3.v) --
# every iteration therefore needs real line refills (repeated eviction, not
# just cold misses), and `blt`'s taken redirect back to `loop:` fires
# immediately after/around those refills on every iteration but the last.
# This is the "icache_miss and branch_taken interacting under real,
# repeated eviction" scenario the phase plan called out by name -- default
# 4KB sizing would never evict for a program this small, so a directed test
# at the small override is the only way to force it deterministically
# (mirrors tb_icache_unit.v's own small-override rationale).
addi x5, x0, 0        # 0:  i = 0
addi x6, x0, 5         # 4:  N = 5
loop:
addi x7, x0, 1           # 8:  x7 = 1 (reset every iteration)
addi x7, x7, 1             # 12
addi x7, x7, 1               # 16
addi x7, x7, 1                 # 20
addi x7, x7, 1                   # 24
addi x7, x7, 1                     # 28
addi x7, x7, 1                       # 32
addi x7, x7, 1                         # 36
addi x5, x5, 1                           # 40: i++
blt  x5, x6, loop                          # 44: taken while i<N -- real redirect every iteration but the last
addi x10, x0, 999                            # 48: marker: loop finished correctly
fence
halt:
jal x0, halt                                   # 52
