# docs/adr/0026-performance-profiler.md (Phase K1). icache_miss (event 17)
# under CACHE_MODE=1 -- reuses sim/programs/perf_cache_j5.s's own proven
# I$/D$ access pattern (two distinct D$ lines, two distinct I$ lines)
# verbatim, with mhpmevent3 reprogrammed to event 17 (stall_icache_pulse,
# a per-cycle DURATION count) instead of J5's own event-4 (icache_miss_
# pulse, an edge-detected OCCURRENCE count) -- a different question, same
# underlying icache_miss wire.
csrrwi x0, 0x323, 17   # mhpmevent3 = event 17 (stall_icache_pulse)

addi x1, x0, 100
sw   x1, 0(x0)
lw   x2, 0(x0)
lw   x3, 0(x0)
sw   x1, 64(x0)
lw   x4, 64(x0)
fence
halt:
jal x0, halt
