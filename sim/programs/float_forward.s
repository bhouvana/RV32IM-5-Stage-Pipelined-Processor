lui x1, 0x40400
word 0xf00080d3  # fmv.w.x f1,x1 -- f1=3.0
word 0xf0008153  # fmv.w.x f2,x1 -- f2=3.0
word 0x2081d3  # fadd.s f3,f1,f2 -- f1:MEM/WB fwd, f2:EX/MEM fwd -- f3=6.0
word 0x10318253  # fmul.s f4,f3,f3 -- both operands EX/MEM fwd from same source -- f4=36.0
word 0x3202d3  # fadd.s f5,f4,f3 -- f4:EX/MEM fwd, f3:MEM/WB fwd -- f5=42.0
word 0xf0008353  # fmv.w.x f6,x1 -- f6=3.0
word 0x302083c3  # fmadd.s f7,f1,f2,f6 -- rs3(f6) EX/MEM fwd -- f7=12.0
word 0xf0008453  # fmv.w.x f8,x1 -- f8=3.0
addi x0, x0, 0  # spacer (unrelated int op)
word 0x402084c3  # fmadd.s f9,f1,f2,f8 -- rs3(f8) MEM/WB fwd (spacer between) -- f9=12.0
word 0x4102027  # fsw f1,64(x0) -- store 3.0's bits
word 0x4002507  # flw f10,64(x0) -- load back
word 0xa505d3  # fadd.s f11,f10,f10 -- must load-use-stall (flw's data not fwd-able yet) -- f11=6.0
addi x13, x0, 100  # x13=100 (unrelated int, shares numeric index 13 with a float reg used next)
word 0xf00086d3  # fmv.w.x f13,x1 -- f13=3.0 (must not cross-forward from integer x13)
add x6, x13, x13  # x6=200 -- integer MEM/WB fwd from instr 2-back (spacer=float instr in between), unaffected by interleaved float op
word 0xd68653  # fadd.s f12,f13,f13 -- f13 producer 2 instrs back (MEM/WB fwd), no cross-file contamination from x13 -- f12=6.0
self:
jal x0, self
