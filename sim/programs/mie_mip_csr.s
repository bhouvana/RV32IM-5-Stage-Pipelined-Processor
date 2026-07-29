# docs/adr/0020-soc-integration.md (Phase D7): mie/mip CSR-only test -- no
# live interrupt redirect exists yet (D9's job), this only confirms the
# read/write/masking plumbing itself. mie/mip addresses (0x304/0x344) used
# directly (raw hex) rather than added to asm.py's CSR_ADDR name table,
# matching the fflags/frm/fcsr precedent from Phase C9.

# mie: write a broad bitmask covering only unreal bits -- none should stick.
addi x1, x0, 0x7F          # bits 0-6, none real
csrrw x2, 0x304, x1        # mie: 0 -> masked(0x7F) = 0, x2 = old (0)
csrrs x3, 0x304, x0        # read back: 0

# mie: set MTIE (bit7) alone.
addi x1, x0, 0x80
csrrw x4, 0x304, x1        # mie: 0 -> 0x80, x4 = old (0)
csrrs x5, 0x304, x0        # read back: 0x80

# mie: csrrw REPLACES (not ORs) -- set MEIE (bit11) alone, MTIE must drop.
lui x1, 0x1
addi x1, x1, -2048         # x1 = 0x800 (bit11 = MEIE)
csrrw x6, 0x304, x1        # mie: 0x80 -> 0x800, x6 = old (0x80)
csrrs x7, 0x304, x0        # read back: 0x800

# mie: csrrs ORs -- both MTIE and MEIE end up set together.
addi x1, x0, 0x80
csrrs x8, 0x304, x1        # mie: 0x800 -> 0x800|0x80 = 0x880, x8 = old (0x800)
csrrs x9, 0x304, x0        # read back: 0x880

# mip: read-only, hardware-driven (tied to 0 until Phase D8 wires the real
# peripherals in) -- a csrrX write must be silently dropped, matching
# every other unimplemented-for-writes CSR in this core.
csrrs x10, 0x344, x0       # read: 0 (nothing pending yet)
addi x1, x0, 0x7FF
csrrw x11, 0x344, x1       # attempted write: dropped
csrrs x12, 0x344, x0       # read again: still 0

self:
jal x0, self
