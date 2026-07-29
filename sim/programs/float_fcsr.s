csrrwi x0, 0x2, 3  # frm <- RUP(3)
lui x1, 0x40200  # x1 = 2.5 bits
word 0xf00080d3  # f1 = 2.5
word 0xc000f2d3  # fcvt.w.s x5,f1,dyn -- frm=RUP -- ceil(2.5)=3
csrrwi x0, 0x2, 0  # frm <- RNE(0)
word 0xc000f353  # fcvt.w.s x6,f1,dyn -- frm=RNE -- round-to-even(2.5)=2
word 0xc000b753  # fcvt.w.s x14,f1,rup (static, not dyn) -- ceil(2.5)=3 regardless of frm
lui x2, 0  # x2 = 0.0 bits
word 0xf0010153  # f2 = 0.0
word 0x182081d3  # f3 = 2.5/0.0 -- DZ
csrrs x7, 0x1, x0  # read fflags (should show DZ=bit3 set) -- 0x08
lui x8, 0x3f000  # x8 = 0.5 bits (0x3F000000)
word 0xf0040253  # f4 = 0.5
word 0x4084d3  # f9 = 2.5+0.5 = 3.0 -- exact, NX stays 0
csrrs x10, 0x1, x0  # fflags still just DZ (sticky, unioned not replaced) -- 0x08
csrrwi x0, 0x1, 0  # clear fflags explicitly
csrrs x11, 0x1, x0  # fflags now reads back 0
addi x13, x0, 0x6d  # x13 = 0b011_01101: frm=RUP(3), fflags=0x0d
csrrw x0, 0x3, x13  # fcsr <- x13
csrrs x15, 0x2, x0  # frm alone reads back 3 (RUP)
csrrs x16, 0x1, x0  # fflags alone reads back 0x0d
csrrs x17, 0x3, x0  # fcsr packed reads back 0x6d
self:
jal x0, self
