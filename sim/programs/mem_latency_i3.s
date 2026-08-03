# docs/adr/0024-variable-latency-memory.md (Phase I3). Several sequential
# fetches under real I-side wait-states (CACHE_NONE), plus an unconditional
# jump -- proves imem_wait doesn't corrupt ordinary execution AND doesn't
# swallow a redirect (the itlb_miss/icache_miss stall-vs-redirect bug class,
# applied proactively here per the ADR's own Context section).
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
