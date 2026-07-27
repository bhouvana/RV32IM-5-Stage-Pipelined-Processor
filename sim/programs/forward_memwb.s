# Stress MEM/WB forwarding specifically: the producer (x1) is separated from
# its consumer by exactly one unrelated filler instruction (gap=2), which
# puts the producer in MEM/WB (not EX/MEM) by the time the consumer is in EX
# -- forces Forward.v down the forwardA/B == 2'b01 path.
addi x1, x0, 1
addi x2, x0, 99    # filler; unrelated destination, occupies the forwarding gap
add  x3, x1, x1    # 1+1=2, must come from MEM/WB forwarding
nop
nop
nop
nop
nop
