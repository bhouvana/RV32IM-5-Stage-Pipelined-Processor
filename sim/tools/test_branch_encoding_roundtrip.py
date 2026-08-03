"""Phase N (docs/adr/0030-branch-encoding-fix.md): confirms asm.py and disasm.py agree on
the post-swap branch funct3 encoding, and that it matches the real RISC-V spec positions for
blt/bge. Run directly: python sim/tools/test_branch_encoding_roundtrip.py
"""
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from asm import assemble
from disasm import disasm

EXPECTED_FUNCT3 = {"beq": 0b000, "bne": 0b001, "blt": 0b100, "bge": 0b101,
                   "ble": 0b010, "bgt": 0b011, "bltu": 0b110, "bgeu": 0b111}


def check_roundtrip(mnemonic):
    asm_line = f"{mnemonic} x1, x2, 0"
    words = assemble([asm_line])
    assert len(words) == 1, f"{mnemonic}: expected 1 assembled word, got {len(words)}"
    word = words[0]
    funct3 = (word >> 12) & 0x7
    expected = EXPECTED_FUNCT3[mnemonic]
    assert funct3 == expected, (
        f"{mnemonic}: asm.py encoded funct3={funct3:03b}, expected {expected:03b}"
    )
    text = disasm(word)
    assert text.startswith(mnemonic + " "), (
        f"{mnemonic}: round-trip disassembled as '{text}', expected it to start with "
        f"'{mnemonic} '"
    )


def main():
    fails = 0
    for mnemonic in EXPECTED_FUNCT3:
        try:
            check_roundtrip(mnemonic)
            print(f"pass  {mnemonic}")
        except AssertionError as e:
            fails += 1
            print(f"FAIL  {mnemonic}: {e}")
    if fails == 0:
        print(f"PASS  branch_encoding_roundtrip ({len(EXPECTED_FUNCT3)} checks)")
        return 0
    else:
        print(f"FAIL  branch_encoding_roundtrip ({fails}/{len(EXPECTED_FUNCT3)} checks failed)")
        return 1


if __name__ == "__main__":
    sys.exit(main())
