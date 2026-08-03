# docs/adr/0025-hpc-performance-csrs.md (Phase J3). 10 independent,
# hazard-free straight-line instructions (distinct dest regs, no loads/
# stores/branches) so minstret's retirement cadence is exactly 1/cycle
# once the pipeline fills -- no redirect/stall cadence to reason about.
addi x1, x0, 1
addi x2, x0, 2
addi x3, x0, 3
addi x4, x0, 4
addi x5, x0, 5
addi x6, x0, 6
addi x7, x0, 7
addi x8, x0, 8
addi x9, x0, 9
addi x10, x0, 10
fence
halt:
jal x0, halt
