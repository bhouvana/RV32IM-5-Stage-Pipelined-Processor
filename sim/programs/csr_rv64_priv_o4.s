# Generation 3, Phase O (docs/adr/0031-sv39-privilege-csr-groundwork-phase-o.md).
# Confirms the RV64/Sv39 CSR-side groundwork: mstatus.UXL/SXL read back as 2
# (fixed) alongside the existing real low-bit fields, satp's storage is
# unmasked at full 64-bit width and its derived satp_mode_w/satp_ppn_w now
# decode Sv39's own MODE/PPN layout (not Sv32's) at XLEN=64, MODE=0 (Bare)
# still decodes to satp_mode_w=0. Also confirms ordinary Bare-mode+U-mode
# execution proceeds untranslated with zero Ptw walks once privilege is
# genuinely dropped to U via mret.
#
# docs/adr/00NN-sv39-mmu-phase-p.md (Phase P3) note: this program originally
# (Phase O) also proved translate_enable stayed force-disabled at XLEN=64
# even with a real-looking Sv39 satp pattern live -- that guarantee no
# longer holds by design once Phase P3 makes translate_enable genuinely
# live at XLEN=64, so this program now leaves satp at Bare (MODE=0) before
# the mret/u_code section instead. Real end-to-end Sv39 translation is
# exercised by its own dedicated test (mirroring mmu_translate_f5.s's role
# for Sv32).
#
# sim/run_tests.sh always assembles directed programs with asm.py's default
# --xlen 32, which encodes slli/srli's shamt as only 5 bits (max 31) even
# though this testbench instantiates PIPELINED at XLEN=64 -- every shift by
# 32 or 60 below is split into two chained shifts (16+16, 30+30) that are
# exactly equivalent on the real 64-bit hardware, sidestepping the
# assembler's encoding limit without needing a real 6-bit shamt field.

# mstatus: writing all-1s sets every real bit (MIE/MPIE/SIE/SPIE/SPP/MPP,
# same real fields Phase F1 already exercises), plus the new fixed
# UXL(33:32)=2/SXL(35:34)=2 read-mux override -- expected readback
# 64'hA000019AA (0xA00000000 from UXL/SXL, 0x19AA from the real low bits,
# non-overlapping ranges).
addi x1, x0, -1          # 0:  x1 = 0xFFFFFFFFFFFFFFFF (all bits set, RV64 sign-extend)
csrrw x2, mstatus, x1      # 4:  x2 = old mstatus (0)
csrrs x3, mstatus, x0        # 8:  x3 = mstatus readback (real bits + fixed UXL/SXL)

# satp: build 64'h8123400000000155 (MODE=8/Sv39, ASID=0x1234, PPN=0x155) --
# hi32=0x81234000 via lui (any RV64 lui sign-extension garbage in bits63:32
# is discarded by the two chained slli-16s below, same "washes out" trick
# random_gen.py's own const64_to_reg_instrs uses for a single slli-32).
# lo32=0x155 fits directly in addi's 12-bit signed immediate (no masking
# needed, positive/small).
lui x5, 0x81234            # 12: x5 = sext32(0x81234000) -- garbage upper bits, washed out below
slli x5, x5, 16              # 16: (1/2) partial shift
slli x5, x5, 16                # 20: (2/2) x5 = 0x8123400000000000 (clean, original bits63:32 shifted off)
addi x6, x0, 0x155               # 24: x6 = 0x155 (already zero-extended, small positive immediate)
or x5, x5, x6                      # 28: x5 = 0x8123400000000155
csrrw x0, 0x180, x5                  # 32: satp <- x5 (old value discarded)
csrrs x7, 0x180, x0                    # 36: x7 = satp readback (raw storage, full 64-bit width)

# Same pattern with MODE forced to 0 (Bare) -- MODE occupies satp's own top
# 4 bits (63:60), so slli/srli by 4 clears exactly that field and nothing
# else, reusing x5 rather than rebuilding the whole constant.
slli x5, x5, 4                          # 40: x5 = top nibble shifted off
srli x5, x5, 4                            # 44: x5 = 0x0123400000000155 (MODE now 0/Bare)
csrrw x0, 0x180, x5                         # 48: satp <- x5 (MODE=0 this time)
csrrs x8, 0x180, x0                           # 52: x8 = satp readback (MODE field now 0)

# Clear mstatus entirely (including MPP, set to M=3 by the earlier all-1s
# write) so the mret below genuinely drops to U (MPP=0) rather than
# returning to M -- mstatus's own real-bit values from here on are never
# checked again, so a full clear is safe.
csrrw x0, mstatus, x0                           # 56: mstatus <- 0 (MPP now U)

# docs/adr/00NN-sv39-mmu-phase-p.md (Phase P3): satp is left at MODE=0
# (Bare, from x5's own value at line 47 above) rather than restored to the
# Sv39-look-alike pattern this program originally used -- Phase P3 makes
# translate_enable genuinely live at XLEN=64 (Phase O's own "stays forced
# off regardless" guarantee this program used to prove no longer holds by
# design), so a live-looking satp here would now trigger a REAL Sv39 walk
# against this program's own tiny memory, not a proven-inert no-op. This
# program's remaining, still-valid purpose is the CSR-decode groundwork
# above (UXL/SXL, mode-conditional satp_mode_w/satp_ppn_w) plus confirming
# ordinary Bare-mode+U-mode execution proceeds untranslated with zero
# Ptw walks -- real, unconditional Bare-mode behavior, not an XLEN-gate
# artifact. Real end-to-end Sv39 translation is exercised by its own
# dedicated test instead (mirroring mmu_translate_f5.s's own role for Sv32).
csrrw x0, 0x180, x5                             # 60: satp <- x5 (still Bare/MODE=0 from line 47)
addi x10, x0, 76                                  # 64: x10 = 76 (physical address of u_code, used as mepc)
csrrw x0, mepc, x10                                 # 68: mepc <- x10
mret                                                  # 72: -> U mode (MPP was cleared to U above), PC <- 76, untranslated
u_code:
addi x11, x0, 222                                       # 76: marker -- fetch landed here in U-mode, untranslated
addi x12, x0, 92                                          # 80: x12 = 92 (store/load address, still physical)
addi x13, x0, 999                                           # 84: value to store
sw   x13, 0(x12)                                              # 88: D-side store -- must NOT fault
lw   x14, 0(x12)                                                # 92: D-side load round trip
fence
halt:
jal x0, halt                                                      # 100
