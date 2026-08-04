# docs/adr/0020-soc-integration.md (Phase D9). Directed test: an interrupt
# must NOT be taken while mstatus.MIE=0 during synchronous-exception
# handling, even once the interrupt source becomes pending and enabled
# mid-handler -- only recognized once the handler's own mret restores
# MIE=1. The mainline arms the timer source but defuses its reset-time
# 'pending immediately' quirk (Timer.v resets with mtime=0>=mtimecmp=0,
# tb_timer_unit.v's own documented behavior) first, then takes an ecall
# trap. Inside the (single, shared) handler, mcause's sign bit tells apart
# a fresh ecall entry from the eventual deferred timer entry. The
# testbench event-waits for the handler's own MTIMECMP=3 re-arm to take
# effect (a 0->1 transition on Timer.v's `pending`, not just its level --
# the reset-time quirk would otherwise make a plain level-wait return
# immediately at t=0) and samples mcause/mstatus at exactly that point,
# still inside the ecall path -- both must be unchanged (11, MIE=0),
# proving the interrupt was correctly deferred, not silently swallowed.
addi  x5, x0, 44  # 0: x5 = handler address (44)
csrrw x0, mtvec, x5  # 4
lui   x2, 0x10104  # 8: x2 = TIMER_BASE + CLINT_OFF_MTIMECMP = 0x1010_4000 (MTIMECMP low, Phase R)
lui   x21, 0xFFFFF  # 12: x21 = 0xFFFFF000 (huge)
sw    x21, 0(x2)  # 16: TIMER.MTIMECMP(low) <- huge -- defuses Timer.v's reset-time 'pending immediately' quirk (mtime=0>=mtimecmp=0) before anything is armed
addi  x6, x0, 128  # 20: 0x80 = MIE_MTIE_BIT
csrrw x0, mie, x6  # 24: mie.MTIE <- 1 (armed, not yet pending)
csrrsi x0, mstatus, 8  # 28: mstatus.MIE <- 1
ecall  # 32: traps to the handler: mepc<-this PC, mcause<-11, MPIE<-1, MIE<-0
addi  x15, x0, 42  # 36: mainline marker -- only reached after the handler's own real mret
self:
jal   x0, self  # 40: mainline spin -- the deferred timer interrupt should catch this loop
handler:
addi  x11, x0, 111  # 44: proves the handler ran (either entry)
csrrs x17, mcause, x0  # 48: x17 <- mcause (11=ecall, or 0x80000007 once the timer interrupt is finally taken)
addi  x7, x0, 3  # 52: MTIMECMP target -- tiny; mtime is already well past 3 by now, so this immediately re-arms `pending`
sw    x7, 0(x2)  # 56: TIMER.MTIMECMP(low) <- 3 -- mip.MTIP becomes (or stays) pending; harmless to redo on a timer-caused entry too
blt   x17, x0, is_int  # 60: mcause<0 (bit31/interrupt bit set) -> this is the deferred timer entry, not the original ecall
addi  x18, x18, 1  # 64: spacer -- while MIE=0 in here, mip.MTIP is already pending+enabled (armed above); the testbench mid-run-samples mcause/mstatus during exactly this window and expects them UNCHANGED
addi  x18, x18, 1  # 68: spacer
csrrs x19, mepc, x0  # 72: x19 <- mepc (the ecall's own PC)
addi  x19, x19, 4  # 76: x19 <- skip past the ecall on return (standard ecall convention, tb_mret_return.v)
csrrw x0, mepc, x19  # 80
mret  # 84: MIE<-MPIE(1), pc<-mepc -- resumes mainline with the timer already pending+armed
is_int:
lui   x20, 0xFFFFF  # 88: x20 = 0xFFFFF000 (huge)
sw    x20, 0(x2)  # 92: TIMER.MTIMECMP(low) <- huge -- defuse for good, this source must not keep re-firing
mret  # 96: MIE<-MPIE, pc<-mepc (the interrupt's own -- the squashed mainline instruction, NOT +4 adjusted)
