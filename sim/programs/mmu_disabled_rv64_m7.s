# Generation 2 (Phase M, docs/adr/0028-rv64-migration-phase-m.md). M7:
# originally confirmed the MMU was force-disabled at XLEN=64 via a hard
# XLEN==32 gate on translate_enable. That gate is gone as of Phase P3
# (docs/adr/00NN-sv39-mmu-phase-p.md) -- translation is now genuinely live
# at XLEN=64 -- but this program's own satp pattern (MODE=1 at Sv32's old
# bit-31 position, PPN=0) still correctly decodes as satp_mode_w=0 (Bare)
# under Sv39's real bit[63:60] MODE field (Phase O), since bit 31 isn't part
# of that field at all. So execution still proceeds untranslated here, now
# for the right structural reason (a genuinely Bare satp) rather than an
# XLEN gate. mret drops to U-mode at what would be treated as a *virtual*
# address if translation were live; if satp_mode_w incorrectly read
# nonzero, the first U-mode fetch would page-fault (redirecting to
# mtvec=0, an infinite loop, never reaching the marker below) or
# mistranslate -- since it correctly decodes Bare, the "virtual" address IS
# the physical address, and the store/load below also go straight through.
addi x3, x0, 1          # 0:  x3 = 1
slli x3, x3, 31          # 4:  x3 = 0x80000000 (satp: MODE=1(Sv32), PPN=0)
csrrw x0, 0x180, x3        # 8:  satp <- x3
addi x4, x0, 24              # 12: x4 = 24 (physical address of u_code, used
                               #     directly as mepc)
csrrw x0, mepc, x4              # 16: mepc <- x4
mret                              # 20: -> U mode, PC <- 24, untranslated
u_code:
addi x10, x0, 111                  # 24: marker -- proves fetch landed here untranslated
addi x6, x0, 40                      # 28: x6 = 40 (store/load address, still physical)
addi x11, x0, 777                      # 32: value to store
sw   x11, 0(x6)                          # 36: D-side store -- must NOT fault
lw   x12, 0(x6)                            # 40: D-side load round trip
fence
halt:
jal x0, halt                                 # 48
