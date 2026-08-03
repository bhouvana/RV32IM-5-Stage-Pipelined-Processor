# docs/adr/0023-caches.md (Phase G1). fence has zero live effect yet (G6's
# job -- real cache-flush semantics); this program only confirms it decodes
# correctly (falls through, doesn't trap) mid-stream, twice, the same
# decode-only coverage sfence.vma got in F2 (sim/programs/mmu_decode_f2.s).
addi x10, x0, 1        # 0: marker: program started
fence                   # 4: real fence -- must decode, not trap
addi x10, x10, 1        # 8: marker: fence #1 fell through
fence                    # 12: second fence, mid-stream
addi x10, x10, 1         # 16: marker: fence #2 fell through

fence
halt:
jal x0, halt            # 20
