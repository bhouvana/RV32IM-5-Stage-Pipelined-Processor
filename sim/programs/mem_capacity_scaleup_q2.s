# Phase Q (docs/adr/0033-memory-capacity-scale-up-phase-q.md): proves
# MEM_SIZE_BYTES=67108864 (64MB) really decodes and reaches
# DataMemoryBRAM.v end to end, not just the low addresses every other test
# already exercises. A baseline store+load near address 0, then a second
# store+load at the literal top of the 64MB region (MEM_SIZE_BYTES-8,
# 8-byte aligned for sd/ld) -- if WbDecoder/RamWishboneAdapter/
# DataMemoryBRAM's address decode silently clipped anywhere below the real
# 64MB boundary, this second pair would read back wrong (or X).
lui   x5, 0x4000        # 0:  x5 = 0x4000000 = 67108864 (MEM_SIZE_BYTES)
addi  x6, x5, -8          # 4:  x6 = 0x3FFFFF8 = 67108856 (top-of-region, 8B aligned)
addi  x1, x0, 100          # 8:  baseline value
addi  x2, x0, -777           # 12: top-of-memory value

sw    x1, 0(x0)                # 16: baseline store near address 0
lw    x3, 0(x0)                  # 20: baseline load back

sd    x2, 0(x6)                    # 24: store at top of 64MB region
ld    x4, 0(x6)                      # 28: load back full 64 bits

fence
halt:
jal x0, halt                           # 36
