# docs/adr/0023-caches.md (Phase G6/G7). Direct proof of this phase's core
# promise: a store under a write-back D$ stays dirty (uncommitted to the
# real backing memory) until fence genuinely flushes it. tb_fence_flush_g7.v
# checks the backing array directly (bypassing the cache entirely, the same
# way check_mem_word/every dump template does) both BEFORE and AFTER the
# fence to prove the flush is real, not a no-op.
addi x5, x0, 0x55       # 0: value to store
sw   x5, 40(x0)          # 4: store to addr 40 -- stays dirty in the D$ under CACHE_MODE=1
fence                     # 8: must flush the dirty line to real memory
addi x10, x0, 999          # 12: marker: fence itself didn't hang/trap

fence
halt:
jal x0, halt               # 16
