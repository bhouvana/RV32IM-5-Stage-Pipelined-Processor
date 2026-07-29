lui x1, 0x40400
lui x2, 0x40800
lui x10, 0x3f800
word 0xf00080d3  # fmv.w.x f1,x1
word 0xf0010153  # fmv.w.x f2,x2
word 0xf00503d3  # fmv.w.x f7,x10
word 0x2081d3  # fadd.s f3,f1,f2
word 0x10208253  # fmul.s f4,f1,f2
word 0x182082d3  # fdiv.s f5,f1,f2
word 0x58010353  # fsqrt.s f6,f2
word 0x38208443  # fmadd.s f8,f1,f2,f7
word 0xe00185d3  # fmv.x.w x11,f3
word 0xe0020653  # fmv.x.w x12,f4
word 0xe00286d3  # fmv.x.w x13,f5
word 0xe0030753  # fmv.x.w x14,f6
word 0xe00407d3  # fmv.x.w x15,f8
word 0xc0008853  # fcvt.w.s x16,f1
word 0xa010a8d3  # feq.s x17,f1,f1
word 0xa0209953  # flt.s x18,f1,f2
word 0xa01109d3  # fle.s x19,f2,f1
word 0x4302027  # fsw f3,64(x0)
word 0x4002487  # flw f9,64(x0)
word 0xe0048a53  # fmv.x.w x20,f9
self:
jal x0, self
