#!/usr/bin/env bash
# Assembles every sim/programs/*.s test program and runs every sim/tb/tb_*.v
# directed testbench against it, with -DASSERT_ON so the design's embedded
# invariant checks (Forward.v, Hazard.v, Register.v, riscvpipeline.v -- see
# docs/ROADMAP.md V-3) run on every test, not just the ones written to
# specifically exercise them. Must be run from the repository root (paths
# -- both `` `include`` dirs and INIT_FILE -- are resolved relative to cwd).
#
# Usage: sim/run_tests.sh [iverilog-bin-dir]
#   e.g. sim/run_tests.sh /c/iverilog/bin   (if iverilog isn't already on PATH)

set -u
if [ -n "${1:-}" ]; then
    export PATH="$1:$PATH"
fi

if ! command -v iverilog >/dev/null 2>&1; then
    echo "error: iverilog not found on PATH (pass its bin dir as \$1)" >&2
    exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 2

echo "=== assembling test programs ==="
for src in sim/programs/*.s; do
    name="$(basename "$src" .s)"
    python sim/tools/asm.py "$src" -o "sim/programs/${name}.mem" || exit 1
done

echo
echo "=== running directed tests ==="
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail_count=0
test_count=0
for tb in sim/tb/tb_*.v; do
    name="$(basename "$tb" .v)"
    test_count=$((test_count + 1))
    out="$work/$name.out"
    if ! iverilog -g2005 -DASSERT_ON -I design -I sim/tb -o "$work/$name.vvp" "$tb" > "$out" 2>&1; then
        echo "COMPILE FAIL  $name"
        cat "$out"
        fail_count=$((fail_count + 1))
        continue
    fi
    vvp "$work/$name.vvp" > "$out" 2>&1
    cat "$out"
    if ! grep -q "^PASS" "$out"; then
        fail_count=$((fail_count + 1))
    fi
done

echo
echo "=== summary: $((test_count - fail_count))/$test_count tests passed ==="
exit $([ "$fail_count" -eq 0 ] && echo 0 || echo 1)
