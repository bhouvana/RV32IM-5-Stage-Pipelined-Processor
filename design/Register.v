`default_nettype none

// Do not modify this file!

module Register (
    input clk,
    input rst,
    input regWrite,
    input [4:0] readReg1,
    input [4:0] readReg2,
    input [4:0] writeReg,
    input [31:0] writeData,
    output [31:0] readData1,
    output [31:0] readData2
);
    reg [31:0] regs [0:31];

    // Write-first bypass. Without this, a read of the register a same-cycle
    // write is targeting returns the pre-write (stale) value: the write
    // below is a synchronous posedge update while reads are combinational.
    // This is NOT redundant with Forward.v's EX/MEM and MEM/WB forwarding --
    // those only cover a producer still resident in a pipeline register.
    // They do not cover a producer whose WB-stage cycle exactly coincides
    // with a *different* instruction's ID-stage read (concretely: producer
    // and consumer exactly 3 instructions apart with no intervening hazard).
    // That gap fell through every existing hazard/forwarding path silently
    // until sim/programs/arith.s caught it -- see docs/adr/0002-register-file-write-first-bypass.md.
    assign readData1 = (readReg1 == 0) ? 32'b0 :
                        (regWrite && writeReg == readReg1) ? writeData :
                        regs[readReg1];
    assign readData2 = (readReg2 == 0) ? 32'b0 :
                        (regWrite && writeReg == readReg2) ? writeData :
                        regs[readReg2];

    always @(posedge clk) begin
        if(~rst) begin
            regs[0] <= 0; regs[1] <= 0; regs[2] <= 32'd128; regs[3] <= 0; 
            regs[4] <= 0; regs[5] <= 0; regs[6] <= 0; regs[7] <= 0; 
            regs[8] <= 0; regs[9] <= 0; regs[10] <= 0; regs[11] <= 0; 
            regs[12] <= 0; regs[13] <= 0; regs[14] <= 0; regs[15] <= 0; 
            regs[16] <= 0; regs[17] <= 0; regs[18] <= 0; regs[19] <= 0; 
            regs[20] <= 0; regs[21] <= 0; regs[22] <= 0; regs[23] <= 0; 
            regs[24] <= 0; regs[25] <= 0; regs[26] <= 0; regs[27] <= 0; 
            regs[28] <= 0; regs[29] <= 0; regs[30] <= 0; regs[31] <= 0;        
        end
        else if(regWrite)
            regs[writeReg] <= (writeReg == 0) ? 0 : writeData;
    end

// Compiled in only with -DASSERT_ON (see sim/run_tests.sh). x0 is hardwired
// to 0 in two independent places above (the write path and the write-first
// bypass reads) -- this checks the invariant the whole ISA depends on
// (x0 reads as 0, always) rather than trusting those two sites never drift
// out of sync with each other.
`ifdef ASSERT_ON
always @(posedge clk) begin
    if (rst && regs[0] !== 32'b0)
        begin $display("ASSERTION FAILED @t=%0t: regs[0] = %0d, x0 must always read 0", $time, regs[0]); $finish; end
end
`endif

endmodule

`default_nettype wire
