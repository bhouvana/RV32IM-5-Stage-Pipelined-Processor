# Generation 2 (Phase M8, docs/adr/0028-rv64-migration-phase-m.md). Exercises
# every new RV64-only instruction end to end through the real assembled
# pipeline at XLEN=64: addiw/slliw/srliw/sraiw/addw/subw/sllw/srlw/sraw/mulw/
# divw/divuw/remw/remuw/ld/sd/lwu. Expected values hand-derived below, each
# with its own comment; checked via check_reg in the testbench.
#
# x2 = -2 (0xFFFFFFFFFFFFFFFE, low 32 bits 0xFFFFFFFE) is the main operand
# reused across most of these -- deliberately NOT zero/trivial, so
# truncation-to-32-bits is actually being exercised, not accidentally
# skipped. x9 vs x11 (sllw vs plain sll on the same operands) is the key
# differentiator proving wordOp_regde really reaches the ALU, not just
# "happens to produce a plausible-looking value": the two must differ.
addi x1, x0, 1           # 0:  x1 = 1
addi x2, x0, -2            # 4:  x2 = -2 (low32 = 0xFFFFFFFE)
addi x10, x0, 31             # 8:  x10 = 31 (shift amount)
addi x20, x0, 3                # 12: x20 = 3 (divisor)
addi x30, x0, 64                 # 16: x30 = 64 (data address for sd/ld/lwu)

addiw x3, x2, 1                    # 20: low32(0xFFFFFFFE)+1 = 0xFFFFFFFF (-1), sign-ext -> -1
slliw x4, x2, 4                      # 24: low32<<4 = 0xFFFFFFE0, sign-ext -> 0xFFFFFFFFFFFFFFE0
srliw x5, x2, 4                        # 28: low32>>4 (logical) = 0x0FFFFFFF, sign-ext(bit31=0) -> 0x000000000FFFFFFF
sraiw x6, x2, 4                          # 32: low32(-2 as i32)>>>4 = -1, sign-ext -> -1
addw  x7, x2, x1                           # 36: low32(-2)+low32(1) = -1, sign-ext -> -1
subw  x8, x0, x2                             # 40: 0-low32(0xFFFFFFFE) = 2, sign-ext -> 2
sllw  x9, x1, x10                              # 44: low32(1)<<31 = 0x80000000, sign-ext -> 0xFFFFFFFF80000000 (negative)
sll   x11, x1, x10                               # 48: plain 64-bit: 1<<31 = 0x0000000080000000 (positive -- MUST differ from x9)
srlw  x12, x2, x10                                 # 52: low32(0xFFFFFFFE)>>31 (logical) = 1, sign-ext -> 1
sraw  x13, x2, x10                                   # 56: low32(-2 as i32)>>>31 = -1, sign-ext -> -1
mulw  x14, x2, x1                                      # 60: low32(-2)*low32(1) = -2, sign-ext -> -2
divw  x15, x2, x20                                       # 64: signed -2/3 (round toward zero) = 0
divuw x16, x2, x20                                         # 68: unsigned 0xFFFFFFFE/3 = 1431655764
remw  x17, x2, x20                                           # 72: signed -2 rem 3 = -2
remuw x18, x2, x20                                             # 76: unsigned 0xFFFFFFFE rem 3 = 2

sd    x2, 0(x30)                                                 # 80: store full 64-bit -2
ld    x27, 0(x30)                                                  # 84: read back full 64-bit -> -2 (ld sign-extends/reads whole word)
lwu   x28, 0(x30)                                                    # 88: read back low 32 zero-extended -> 0x00000000FFFFFFFE (differs from x27)

fence
halt:
jal x0, halt                                                          # 96
