`default_nettype none

module InstructionMemory #(
    // Resolved relative to the simulator's working directory at run time
    // (Icarus resolves $readmemb paths against the invoking process's CWD,
    // not the source file's location) -- the provided Makefile always
    // invokes vvp from the repository root, so paths here are repo-root-relative.
    parameter INIT_FILE = "sim/programs/arith.mem"
) (
    input [31:0] readAddr,
    output [31:0] inst
);

    reg [7:0] insts [127:0];

    assign inst = (readAddr >= 128) ? 32'b0 : {insts[readAddr], insts[readAddr + 1], insts[readAddr + 2], insts[readAddr + 3]};

    integer i;
    initial begin
        for (i = 0; i < 128; i = i + 1)
            insts[i] = 8'b0;
        // Explicit start/stop avoids relying on simulator-specific default
        // behavior for which end of a descending-range array $readmemb fills
        // first (Icarus warns about exactly this ambiguity otherwise).
        if (INIT_FILE != "")
            $readmemb(INIT_FILE, insts, 0, 127);
    end

endmodule

`default_nettype wire
