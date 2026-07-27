# Generic Xilinx (Vivado) XDC constraints template for fpga/top.v
# (docs/ROADMAP.md Phase 7, docs/adr/0012-fpga-readiness.md).
#
# This is NOT a working constraints file for any specific board -- every
# LOC (pin) and IOSTANDARD below is a placeholder. Copy this file to
# fpga/constraints_<board>.xdc, fill in the real pin numbers from your
# board's reference manual/schematic, and pass THAT file to Vivado, not
# this one. For a non-Xilinx target (Lattice iCE40/ECP5 via open-source
# yosys+nextpnr, Intel/Altera Quartus), the constraint *syntax* differs
# (.pcf for Lattice, .qsf for Intel) but the same four signals
# (clk_i/btn_rst_ni/leds[7:0]) need equivalent pin/timing constraints --
# translate this file's intent, not its syntax, for those toolchains.

## ---- Clock ----
# Replace CLK_PIN and CLK_PERIOD_NS with your board's oscillator pin and
# actual period (e.g. 10.000 for a 100MHz oscillator, 20.000 for 50MHz).
# HEARTBEAT_DIV_BITS in fpga/top.v assumes something in the 50-100MHz
# range for a human-visible blink rate -- retune it if your board's
# oscillator is far outside that range.
set_property PACKAGE_PIN CLK_PIN [get_ports clk_i]
set_property IOSTANDARD LVCMOS33 [get_ports clk_i]
create_clock -period CLK_PERIOD_NS -name sys_clk [get_ports clk_i]

## ---- Reset button ----
# Most dev boards have at least one active-low push button already wired
# with an external pull-up -- confirm polarity against your board's
# schematic (fpga/top.v assumes active-low; invert here or in top.v if
# your board's button is active-high instead).
set_property PACKAGE_PIN RST_BTN_PIN [get_ports btn_rst_ni]
set_property IOSTANDARD LVCMOS33 [get_ports btn_rst_ni]

## ---- LEDs ----
# Fill in 8 real LED pins from your board. Boards with fewer than 8
# user LEDs will need leds[7:0] narrowed in fpga/top.v to match, or left
# partially unconnected here (Vivado will warn, not error, on an
# unconstrained bit of a wider port -- still fix it before believing the
# waveform/board behavior line up).
set_property PACKAGE_PIN LED0_PIN [get_ports {leds[0]}]
set_property PACKAGE_PIN LED1_PIN [get_ports {leds[1]}]
set_property PACKAGE_PIN LED2_PIN [get_ports {leds[2]}]
set_property PACKAGE_PIN LED3_PIN [get_ports {leds[3]}]
set_property PACKAGE_PIN LED4_PIN [get_ports {leds[4]}]
set_property PACKAGE_PIN LED5_PIN [get_ports {leds[5]}]
set_property PACKAGE_PIN LED6_PIN [get_ports {leds[6]}]
set_property PACKAGE_PIN LED7_PIN [get_ports {leds[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[*]}]

## ---- False paths ----
# btn_rst_ni is asynchronous by nature (a mechanical button) and is
# synchronized inside fpga/top.v before use -- tell the tool not to time
# the raw async input against sys_clk, matching that synchronizer's intent.
set_false_path -from [get_ports btn_rst_ni]
