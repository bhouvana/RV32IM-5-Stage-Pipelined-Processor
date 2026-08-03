# docs/adr/0025-hpc-performance-csrs.md (Phase J2). Deliberately the
# smallest possible program (nothing but the mandatory halt spin-loop) --
# this test's whole point is asserting mcycle's exact wall-clock cycle
# count at a known simulation time, hand-derived from the testbench's own
# clock/reset timing (see tb_perf_mcycle_j2.v). Any other instruction here
# would still be free (mcycle counts cycles, not instructions), but adding
# CSR writes here (as sim/programs/perf_csr_probe_j2.s does, separately)
# would risk touching mcountinhibit and invalidating the exact count.
fence
halt:
jal x0, halt
