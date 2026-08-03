# docs/adr/0025-hpc-performance-csrs.md (Phase J7). mcountinhibit gating:
# inhibit mcycle/minstret/mhpmcounter3 together (bits 0,2,3 = 0xD),
# execute a real branch (mhpmcounter3's own default event, branches
# retired -- needs genuine activity to test against, unlike mcycle/
# minstret which are always active) plus filler while inhibited, then
# re-enable (write 0) and execute another branch plus filler --
# tb_perf_countinhibit_j7.v snapshots all three counters before/after each
# phase to confirm frozen-then-resumed, not exact absolute values (robust
# against off-by-one cycle counting, unlike this phase's other directed
# tests which do need exact values).
addi x1, x0, 0xD          # bits 0(CY),2(IR),3(mhpmcounter3's own inhibit)
csrrw x0, 0x320, x1        # mcountinhibit <- 0xD (all three inhibited)
addi x2, x0, 1
beq  x0, x1, skip1          # never taken (x1=0xD != 0) -- retired but not taken
addi x2, x2, 1
skip1:
addi x2, x2, 1
addi x2, x2, 1
csrrw x0, 0x320, x0        # mcountinhibit <- 0 (all three re-enabled)
addi x3, x0, 1
beq  x0, x1, skip2          # never taken -- second real branch, now while enabled
addi x3, x3, 1
skip2:
addi x3, x3, 1
addi x3, x3, 1
fence
halt:
jal x0, halt
