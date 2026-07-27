# Byte/halfword load-store: sign vs. zero extension on load, and (via the
# final lw) that sh/sb only touch the bytes they own rather than the whole
# word the way the original word-only DataMemory always did.
addi x5, x0, 40         # base address
addi x6, x0, -1          # 0xFFFFFFFF
sb   x6, 0(x5)
lb   x7, 0(x5)            # sign-extend of 0xFF -> -1 (0xFFFFFFFF)
lbu  x8, 0(x5)             # zero-extend of 0xFF -> 255

lui  x9, 0xABCDE            # x9 = 0xABCDE000
sh   x9, 8(x5)                # stores only the low halfword (0xE000) at addr 48
lh   x10, 8(x5)                # sign-extend of 0xE000 (bit15 set) -> 0xFFFFE000
lhu  x11, 8(x5)                 # zero-extend -> 0x0000E000
lw   x12, 8(x5)                  # full-word readback: must be 0x0000E000, NOT
                                  # 0xABCDE000 -- if sh had wrongly written all 4
                                  # bytes (like the original word-only sw), the
                                  # upper half would leak 0xABCD in here.

halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
