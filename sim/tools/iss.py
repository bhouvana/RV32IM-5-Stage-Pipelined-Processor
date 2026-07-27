#!/usr/bin/env python3
"""
Minimal functional reference model (instruction set simulator) for this
core's exact ISA -- RV32I + RV32M plus its specific deviations from
standard RISC-V (the ble/bgt custom branches, the ctz custom op, the
documented ctz(0)=31 off-by-one). Sequential, one instruction at a time --
no pipeline, no hazards, because a sequential model has none by
construction. Used by sim/tools/random_gen.py to compute expected final
architectural state for constrained-random programs (docs/ROADMAP.md V-4),
since hand-computing expected values doesn't scale past directed tests.

This is deliberately a *second, independent* implementation of the ISA
semantics, not a reuse of design/*.v or sim/tools/asm.py's encoding tables
beyond the opcode constants -- the whole point is to catch RTL/model
disagreements, which an implementation that shares its logic with the
thing it's checking cannot do.
"""


def s32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


def u32(v):
    return v & 0xFFFFFFFF


def sext(v, bits):
    # Sign-extend a `bits`-wide field to a full-width signed value -- NOT
    # the same as s32(), which only correctly sign-extends a value that is
    # already a full 32-bit two's-complement quantity (checks bit 31).
    # Applying s32() directly to a narrower immediate field (12-bit I/S-type,
    # 13-bit B-type, 21-bit J-type) silently does nothing, since those
    # values are always < 0x80000000 before extension.
    v &= (1 << bits) - 1
    if v & (1 << (bits - 1)):
        v -= (1 << bits)
    return v


class ISS:
    def __init__(self, mem_size=128):
        self.regs = [0] * 32
        self.regs[2] = 128  # sp reset default, matches design/Register.v
        self.mem = bytearray(mem_size)
        self.pc = 0
        self.halted = False

    def wr(self, rd, val):
        if rd != 0:
            self.regs[rd] = u32(val)

    def load_mem_byte(self, addr):
        return self.mem[addr & 0x7F]

    def store_mem_byte(self, addr, val):
        self.mem[addr & 0x7F] = val & 0xFF

    def step(self, word):
        if word == 0:
            self.pc += 4
            return
        op = word & 0x7F
        rd = (word >> 7) & 0x1F
        f3 = (word >> 12) & 0x7
        rs1 = (word >> 15) & 0x1F
        rs2 = (word >> 20) & 0x1F
        f7 = (word >> 25) & 0x7F
        imm_i = sext((word >> 20) & 0xFFF, 12)
        A = self.regs[rs1]
        B = self.regs[rs2]
        next_pc = self.pc + 4

        if op == 0b0110011:  # R-type (base + RV32M)
            if f7 == 0b0000001:  # RV32M
                if f3 == 0b000:
                    res = u32(A * B)
                elif f3 == 0b001:
                    # Python's >> on a negative int is a floor shift, which is
                    # exactly two's-complement arithmetic right shift -- no
                    # masking to 64 bits needed first.
                    res = u32((s32(A) * s32(B)) >> 32)
                elif f3 == 0b010:
                    res = u32((s32(A) * u32(B)) >> 32)
                elif f3 == 0b011:
                    res = (u32(A) * u32(B)) >> 32
                elif f3 == 0b100:  # div
                    if B == 0:
                        res = 0xFFFFFFFF
                    elif s32(A) == -2147483648 and s32(B) == -1:
                        res = A
                    else:
                        q = abs(s32(A)) // abs(s32(B))
                        if (s32(A) < 0) != (s32(B) < 0):
                            q = -q
                        res = u32(q)
                elif f3 == 0b101:  # divu
                    res = 0xFFFFFFFF if B == 0 else (u32(A) // u32(B))
                elif f3 == 0b110:  # rem
                    if B == 0:
                        res = A
                    elif s32(A) == -2147483648 and s32(B) == -1:
                        res = 0
                    else:
                        r = abs(s32(A)) % abs(s32(B))
                        if s32(A) < 0:
                            r = -r
                        res = u32(r)
                else:  # remu
                    res = A if B == 0 else (u32(A) % u32(B))
                self.wr(rd, res)
            elif f7 == 0b0100000 and f3 == 0b111:  # custom ctz
                count = 0
                done = False
                for i in range(31):
                    if (A >> i) & 1 == 0 and not done:
                        count += 1
                    else:
                        done = True
                self.wr(rd, count)
            else:
                if f3 == 0 and f7 == 0:
                    res = u32(A + B)
                elif f3 == 0 and f7 == 0b0100000:
                    res = u32(A - B)
                elif f3 == 1:
                    res = u32(A << (B & 0x1F))
                elif f3 == 2:
                    res = 1 if s32(A) < s32(B) else 0
                elif f3 == 3:
                    res = 1 if u32(A) < u32(B) else 0
                elif f3 == 4:
                    res = u32(A ^ B)
                elif f3 == 5 and f7 == 0:
                    res = u32(A) >> (B & 0x1F)
                elif f3 == 5 and f7 == 0b0100000:
                    res = u32(s32(A) >> (B & 0x1F))
                elif f3 == 6:
                    res = u32(A | B)
                elif f3 == 7:
                    res = u32(A & B)
                else:
                    raise ValueError(f"unknown R-type f3={f3} f7={f7}")
                self.wr(rd, res)
            self.pc = next_pc

        elif op == 0b0101010:  # custom ctz (opcode 0101010, not 0110011 -- see design/riscv_defs.vh OPCODE_CUSTOM)
            count = 0
            done = False
            for i in range(31):
                if (A >> i) & 1 == 0 and not done:
                    count += 1
                else:
                    done = True
            self.wr(rd, count)
            self.pc = next_pc

        elif op == 0b0010011:  # I-type ALU
            if f3 in (1, 5):
                shamt = (word >> 20) & 0x1F
                if f3 == 1:
                    res = u32(A << shamt)
                elif f7 == 0b0100000:
                    res = u32(s32(A) >> shamt)
                else:
                    res = u32(A) >> shamt
            elif f3 == 0:
                res = u32(A + imm_i)
            elif f3 == 2:
                res = 1 if s32(A) < imm_i else 0
            elif f3 == 3:
                res = 1 if u32(A) < u32(imm_i) else 0
            elif f3 == 4:
                res = u32(A ^ u32(imm_i))
            elif f3 == 6:
                res = u32(A | u32(imm_i))
            elif f3 == 7:
                res = u32(A & u32(imm_i))
            else:
                raise ValueError(f"unknown I-type f3={f3}")
            self.wr(rd, res)
            self.pc = next_pc

        elif op == 0b0000011:  # loads
            addr = u32(A + imm_i)
            if f3 == 0:  # lb
                v = self.load_mem_byte(addr)
                res = u32(s32(v | (0xFFFFFF00 if v & 0x80 else 0)))
            elif f3 == 1:  # lh
                v = self.load_mem_byte(addr) | (self.load_mem_byte(addr + 1) << 8)
                res = u32(s32(v | (0xFFFF0000 if v & 0x8000 else 0)))
            elif f3 == 2:  # lw
                res = (self.load_mem_byte(addr) | (self.load_mem_byte(addr + 1) << 8) |
                       (self.load_mem_byte(addr + 2) << 16) | (self.load_mem_byte(addr + 3) << 24))
            elif f3 == 4:  # lbu
                res = self.load_mem_byte(addr)
            elif f3 == 5:  # lhu
                res = self.load_mem_byte(addr) | (self.load_mem_byte(addr + 1) << 8)
            else:
                raise ValueError(f"unknown load f3={f3}")
            self.wr(rd, res)
            self.pc = next_pc

        elif op == 0b0100011:  # stores
            imm_s = sext(((word >> 25) << 5) | ((word >> 7) & 0x1F), 12)
            addr = u32(A + imm_s)
            if f3 == 0:
                self.store_mem_byte(addr, B)
            elif f3 == 1:
                self.store_mem_byte(addr, B)
                self.store_mem_byte(addr + 1, B >> 8)
            elif f3 == 2:
                for i in range(4):
                    self.store_mem_byte(addr + i, B >> (8 * i))
            else:
                raise ValueError(f"unknown store f3={f3}")
            self.pc = next_pc

        elif op == 0b1100011:  # branches
            b12 = (word >> 31) & 1
            b11 = (word >> 7) & 1
            b10_5 = (word >> 25) & 0x3F
            b4_1 = (word >> 8) & 0xF
            off = sext((b12 << 12) | (b11 << 11) | (b10_5 << 5) | (b4_1 << 1), 13)
            taken = {
                0: s32(A) == s32(B), 1: s32(A) != s32(B),
                2: s32(A) < s32(B), 3: s32(A) >= s32(B),
                4: s32(A) <= s32(B), 5: s32(A) > s32(B),
                6: u32(A) < u32(B), 7: u32(A) >= u32(B),
            }[f3]
            self.pc = u32(self.pc + off) if taken else next_pc

        elif op == 0b1101111:  # jal
            b20 = (word >> 31) & 1
            b19_12 = (word >> 12) & 0xFF
            b11 = (word >> 20) & 1
            b10_1 = (word >> 21) & 0x3FF
            off = sext((b20 << 20) | (b19_12 << 12) | (b11 << 11) | (b10_1 << 1), 21)
            self.wr(rd, next_pc)
            self.pc = u32(self.pc + off)

        elif op == 0b1100111:  # jalr
            target = u32((A + imm_i) & ~1)
            self.wr(rd, next_pc)
            self.pc = target

        elif op == 0b0110111:  # lui
            self.wr(rd, word & 0xFFFFF000)
            self.pc = next_pc

        elif op == 0b0010111:  # auipc
            self.wr(rd, u32(self.pc + (word & 0xFFFFF000)))
            self.pc = next_pc

        else:
            raise ValueError(f"unknown opcode {op:07b}")

    def run(self, words, max_steps=20000):
        byte_len = len(words) * 4
        steps = 0
        while self.pc < byte_len and steps < max_steps:
            self.step(words[self.pc // 4])
            steps += 1
        if steps >= max_steps:
            raise RuntimeError(f"exceeded {max_steps} steps -- program likely loops forever")
        return steps
