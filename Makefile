# Requires Icarus Verilog (iverilog/vvp) and Python 3 on PATH.
# On Windows without `make` available, use sim/run_tests.sh instead --
# both do the same thing.

PROGRAMS := $(wildcard sim/programs/*.s)
MEMS     := $(PROGRAMS:.s=.mem)

.PHONY: test lint clean

test: $(MEMS)
	@bash sim/run_tests.sh

sim/programs/%.mem: sim/programs/%.s sim/tools/asm.py
	python sim/tools/asm.py $< -o $@

# Not a real lint pass (no Verible in this environment yet, see docs/ROADMAP.md
# CQ-5) -- this at least catches syntax errors and latch/width warnings via
# `iverilog -Wall` without elaborating a full simulation.
lint:
	iverilog -Wall -g2005 -I design -tnull design/*.v

clean:
	rm -f sim/programs/*.mem
