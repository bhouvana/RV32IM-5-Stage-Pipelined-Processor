`include "riscvpipeline.v"
`include "PC.v"
`include "Adder.v"
`include "ALU.v"
`include "ALUCtrl.v"
`include "Control.v"
`include "DataMemoryBRAM.v"
`include "ImmGen.v"
`include "InstructionMemory.v"
`include "Mux2to1.v"
`include "Mux4to1.v"
`include "MuxN.v"
`include "FRegister.v"
`include "FALU.v"
`include "FDivider.v"
`include "FSqrt.v"
`include "FMADDUnit.v"
`include "Register.v"
`include "ShiftLeftOne.v"
`include "reg1.v"
`include "reg1a.v"
`include "reg2.v"
`include "reg3.v"
`include "reg4.v"
`include "Hazard.v"
`include "HazardNoForward.v"
`include "Forward.v"
`include "FForward.v"
`include "Divider.v"
`include "CSR.v"
`include "WbDecoder.v"
`include "RamWishboneAdapter.v"
`include "Uart.v"
`include "Timer.v"
`include "Tlb.v"
`include "Ptw.v"
`include "Bht.v"
`include "Btb.v"
`include "ICache.v"
`include "DCache.v"
`include "MemoryLatencyModel.v"

// docs/adr/0027-formal-verification.md (Phase L4). Whole-pipeline
// abstracted safety property, the real stretch goal of this phase:
// a committing register write is always from a real, non-squashed
// instruction. Built directly on Phase L2's new `valid_regwb` (closing
// the loop reg2/reg3 already opened, docs/adr/0025 Phase J3) --
// `debug_regwrite_commit`/`debug_valid_commit` (Phase L4's own two new
// riscvpipeline.v debug-observability ports, same "unconnected changes
// nothing" shape as docs/adr/0012's debug_x10) expose exactly the two
// WB-stage signals this property compares, since Yosys's read_verilog
// can't resolve a hierarchical peek into an internal wire (confirmed
// repeatedly in L1/L3).
//
// Tractability: the .sby [script] blackboxes every submodule this
// property doesn't need (the F-extension unit, the bus/peripherals, the
// MMU's TLB/page-table-walker) via Yosys's own `blackbox` command --
// their real implementations are read normally (so hierarchy/port
// checking still passes) and then stripped to free/unconstrained
// interfaces, not shadowed via a separate stub-file/include-path trick.
// CACHE_MODE/BRANCH_PREDICTOR stay at their PROFILE_5STAGE/PREDICTOR_
// STATIC/CACHE_NONE defaults, so ICache/DCache/Bht/Btb/the I-side
// MemoryLatencyModel aren't even elaborated (they live inside
// riscvpipeline.v's own `generate` blocks) -- blackboxing them anyway is
// a harmless no-op, not load-bearing for this property.
module pipeline_formal (
    input clk,
    input start
);
    wire uart_tx;
    wire [31:0] debug_x10;
    wire debug_regwrite_commit, debug_valid_commit;

    // INIT_FILE's content is irrelevant to this property (formal BMC
    // treats memory contents as free/symbolic regardless) -- just needs
    // to exist so InstructionMemory.v's $readmemb doesn't fail to open a
    // file. dummy.mem is any valid 128-byte binary-ASCII memory image.
    PIPELINED #(.INIT_FILE("dummy.mem")) dut (
        .clk(clk),
        .start(start),
        .debug_x10(debug_x10),
        .uart_tx(uart_tx),
        .uart_rx(1'b1),
        .debug_regwrite_commit(debug_regwrite_commit),
        .debug_valid_commit(debug_valid_commit)
    );

    // Both signals are combinational reflections of reg4's own same-cycle
    // WB-stage outputs (regWrite_regwb/valid_regwb) -- no cross-cycle
    // $past() needed, unlike the CSR trap-entry property.
    always @(posedge clk) begin
        if (start)
            assert (!debug_regwrite_commit || debug_valid_commit);
    end
endmodule
