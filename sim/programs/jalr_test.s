# jalr: target = rs1+imm, link = PC+4 (distinct from jal's PC+imm target --
# this is the part that needed its own adder-input muxing, see
# design/riscvpipeline.v's target_base/target_off). x6 (not x2) is used for
# the poison registers deliberately: x2/sp has a nonzero (128) architectural
# reset default (see design/Register.v), which is easy to mistake for "never
# written" -- got bitten by exactly that once already in sim/tb/tb_jal.v.
addi x5, x0, 0
jalr x1, 16(x5)      # target = 0+16 = 16; link x1 = PC(4)+4 = 8
addi x6, x0, 999      # poison #1 (must be squashed)
addi x6, x0, 888      # poison #2 (must be squashed)
target:               # address 16
add  x3, x1, x1       # depends on jalr's link register immediately -- exercises
                       # the same EX/MEM forwarding correction jal needed (jalr
                       # also sets `jump`, so it's covered by the same fix)

fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
