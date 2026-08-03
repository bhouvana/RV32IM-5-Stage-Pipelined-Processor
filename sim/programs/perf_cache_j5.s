# docs/adr/0025-hpc-performance-csrs.md (Phase J5). Small, straight-line
# (no loop) I$/D$ access pattern at default cache sizing (generous enough
# that nothing evicts): two distinct D$ lines (addr 0, addr 64 -- 16B
# lines, so genuinely different lines), each store-miss-then-load-hit-hit;
# two distinct I$ lines (this program's own instructions span exactly two
# 16B/4-instruction lines before the mandatory fence/halt).
addi x1, x0, 100
sw   x1, 0(x0)
lw   x2, 0(x0)
lw   x3, 0(x0)
sw   x1, 64(x0)
lw   x4, 64(x0)
fence
halt:
jal x0, halt
