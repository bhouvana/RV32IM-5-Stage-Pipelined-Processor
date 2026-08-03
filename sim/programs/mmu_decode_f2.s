# docs/adr/00NN-mmu-sv32.md (Phase F2, updated for F3). sfence.vma still
# has zero live effect (F5's job -- TLB flush) so its own coverage stays
# decode-only, confirmed by marker registers falling through normally.
# sret, however, now has REAL behavior as of F3 (return-from-trap: redirect
# to sepc, restore priv_mode/mstatus from SPP/SPIE) -- executed here from
# M-mode (never lowered, so not a privilege violation), it's a real, live
# instruction, not an inert one. sepc is programmed to `halt`'s own address
# first so the redirect lands somewhere deterministic and safe, rather than
# sepc's reset value of 0 (which would restart the whole program from
# address 0 -- an infinite loop, not a crash, but not a useful check
# either). x10 must stop at 3, never reaching 4 -- reaching 4 would mean
# sret incorrectly fell through instead of redirecting.
addi x10, x0, 1       # 0: marker: program started
sfence.vma x5, x6      # 4: real (nonzero) rs1/rs2 -- must still decode correctly
addi x10, x10, 1       # 8: marker: sfence.vma (nonzero-operand form) fell through
sfence.vma              # 12: rs1=rs2=x0 ("all addresses, all ASIDs") -- the common real form
addi x10, x10, 1        # 16: marker: sfence.vma (all-zero form) fell through
addi x9, x0, 36          # 20: x9 = halt's own address (36) -- see the layout below
csrrw x0, 0x141, x9       # 24: sepc <- 36 (a known, safe sret landing point)
sret                       # 28: real F3 behavior: redirect to sepc (36), priv_mode <- SPP (U, reset default)
addi x10, x10, 1            # 32: UNREACHABLE if sret correctly redirected

fence
halt:
jal x0, halt           # 36
