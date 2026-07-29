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


CSR_MSTATUS, CSR_MTVEC, CSR_MSCRATCH, CSR_MEPC, CSR_MCAUSE = 0x300, 0x305, 0x340, 0x341, 0x342
MCAUSE_ILLEGAL_INSTRUCTION, MCAUSE_BREAKPOINT, MCAUSE_ECALL_FROM_M = 2, 3, 11

# docs/adr/0020-soc-integration.md (Phase D10). Matches design/riscv_defs.vh's
# MCAUSE_INT_MACHINE_TIMER/MCAUSE_INT_MACHINE_EXTERNAL (7/11) with bit31 (the
# interrupt-vs-exception bit) set -- the two interrupt causes an externally
# scheduled trap() call below can raise.
MCAUSE_INT_MACHINE_TIMER = 0x80000007
MCAUSE_INT_MACHINE_EXTERNAL = 0x8000000B


# ==========================================================================
# docs/adr/0019-f-extension.md (Phase C9): RV32F reference model. Independent
# of design/*.v's own logic by construction (same reason the integer ISS
# above is independent of design/*.v/asm.py): every arithmetic op here is
# computed with exact rational arithmetic (fractions.Fraction) and rounded
# once, at the very end, rather than mirroring the RTL's internal bit-level
# mechanics (guard/round/sticky bits, alignment shifts, digit-recurrence
# division/sqrt) -- an independent *result*, not an independent copy of the
# same algorithm. This is the same "exact Fraction arithmetic, then round"
# approach the standalone Python reference models used to verify
# FALU.v/FDivider.v/FSqrt.v/FMADDUnit.v during C3-C5, reused here as the
# live oracle for random cross-checks instead of a one-off verification
# script.
#
# Mirrors this core's two documented IEEE 754 deviations exactly (not
# textbook-correct float32, which would produce spurious mismatches against
# a bug-free RTL): no NaN-boxing (moot -- F-only, FLEN==XLEN==32), and
# subnormals flushed to zero on both input and output (docs/adr/0019's
# Design section). Validated against numpy.float32 (3000/3000 matched for
# fadd/fsub/fmul/fdiv/fsqrt each, RNE) and against every existing directed
# float testbench's hand-computed expected values before being wired in
# below as the live ISS.step() dispatch.
# ==========================================================================
import math
from fractions import Fraction

RM_RNE, RM_RTZ, RM_RDN, RM_RUP, RM_RMM, RM_DYN = 0, 1, 2, 3, 4, 7

CSR_FFLAGS, CSR_FRM, CSR_FCSR = 0x001, 0x002, 0x003

CANONICAL_NAN = 0x7FC00000

# {NV, DZ, OF, UF, NX} bit positions, matching design/fp_round.vh exactly.
F_NV, F_DZ, F_OF, F_UF, F_NX = 0b10000, 0b01000, 0b00100, 0b00010, 0b00001


def f32_decode(bits):
    """bits -> (sign, is_zero, is_inf, is_nan, is_snan, magnitude:Fraction|None).
    Subnormal-encoded inputs (exp==0, mant!=0) flush to signed zero on input
    (design/FALU.v's documented simplification) -- magnitude is None for
    inf/nan, a Fraction (possibly 0) otherwise."""
    bits &= 0xFFFFFFFF
    sign = (bits >> 31) & 1
    exp = (bits >> 23) & 0xFF
    mant = bits & 0x7FFFFF
    if exp == 0xFF:
        if mant == 0:
            return sign, False, True, False, False, None
        is_snan = ((mant >> 22) & 1) == 0
        return sign, False, False, True, is_snan, None
    if exp == 0:
        return sign, True, False, False, False, Fraction(0)
    magnitude = Fraction((1 << 23) | mant, 1 << 23) * (Fraction(2) ** (exp - 127))
    return sign, False, False, False, False, magnitude


def f32_is_zero_arith(bits):
    # True for a real zero AND a (flushed) subnormal -- matches FALU.v's
    # is_zero_arith_f exactly (checks only the exponent field).
    return ((bits >> 23) & 0xFF) == 0


def f32_pack_zero(sign):
    return (sign & 1) << 31


def f32_pack_inf(sign):
    return ((sign & 1) << 31) | (0xFF << 23)


def _f32_round_up_decision(cls, sig_floor, sign, rm):
    # cls: 'exact' | 'below' | 'tie' | 'above' -- classification of the
    # exact fractional remainder against 1/2. Mirrors design/fp_round.vh's
    # round_and_pack case statement bit-for-bit, including its defensive
    # RNE fallback for an unrecognized rm.
    if cls == "exact":
        return False, False
    if rm == RM_RTZ:
        return False, True
    if rm == RM_RDN:
        return (sign == 1), True
    if rm == RM_RUP:
        return (sign == 0), True
    if rm == RM_RMM:
        return (cls != "below"), True
    # RM_RNE, and the defensive fallback for anything else
    if cls == "above":
        return True, True
    if cls == "below":
        return False, True
    return bool(sig_floor & 1), True  # exact tie -> round to even


def _f32_pack_rounded(sign, e, sig_floor, cls, rm):
    """sig_floor: 24-bit int (2^23 <= sig_floor < 2^24) already normalized
    against unbiased exponent e. Returns (bits, flags) with only OF/UF/NX
    ever set (NV/DZ are the caller's concern, per every RTL module's own
    `flags` convention)."""
    round_up, inexact = _f32_round_up_decision(cls, sig_floor, sign, rm)
    if round_up:
        sig_floor += 1
        if sig_floor == (1 << 24):
            sig_floor >>= 1
            e += 1

    if e > 127:
        # Overflow does NOT always mean infinity -- RTZ always truncates to
        # the largest finite value, and RDN/RUP only overflow to infinity in
        # the direction they round toward (docs/fp_round.vh's own comment).
        if rm == RM_RTZ or (rm == RM_RDN and sign == 0) or (rm == RM_RUP and sign == 1):
            bits = (sign << 31) | (0xFE << 23) | 0x7FFFFF
        else:
            bits = (sign << 31) | (0xFF << 23)
        return bits, F_OF | F_NX
    if e < -126:
        return f32_pack_zero(sign), F_UF | F_NX
    exp_biased = e + 127
    bits = (sign << 31) | (exp_biased << 23) | (sig_floor & 0x7FFFFF)
    return bits, (F_NX if inexact else 0)


def _f32_normalize_fraction(magnitude):
    """Positive exact Fraction -> (e, sig_floor, remainder_cls) with
    2^23 <= sig_floor < 2^24 and magnitude == (sig_floor + r) * 2^(e-23)."""
    two = Fraction(2)
    e = magnitude.numerator.bit_length() - magnitude.denominator.bit_length() - 1
    while magnitude >= two ** (e + 1):
        e += 1
    while magnitude < two ** e:
        e -= 1
    sig_exact = magnitude * (two ** (23 - e))
    sig_floor = sig_exact.numerator // sig_exact.denominator
    remainder = sig_exact - sig_floor
    half = Fraction(1, 2)
    if remainder == 0:
        cls = "exact"
    elif remainder < half:
        cls = "below"
    elif remainder > half:
        cls = "above"
    else:
        cls = "tie"
    return e, sig_floor, cls


def _f32_sqrt_normalize(magnitude):
    """Positive exact (dyadic) Fraction -> (e, sig_floor, cls) for
    sqrt(magnitude), via exact integer sqrt (math.isqrt) -- no irrational
    approximation, no precision loss."""
    two = Fraction(2)
    e = (magnitude.numerator.bit_length() - magnitude.denominator.bit_length()) // 2 - 1
    while magnitude >= two ** (2 * (e + 1)):
        e += 1
    while magnitude < two ** (2 * e):
        e -= 1
    scaled = magnitude * (two ** (2 * (23 - e)))
    assert scaled.denominator == 1, "fsqrt input expected dyadic (a single decoded float32)"
    n = scaled.numerator
    sig_floor = math.isqrt(n)
    if sig_floor * sig_floor == n:
        cls = "exact"
    else:
        mid_sq = (2 * sig_floor + 1) ** 2
        four_n = 4 * n
        cls = "below" if four_n < mid_sq else ("above" if four_n > mid_sq else "tie")
    return e, sig_floor, cls


def f32_round_from_fraction(sign, magnitude, rm):
    """Shared entry point for add/sub/mul/div/fma: magnitude is the exact
    nonnegative Fraction result (0 handled by the caller before this)."""
    e, sig_floor, cls = _f32_normalize_fraction(magnitude)
    return _f32_pack_rounded(sign, e, sig_floor, cls, rm)


def f32_round_from_sqrt(sign, magnitude, rm):
    e, sig_floor, cls = _f32_sqrt_normalize(magnitude)
    return _f32_pack_rounded(sign, e, sig_floor, cls, rm)


# ---- per-op semantics -- special-case dispatch order/results mirror
# design/FALU.v / FDivider.v / FSqrt.v / FMADDUnit.v exactly (they are the
# spec this model is checked against, not textbook IEEE 754 in the
# abstract -- e.g. the documented subnormal-flush-to-zero deviation). ----

def f_add(a_bits, b_bits, rm, is_sub):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    sb, zb, ib, nb, snb, mb = f32_decode(b_bits)
    eff_sb = sb ^ (1 if is_sub else 0)
    if na or nb:
        return CANONICAL_NAN, (F_NV if (sna or snb) else 0)
    if ia and ib and (sa != eff_sb):
        return CANONICAL_NAN, F_NV
    if ia:
        return f32_pack_inf(sa), 0
    if ib:
        return f32_pack_inf(eff_sb), 0
    if za and zb:
        if sa == eff_sb:
            return f32_pack_zero(sa), 0
        return f32_pack_zero(1 if rm == RM_RDN else 0), 0
    if za:
        return (eff_sb << 31) | (b_bits & 0x7FFFFFFF), 0
    if zb:
        return a_bits, 0
    va = ma if sa == 0 else -ma
    vb = mb if eff_sb == 0 else -mb
    total = va + vb
    if total == 0:
        return f32_pack_zero(1 if rm == RM_RDN else 0), 0
    sign = 1 if total < 0 else 0
    return f32_round_from_fraction(sign, abs(total), rm)


def f_mul(a_bits, b_bits, rm):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    sb, zb, ib, nb, snb, mb = f32_decode(b_bits)
    if na or nb:
        return CANONICAL_NAN, (F_NV if (sna or snb) else 0)
    if (ia and zb) or (za and ib):
        return CANONICAL_NAN, F_NV
    if ia or ib:
        return f32_pack_inf(sa ^ sb), 0
    if za or zb:
        return f32_pack_zero(sa ^ sb), 0
    return f32_round_from_fraction(sa ^ sb, ma * mb, rm)


def f_div(a_bits, b_bits, rm):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    sb, zb, ib, nb, snb, mb = f32_decode(b_bits)
    if na or nb:
        return CANONICAL_NAN, (F_NV if (sna or snb) else 0)
    if ia and ib:
        return CANONICAL_NAN, F_NV
    if za and zb:
        return CANONICAL_NAN, F_NV
    if ia:
        return f32_pack_inf(sa ^ sb), 0
    if ib:
        return f32_pack_zero(sa ^ sb), 0
    if zb:
        return f32_pack_inf(sa ^ sb), F_DZ
    if za:
        return f32_pack_zero(sa ^ sb), 0
    return f32_round_from_fraction(sa ^ sb, ma / mb, rm)


def f_sqrt(a_bits, rm):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    if na:
        return CANONICAL_NAN, (F_NV if sna else 0)
    if za:
        return a_bits, 0  # sqrt(+/-0) = +/-0, a defined special case
    if sa:
        return CANONICAL_NAN, F_NV  # sqrt of any negative, nonzero, finite (or -inf) value
    if ia:
        return a_bits, 0  # sqrt(+inf) = +inf
    return f32_round_from_sqrt(0, ma, rm)


def f_madd(a_bits, b_bits, c_bits, rm, neg_prod, neg_addend):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    sb, zb, ib, nb, snb, mb = f32_decode(b_bits)
    sc, zc, ic, nc, snc, mc = f32_decode(c_bits)
    if na or nb or nc:
        return CANONICAL_NAN, (F_NV if (sna or snb or snc) else 0)
    if (ia and zb) or (za and ib):
        return CANONICAL_NAN, F_NV
    prod_sign = sa ^ sb ^ (1 if neg_prod else 0)
    prod_inf = ia or ib
    eff_sc = sc ^ (1 if neg_addend else 0)
    if prod_inf and ic and (prod_sign != eff_sc):
        return CANONICAL_NAN, F_NV
    if prod_inf:
        return f32_pack_inf(prod_sign), 0
    if ic:
        return f32_pack_inf(eff_sc), 0
    if za or zb:
        # product is exactly zero (and finite)
        if zc:
            if prod_sign == eff_sc:
                return f32_pack_zero(prod_sign), 0
            return f32_pack_zero(1 if rm == RM_RDN else 0), 0
        return (eff_sc << 31) | (c_bits & 0x7FFFFFFF), 0
    # General finite case: exact product +/- exact addend, rounded once.
    prod_val = ma * mb  # exact, nonnegative
    prod_signed = prod_val if prod_sign == 0 else -prod_val
    addend_signed = mc if eff_sc == 0 else -mc
    total = prod_signed + addend_signed
    if total == 0:
        return f32_pack_zero(1 if rm == RM_RDN else 0), 0
    sign = 1 if total < 0 else 0
    return f32_round_from_fraction(sign, abs(total), rm)


def f_sgnj(a_bits, b_bits, funct3):
    sa = (a_bits >> 31) & 1
    sb = (b_bits >> 31) & 1
    if funct3 == 0b000:
        sign = sb
    elif funct3 == 0b001:
        sign = sb ^ 1
    else:
        sign = sa ^ sb
    return (sign << 31) | (a_bits & 0x7FFFFFFF), 0


def f_minmax(a_bits, b_bits, funct3):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    sb, zb, ib, nb, snb, mb = f32_decode(b_bits)
    if na and nb:
        return CANONICAL_NAN, (F_NV if (sna or snb) else 0)
    if na:
        return b_bits, (F_NV if sna else 0)
    if nb:
        return a_bits, (F_NV if snb else 0)
    a_ez, b_ez = f32_is_zero_arith(a_bits), f32_is_zero_arith(b_bits)
    a_nz = a_ez and ((a_bits >> 31) & 1)
    b_nz = b_ez and ((b_bits >> 31) & 1)
    if a_ez and b_ez:
        a_lt_b = a_nz and not b_nz
    elif sa != sb:
        a_lt_b = bool(sa)
    elif sa:
        a_lt_b = (a_bits & 0x7FFFFFFF) > (b_bits & 0x7FFFFFFF)
    else:
        a_lt_b = (a_bits & 0x7FFFFFFF) < (b_bits & 0x7FFFFFFF)
    is_min = (funct3 == 0b000)
    if is_min:
        return (a_bits if a_lt_b else b_bits), 0
    return (b_bits if a_lt_b else a_bits), 0


def f_cmp(a_bits, b_bits, funct3):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    sb, zb, ib, nb, snb, mb = f32_decode(b_bits)
    if na or nb:
        if funct3 == 0b010:  # feq.s: only sNaN raises NV
            flags = F_NV if (sna or snb) else 0
        else:  # flt.s/fle.s: any NaN raises NV
            flags = F_NV
        return 0, flags
    a_ez, b_ez = f32_is_zero_arith(a_bits), f32_is_zero_arith(b_bits)
    both_zero = a_ez and b_ez
    eq = True if both_zero else (a_bits == b_bits)
    if both_zero:
        lt = False
    elif sa != sb:
        lt = bool(sa)
    elif sa:
        lt = (a_bits & 0x7FFFFFFF) > (b_bits & 0x7FFFFFFF)
    else:
        lt = (a_bits & 0x7FFFFFFF) < (b_bits & 0x7FFFFFFF)
    if funct3 == 0b010:
        res = 1 if eq else 0
    elif funct3 == 0b001:
        res = 1 if lt else 0
    else:
        res = 1 if (lt or eq) else 0
    return res, 0


def f_class(a_bits):
    sa = (a_bits >> 31) & 1
    exp = (a_bits >> 23) & 0xFF
    frac = a_bits & 0x7FFFFF
    if exp == 0xFF and frac == 0 and sa:
        return 1 << 0
    if exp not in (0, 0xFF) and sa:
        return 1 << 1
    if exp == 0 and frac != 0 and sa:
        return 1 << 2
    if exp == 0 and frac == 0 and sa:
        return 1 << 3
    if exp == 0 and frac == 0 and not sa:
        return 1 << 4
    if exp == 0 and frac != 0 and not sa:
        return 1 << 5
    if exp not in (0, 0xFF) and not sa:
        return 1 << 6
    if exp == 0xFF and frac == 0 and not sa:
        return 1 << 7
    if exp == 0xFF and frac != 0 and not (frac >> 22 & 1):
        return 1 << 8
    return 1 << 9


def f_cvt_to_int(a_bits, rm, unsigned):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    if na:
        return (0xFFFFFFFF if unsigned else 0x7FFFFFFF), F_NV
    if za:
        return 0, 0
    if ia:
        res = (0 if sa else 0xFFFFFFFF) if unsigned else (0x80000000 if sa else 0x7FFFFFFF)
        return res, F_NV
    # Round the exact magnitude directly to the nearest *integer* -- this is
    # integer-target rounding (absolute precision at bit 0), a different
    # target precision than f32_round_from_fraction's float32-significand
    # rounding (relative precision at 23 fraction bits), so it must use its
    # own floor/remainder classification against magnitude itself, not go
    # through _f32_normalize_fraction. Python's arbitrary-precision ints make
    # the RTL's own "is_inf(a) || exp_u > 31" pre-check unnecessary here --
    # an astronomically large exact magnitude just produces an
    # astronomically large Python int, still caught correctly by the same
    # out-of-range bounds check used for every other case.
    floor_mag = ma.numerator // ma.denominator
    remainder = ma - floor_mag
    half = Fraction(1, 2)
    if remainder == 0:
        cls = "exact"
    elif remainder < half:
        cls = "below"
    elif remainder > half:
        cls = "above"
    else:
        cls = "tie"
    round_up, inexact = _f32_round_up_decision(cls, floor_mag, sa, rm)
    magnitude = floor_mag + (1 if round_up else 0)
    if unsigned:
        out_of_range = (sa and magnitude != 0) or magnitude > 0xFFFFFFFF
    else:
        out_of_range = (not sa and magnitude > 0x7FFFFFFF) or (sa and magnitude > 0x80000000)
    if out_of_range:
        res = (0 if sa else 0xFFFFFFFF) if unsigned else (0x80000000 if sa else 0x7FFFFFFF)
        return res, F_NV
    res = (magnitude & 0xFFFFFFFF) if not sa else ((-magnitude) & 0xFFFFFFFF)
    return res, (F_NX if inexact else 0)


def f_cvt_from_int(a_bits, rm, unsigned):
    if a_bits == 0:
        return 0, 0
    if unsigned:
        sign = 0
        magnitude = a_bits & 0xFFFFFFFF
    else:
        sign = (a_bits >> 31) & 1
        magnitude = ((~a_bits + 1) & 0xFFFFFFFF) if sign else a_bits
    return f32_round_from_fraction(sign, Fraction(magnitude), rm)


class ISS:
    def __init__(self, mem_size=128):
        self.regs = [0] * 32
        # sp reset default -- matches design/Register.v's SP_INIT parameter,
        # which riscvpipeline.v ties directly to MEM_SIZE_BYTES, not a fixed
        # 128 (docs/adr/0020-soc-integration.md Phase D10 caught this: the
        # non-interrupt corpus never varies mem_size away from 128, so this
        # was silently correct by coincidence until interrupt-mode runs
        # actually changed it).
        self.regs[2] = mem_size
        self.mem = bytearray(mem_size)
        self.mem_mask = mem_size - 1  # mem_size is always a power of 2 (128, 256, ...)
        self.pc = 0
        self.halted = False
        # CSR state (docs/adr/0011-csr-and-exceptions.md) -- only the 5
        # machine-mode CSRs design/CSR.v implements. mstatus models just the
        # MIE (bit3) / MPIE (bit7) trap-enable stack, matching that module.
        self.csr = {CSR_MSTATUS: 0, CSR_MTVEC: 0, CSR_MSCRATCH: 0, CSR_MEPC: 0, CSR_MCAUSE: 0}
        # docs/adr/0019-f-extension.md (Phase C9). fregs has no x0-equivalent
        # (FRegister.v hardwires nothing). frm/fflags mirror CSR.v's own
        # separate registers, not folded into self.csr, since fflags needs
        # sticky-OR semantics distinct from every other CSR's plain
        # read/write (see set_fflags below).
        self.fregs = [0] * 32
        self.frm = 0
        self.fflags = 0
        # docs/adr/0020-soc-integration.md (Phase D10). Externally scheduled
        # interrupt injection, set via schedule_interrupt() below -- None
        # (default) means no interrupt-mode testing is active, run() behaves
        # exactly as it always has. This is deliberately NOT a real timing
        # model (the ISS has no notion of cycles): the RTL side independently
        # arms real hardware (a genuinely reachable MTIMECMP, or the test
        # rig's own driven UART byte) that will, with a generous timing
        # margin, actually fire somewhere during the same window this fires
        # in on the ISS side. The two sides deliberately do NOT need to agree
        # on the *exact* instruction boundary -- see random_gen.py's
        # interrupt-mode docstring for why a minimal, architecturally-inert
        # handler (mie<-0 then mret, no register/memory footprint at all)
        # makes the final compared state independent of exactly which
        # instruction got interrupted, as long as it fires (at most) once.
        self.pending_interrupt = None

    def schedule_interrupt(self, after_steps, cause):
        self.pending_interrupt = {"after": after_steps, "cause": cause}

    def wr(self, rd, val):
        if rd != 0:
            self.regs[rd] = u32(val)

    def set_fflags(self, flags):
        # docs/adr/0019 Phase C8/C9: sticky hardware accumulation -- every
        # F-extension instruction that executes ORs its own flags in,
        # matching design/CSR.v's fp_flags_we path exactly.
        self.fflags = (self.fflags | flags) & 0x1F

    def resolve_rm(self, rm_field):
        return self.frm if rm_field == RM_DYN else rm_field

    def csr_read(self, addr):
        if addr == CSR_FFLAGS:
            return self.fflags & 0x1F
        if addr == CSR_FRM:
            return self.frm & 0x7
        if addr == CSR_FCSR:
            return ((self.frm & 0x7) << 5) | (self.fflags & 0x1F)
        return self.csr.get(addr, 0)

    def csr_write(self, addr, val):
        if addr == CSR_FFLAGS:
            self.fflags = val & 0x1F
            return
        if addr == CSR_FRM:
            self.frm = val & 0x7
            return
        if addr == CSR_FCSR:
            self.frm = (val >> 5) & 0x7
            self.fflags = val & 0x1F
            return
        if addr == CSR_MSTATUS:  # only bits 3 (MIE) and 7 (MPIE) are real, see design/CSR.v
            val &= (1 << 3) | (1 << 7)
        if addr in self.csr:
            self.csr[addr] = u32(val)

    def trap(self, cause):
        # Matches design/CSR.v's trap_taken path exactly: mepc <- the
        # trapping instruction's own PC (not next_pc), mcause <- cause,
        # mstatus.MPIE <- mstatus.MIE, mstatus.MIE <- 0, pc <- mtvec.
        mie = (self.csr[CSR_MSTATUS] >> 3) & 1
        self.csr[CSR_MSTATUS] = (mie << 7)
        self.csr[CSR_MEPC] = self.pc
        self.csr[CSR_MCAUSE] = u32(cause)
        self.pc = self.csr[CSR_MTVEC]

    def mret(self):
        # Matches design/CSR.v's mret_taken path: mstatus.MIE <- mstatus.MPIE,
        # mstatus.MPIE <- 1, pc <- mepc.
        mpie = (self.csr[CSR_MSTATUS] >> 7) & 1
        self.csr[CSR_MSTATUS] = (mpie << 3) | (1 << 7)
        self.pc = self.csr[CSR_MEPC]

    def load_mem_byte(self, addr):
        # docs/adr/0020-soc-integration.md (Phase D10). MMIO_BASE (design/
        # riscv_defs.vh, 0x1000_0000) and above is real peripheral address
        # space on the RTL side (WbDecoder routes it away from RAM
        # entirely) -- this ISS has no peripheral model at all (interrupt
        # firing is scheduled externally, not derived from simulated
        # peripheral state, see schedule_interrupt), so an MMIO address must
        # NOT alias into self.mem via the mask below the way an ordinary
        # RAM address does, or a real MMIO store/load would corrupt (or a
        # load would silently fabricate) unrelated compared memory state.
        # Reads at an unmodeled address are simply 0, the same convention
        # csr_read already uses for an unimplemented CSR.
        if addr >= 0x10000000:
            return 0
        return self.mem[addr & self.mem_mask]

    def store_mem_byte(self, addr, val):
        if addr >= 0x10000000:
            return
        self.mem[addr & self.mem_mask] = val & 0xFF

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

        elif op == 0b1110011:  # SYSTEM: csrrw/rs/rc(+i), ecall, ebreak, mret
            csr_addr = (word >> 20) & 0xFFF
            if f3 == 0b000:
                if csr_addr == 0x000:
                    self.trap(MCAUSE_ECALL_FROM_M)
                elif csr_addr == 0x001:
                    self.trap(MCAUSE_BREAKPOINT)
                elif csr_addr == 0x302:
                    self.mret()
                else:
                    self.trap(MCAUSE_ILLEGAL_INSTRUCTION)  # SYSTEM/f3=0, not ecall/ebreak/mret
            else:
                # rs1's raw 5-bit field doubles as the zero-extended uimm for
                # the *i variants -- matches design/riscvpipeline.v's
                # csr_wdata = funct3[2] ? {27'b0, inst[19:15]} : readData1.
                old = self.csr_read(csr_addr)
                src = rs1 if (f3 & 0b100) else A
                csr_op = f3 & 0b011  # 01=write, 10=set, 11=clear -- matches design/CSR.v
                if csr_op == 0b01:
                    new_val = src
                elif csr_op == 0b10:
                    new_val = old | src
                else:
                    new_val = old & ~src
                self.csr_write(csr_addr, new_val)
                self.wr(rd, old)
                self.pc = next_pc

        # docs/adr/0019-f-extension.md (Phase C9): RV32F dispatch.
        elif op == 0b0000111:  # flw
            addr = u32(A + imm_i)
            v = (self.load_mem_byte(addr) | (self.load_mem_byte(addr + 1) << 8) |
                 (self.load_mem_byte(addr + 2) << 16) | (self.load_mem_byte(addr + 3) << 24))
            self.fregs[rd] = v
            self.pc = next_pc

        elif op == 0b0100111:  # fsw
            imm_s = sext(((word >> 25) << 5) | ((word >> 7) & 0x1F), 12)
            addr = u32(A + imm_s)
            v = self.fregs[rs2]
            for i in range(4):
                self.store_mem_byte(addr + i, v >> (8 * i))
            self.pc = next_pc

        elif op == 0b1010011:  # OP-FP
            funct5 = (word >> 27) & 0x1F
            rm = self.resolve_rm(f3)
            fa, fb = self.fregs[rs1], self.fregs[rs2]
            if funct5 == 0b00000:  # fadd.s
                res, flags = f_add(fa, fb, rm, is_sub=False)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b00001:  # fsub.s
                res, flags = f_add(fa, fb, rm, is_sub=True)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b00010:  # fmul.s
                res, flags = f_mul(fa, fb, rm)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b00011:  # fdiv.s
                res, flags = f_div(fa, fb, rm)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b01011:  # fsqrt.s
                res, flags = f_sqrt(fa, rm)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b00100:  # fsgnj.s/fsgnjn.s/fsgnjx.s
                res, _ = f_sgnj(fa, fb, f3)
                self.fregs[rd] = res
            elif funct5 == 0b00101:  # fmin.s/fmax.s
                res, flags = f_minmax(fa, fb, f3)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b10100:  # fle.s/flt.s/feq.s -- writes the INTEGER file
                res, flags = f_cmp(fa, fb, f3)
                self.wr(rd, res)
                self.set_fflags(flags)
            elif funct5 == 0b11000:  # fcvt.w.s/fcvt.wu.s -- writes the INTEGER file
                unsigned = (rs2 == 0b00001)
                res, flags = f_cvt_to_int(fa, rm, unsigned)
                self.wr(rd, res)
                self.set_fflags(flags)
            elif funct5 == 0b11010:  # fcvt.s.w/fcvt.s.wu -- reads the INTEGER file
                unsigned = (rs2 == 0b00001)
                res, flags = f_cvt_from_int(A, rm, unsigned)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b11100:  # fmv.x.w/fclass.s -- both write the INTEGER file
                if f3 == 0b001:
                    self.wr(rd, f_class(fa))
                else:
                    self.wr(rd, fa)
            elif funct5 == 0b11110:  # fmv.w.x -- reads the INTEGER file
                self.fregs[rd] = A
            else:
                raise ValueError(f"unknown OP-FP funct5={funct5:#07b}")
            self.pc = next_pc

        elif op in (0b1000011, 0b1000111, 0b1001011, 0b1001111):  # fmadd.s/fmsub.s/fnmsub.s/fnmadd.s
            rs3 = (word >> 27) & 0x1F
            rm = self.resolve_rm(f3)
            # docs/adr/0019 (Phase C9 bugfix): opcode[3:2], not [4:3] -- see
            # design/riscvpipeline.v's own Phase C9 bugfix comment.
            op2 = (op >> 2) & 0b11
            neg_prod = bool(op2 & 0b10)
            neg_addend = bool(op2 & 0b01)
            res, flags = f_madd(self.fregs[rs1], self.fregs[rs2], self.fregs[rs3], rm, neg_prod, neg_addend)
            self.fregs[rd] = res
            self.set_fflags(flags)
            self.pc = next_pc

        else:
            # Matches design/Control.v's outer default case (docs/adr/0011):
            # any opcode this core doesn't implement traps as an illegal
            # instruction rather than being a simulator-level error.
            self.trap(MCAUSE_ILLEGAL_INSTRUCTION)

    def run(self, words, max_steps=20000):
        # Every generated/hand-written test program (docs/adr/0011) now ends
        # in a deliberate `jal x0, <self>` rather than running off the end
        # into instruction memory's zero-filled remainder (opcode 0000000 is
        # not a valid instruction and correctly traps as of that ADR) --
        # detect that specific self-loop and stop cleanly there instead of
        # spinning for the full step budget. Reaching max_steps *without*
        # hitting a self-loop is still treated as a genuine runaway: nothing
        # else should be able to loop, since sim/tools/random_gen.py only
        # ever generates forward-only branches/jumps.
        byte_len = len(words) * 4
        steps = 0
        while self.pc < byte_len and steps < max_steps:
            # docs/adr/0020-soc-integration.md (Phase D10). Externally
            # scheduled interrupt injection -- checked *before* the
            # self-loop-halt detection below, deliberately: if `after_steps`
            # happens to land exactly on (or past) the halt loop, the
            # interrupt must still fire rather than the halt check breaking
            # out first and silently skipping it. Single-shot by
            # construction (pending_interrupt is cleared the instant it
            # fires) -- no separate re-trigger-prevention logic needed on
            # this side the way the RTL's own handler needs one (mip is a
            # real level signal there; this is just a one-time scheduled
            # event here).
            if (self.pending_interrupt is not None
                    and steps >= self.pending_interrupt["after"]
                    and ((self.csr[CSR_MSTATUS] >> 3) & 1)):
                self.trap(self.pending_interrupt["cause"])
                self.pending_interrupt = None
                continue
            word = words[self.pc // 4]
            if word & 0x7F == 0b1101111:  # jal
                b20 = (word >> 31) & 1
                b19_12 = (word >> 12) & 0xFF
                b11 = (word >> 20) & 1
                b10_1 = (word >> 21) & 0x3FF
                off = sext((b20 << 20) | (b19_12 << 12) | (b11 << 11) | (b10_1 << 1), 21)
                if off == 0:
                    break  # self-loop halt, see comment above
            self.step(word)
            steps += 1
        else:
            if steps >= max_steps:
                raise RuntimeError(f"exceeded {max_steps} steps without reaching a self-loop -- program likely loops forever unexpectedly")
        return steps
