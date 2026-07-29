lui x1, 0x40400  # x1 = 3.0 bits
lui x2, 0x40800  # x2 = 4.0 bits
lui x3, 0x3f800  # x3 = 1.0 bits
word 0xf00080d3  # f1 = 3.0
word 0xf0010153  # f2 = 4.0
word 0xf00181d3  # f3 = 1.0
word 0x18208543  # f10 = fmadd.s  f1*f2+f3  =  3*4+1  = 13.0
word 0x182085c7  # f11 = fmsub.s  f1*f2-f3  =  3*4-1  = 11.0
word 0x1820864b  # f12 = fnmsub.s -(f1*f2)+f3 = -12+1 = -11.0
word 0x182086cf  # f13 = fnmadd.s -(f1*f2)-f3 = -12-1 = -13.0
self:
jal x0, self
