# docs/adr/0026-performance-profiler.md (Phase K1). imem_wait (event 18)
# under CACHE_NONE + a real MEM_LATENCY_I (docs/adr/0024-variable-latency-
# memory.md's own Phase I3 scenario, reused verbatim below labels are
# resolved by asm.py so prepending this reprogram doesn't disturb the
# original program's own jal/target addresses). Reprograms mhpmevent3 to
# select event 18 (stall_imem_wait_pulse) before the same sequential-fetch-
# plus-jump pattern I3 already established.
csrrwi x0, 0x323, 18   # mhpmevent3 = event 18 (stall_imem_wait_pulse)

addi x1, x0, 1
addi x2, x0, 2
jal  x0, target
addi x3, x0, 99
addi x3, x0, 99
target:
addi x4, x0, 4
addi x5, x0, 5

fence
halt:
jal x0, halt
