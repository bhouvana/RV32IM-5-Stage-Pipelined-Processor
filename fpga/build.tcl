# Non-interactive Vivado project/build script for fpga/top.v (docs/ROADMAP.md
# Phase 7, docs/adr/0012-fpga-readiness.md). Run once Vivado and a real,
# filled-in board constraints file exist -- this repo does not include
# either (see fpga/README.md for why: no vendor toolchain and no physical
# board are available in the environment this was written in, so this
# script is unrun/unverified against a real Vivado install -- it follows
# Vivado's own documented batch-mode Tcl API, but "the syntax is right" and
# "it has actually been run" are different claims, and only the first one
# is being made here).
#
# Usage (from the repo root, with Vivado's bin/ on PATH):
#   vivado -mode batch -source fpga/build.tcl -tclargs <board_xdc> [part]
#
# <board_xdc>: path to a REAL, board-specific constraints file with actual
#              pin numbers filled in -- copy fpga/constraints_template.xdc
#              to fpga/constraints_<yourboard>.xdc first (see that file's
#              header comment and fpga/README.md). Passing the template
#              itself will fail synthesis (PACKAGE_PIN CLK_PIN etc. are not
#              real pin names).
# [part]:      Vivado part number for your board (e.g. xc7a35ticsg324-1L
#              for a Digilent Arty A7-35T). Defaults below to that part --
#              override for a different board/device.

if {[llength $argv] < 1} {
    puts "usage: vivado -mode batch -source fpga/build.tcl -tclargs <board_xdc> \[part\]"
    exit 1
}
set board_xdc [lindex $argv 0]
set part_name [expr {[llength $argv] >= 2 ? [lindex $argv 1] : "xc7a35ticsg324-1L"}]

if {![file exists $board_xdc]} {
    puts "error: $board_xdc does not exist -- copy fpga/constraints_template.xdc to a real, board-specific file and fill in actual pin numbers first"
    exit 1
}

set repo_root [file normalize [file dirname [info script]]/..]
set build_dir [file normalize $repo_root/fpga/build]
file mkdir $build_dir

create_project -force riscv_pipeline_top $build_dir/riscv_pipeline_top -part $part_name

# design/*.v : every RTL module this design needs. fpga/top.v is the
# bring-up wrapper (docs/adr/0012) -- set as the top module explicitly
# below, since add_files also (correctly) picks up every testbench-only
# module under sim/ if pointed there, which is why sim/ is NOT added here.
add_files -norecurse [glob $repo_root/design/*.v]
add_files -norecurse $repo_root/fpga/top.v
add_files -fileset constrs_1 -norecurse $board_xdc

set_property top top [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs [get_param general.maxThreads]
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "error: synthesis did not complete -- check $build_dir/riscv_pipeline_top.runs/synth_1/runme.log"
    exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs [get_param general.maxThreads]
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "error: implementation/bitstream generation did not complete -- check $build_dir/riscv_pipeline_top.runs/impl_1/runme.log"
    exit 1
}

open_run impl_1
report_utilization -file $build_dir/utilization.rpt
report_timing_summary -file $build_dir/timing_summary.rpt

set bitstream [glob -nocomplain $build_dir/riscv_pipeline_top.runs/impl_1/*.bit]
if {$bitstream eq ""} {
    puts "error: no .bit file produced -- check the implementation log"
    exit 1
}
puts "bitstream: $bitstream"
puts "utilization report: $build_dir/utilization.rpt"
puts "timing summary: $build_dir/timing_summary.rpt"
