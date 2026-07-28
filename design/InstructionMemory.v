`default_nettype none

// Instruction ROM: a flat byte array, word-read combinationally at
// `readAddr` (no synchronous retiming yet -- see docs/adr/0013's Future
// improvements, which retimed DataMemoryBRAM.v this way but left this
// module as future work). Reads past `SIZE_BYTES` return 0, which
// Control.v decodes as opcode 0000000, a real illegal-instruction trap
// (docs/adr/0011) -- every test program relies on this to catch a runaway
// PC (see the "jal x0, self" halt-loop convention documented in
// docs/ROADMAP.md).
module InstructionMemory #(
    // Resolved relative to the simulator's working directory at run time
    // (Icarus resolves $readmemb paths against the invoking process's CWD,
    // not the source file's location) -- the provided Makefile always
    // invokes vvp from the repository root, so paths here are repo-root-relative.
    parameter INIT_FILE = "sim/programs/arith.mem",
    parameter SIZE_BYTES = 128,  // was a hardcoded 128 throughout; now threaded
                                   // from PIPELINED, matching DataMemory.v
                                   // (docs/ROADMAP.md Phase 6/7).
    parameter XLEN = 32   // docs/adr/0015-xlen-and-regcount-parameterization.md.
                            // Applies to readAddr/inst too, same simplification
                            // ImmGen.v/reg1.v already made -- RV32I's fixed
                            // 32-bit instruction word happens to equal XLEN,
                            // only because both are 32 for this ISA.
) (
    input [XLEN-1:0] readAddr,
    output [XLEN-1:0] inst
);

    reg [7:0] insts [0:SIZE_BYTES-1];

    assign inst = (readAddr >= SIZE_BYTES) ? {XLEN{1'b0}} : {insts[readAddr], insts[readAddr + 1], insts[readAddr + 2], insts[readAddr + 3]};

    integer i;
    initial begin
        for (i = 0; i < SIZE_BYTES; i = i + 1)
            insts[i] = 8'b0;
        // Explicit start/stop avoids relying on simulator-specific default
        // behavior for which end of a descending-range array $readmemb fills
        // first (Icarus warns about exactly this ambiguity otherwise).
        if (INIT_FILE != "")
            $readmemb(INIT_FILE, insts, 0, SIZE_BYTES-1);
    end

endmodule

`default_nettype wire
