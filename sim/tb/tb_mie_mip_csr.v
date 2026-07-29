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
`include "reg2.v"
`include "reg3.v"
`include "reg4.v"
`include "Hazard.v"
`include "Forward.v"
`include "FForward.v"
`include "Divider.v"
`include "CSR.v"
`include "WbDecoder.v"
`include "RamWishboneAdapter.v"
`include "Uart.v"

// docs/adr/0020-soc-integration.md (Phase D7): mie/mip's CSR-only plumbing
// -- masking (only MTIE/MEIE survive a write to mie), csrrw-replaces-vs-
// csrrs-ORs semantics against a real bit-position pair spread across the
// 32-bit register (not adjacent low bits, unlike mscratch's own
// tb_csr_ops.v coverage), and mip's read-only/write-dropped behavior.
// No live interrupt redirect exists yet (D9) -- mip reads 0 throughout
// since riscvpipeline.v ties timer_pending/ext_pending to 1'b0 until D8.
module tb_mie_mip_csr;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/mie_mip_csr.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #300;

        check_reg(2, 32'h00000000, "csrrw x2,mie,0x7f: x2 = old mie (0)");
        check_reg(3, 32'h00000000, "mie reads back 0 -- no real bits in 0x7f survived masking");

        check_reg(4, 32'h00000000, "csrrw x4,mie,0x80: x4 = old mie (0)");
        check_reg(5, 32'h00000080, "mie reads back 0x80 -- MTIE alone survived");

        check_reg(6, 32'h00000080, "csrrw x6,mie,0x800: x6 = old mie (0x80)");
        check_reg(7, 32'h00000800, "mie reads back 0x800 -- csrrw REPLACED, MTIE dropped");

        check_reg(8, 32'h00000800, "csrrs x8,mie,0x80: x8 = old mie (0x800)");
        check_reg(9, 32'h00000880, "mie reads back 0x880 -- csrrs ORed, MTIE and MEIE both set");

        check_reg(10, 32'h00000000, "mip reads 0 before any write attempt (nothing pending, D8 not wired yet)");
        check_reg(11, 32'h00000000, "csrrw x11,mip,0x7ff: x11 = old mip (0)");
        check_reg(12, 32'h00000000, "mip still reads 0 -- the write to a read-only CSR was silently dropped");

        report("mie_mip_csr");
        $finish;
    end
endmodule
