# docs/adr/0026-performance-profiler.md (Phase K1). Exercises the 5 new
# per-cause stall events reachable under this core's own default params
# (no MMU/cache/latency setup needed): stall (load-use hazard, event 10),
# div_stall (event 11), mem_stall (event 12 -- already produced by any
# ordinary fresh load, docs/adr/0013), fp_stall (event 13), and
# float_load_use_hazard (event 14, reusing the exact flw-then-dependent-
# fadd.s shape sim/programs/float_forward.s already established). Reprograms
# mhpmevent3-7 to select these 5 new events before exercising each.
csrrwi x0, 0x323, 10   # mhpmevent3 = event 10 (stall_hazard_pulse)
csrrwi x0, 0x324, 11   # mhpmevent4 = event 11 (stall_div_pulse)
csrrwi x0, 0x325, 12   # mhpmevent5 = event 12 (stall_mem_pulse)
csrrwi x0, 0x326, 13   # mhpmevent6 = event 13 (stall_fp_pulse)
csrrwi x0, 0x327, 14   # mhpmevent7 = event 14 (stall_float_lu_pulse)

addi x1, x0, 5
sw   x1, 0(x0)
lw   x2, 0(x0)
add  x3, x2, x2        # load-use hazard on x2 -> stall_hazard_pulse + mem_stall (the lw itself)

addi x4, x0, 20
addi x5, x0, 3
div  x6, x4, x5        # div_stall

lui  x10, 0x40400
fmv.w.x f1, x10        # f1 = 3.0
fmv.w.x f2, x10        # f2 = 3.0
fdiv.s f3, f1, f2      # fp_stall

fsw  f1, 64(x0)
flw  f4, 64(x0)
fadd.s f5, f4, f4      # float_load_use_hazard (flw's data not fwd-able yet)

fence
halt:
jal x0, halt
