# Requires Icarus Verilog (iverilog/vvp) and Python 3 on PATH.
# On Windows without `make` available, use sim/run_tests.sh instead --
# both do the same thing.

PROGRAMS := $(wildcard sim/programs/*.s)
MEMS     := $(PROGRAMS:.s=.mem)

.PHONY: test lint clean viewer

test: $(MEMS)
	@bash sim/run_tests.sh

sim/programs/%.mem: sim/programs/%.s sim/tools/asm.py
	python sim/tools/asm.py $< -o $@

# Not a real lint pass (no Verible in this environment yet, see docs/ROADMAP.md
# CQ-5) -- this at least catches syntax errors and latch/width warnings via
# `iverilog -Wall` without elaborating a full simulation.
lint:
	iverilog -Wall -g2005 -I design -tnull design/*.v

# Cycle-accurate pipeline viewer (docs/ROADMAP.md Phase 4) -- traces
# sim/programs/demo.s by default; edit sim/tb/gen_trace.v's INIT_FILE to
# trace a different program.
viewer: sim/programs/demo.mem
	iverilog -g2005 -I design -o /tmp/gen_trace.vvp sim/tb/gen_trace.v
	vvp /tmp/gen_trace.vvp
	python sim/tools/build_viewer.py trace.csv -o pipeline-viewer.html
	rm -f trace.csv /tmp/gen_trace.vvp

clean:
	rm -f sim/programs/*.mem trace.csv pipeline-viewer.html
