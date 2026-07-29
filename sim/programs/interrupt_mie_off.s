# docs/adr/0020-soc-integration.md (Phase D9). Directed test: mstatus.MIE=0
# must block BOTH interrupt sources even when they are genuinely pending
# (mip.MTIP -- Timer.v resets with mtime=0/mtimecmp=0, pending immediately,
# tb_timer_unit.v's own documented reset behavior) and enabled (mie.MTIE=1,
# mie.MEIE=1). mstatus.MIE is deliberately never written by this program --
# it stays at its own reset value of 0 throughout. The loop must run to
# completion untouched and the handler must never execute.
# Layout: loop = [28, 104], self = 108, handler = 112
lui   x2, 0x10000  # 0: x2 = MMIO_BASE
addi  x2, x2, 16  # 4: x2 = TIMER_BASE (unused here -- MTIMECMP's reset value of 0 already makes mip.MTIP pending immediately, tb_timer_unit.v's own documented reset behavior)
addi  x5, x0, 112  # 8: x5 = handler address (112) -- armed but must never be reached
csrrw x0, mtvec, x5  # 12
addi  x6, x0, -1920  # 16: 0xFFFFF880 after sign-ext -- CSR.v's mie_masked only reads bits 7/11, both set here (MTIE|MEIE), same harmless-masking reasoning as mip_live.s's andi checks
csrrw x0, mie, x6  # 20: mie = MTIE|MEIE <- both enabled
# mstatus.MIE is deliberately NEVER set -- stays 0 for this entire program  # 24
addi  x10, x10, 1  # 28
addi  x10, x10, 1  # 32
addi  x10, x10, 1  # 36
addi  x10, x10, 1  # 40
addi  x10, x10, 1  # 44
addi  x10, x10, 1  # 48
addi  x10, x10, 1  # 52
addi  x10, x10, 1  # 56
addi  x10, x10, 1  # 60
addi  x10, x10, 1  # 64
addi  x10, x10, 1  # 68
addi  x10, x10, 1  # 72
addi  x10, x10, 1  # 76
addi  x10, x10, 1  # 80
addi  x10, x10, 1  # 84
addi  x10, x10, 1  # 88
addi  x10, x10, 1  # 92
addi  x10, x10, 1  # 96
addi  x10, x10, 1  # 100
addi  x10, x10, 1  # 104
self:
jal   x0, self  # 108: spin once the loop completes
handler:
addi  x11, x0, 777  # 112: must NEVER run -- mstatus.MIE=0 blocks both pending, enabled sources
mret  # 116
