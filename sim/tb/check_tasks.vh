// Shared self-checking primitives for directed testbenches.
// `` `include``d into each per-test .v file (each test is compiled/run as its
// own standalone simulation, so there is no multiple-inclusion hazard here).

integer total_checks = 0;
integer total_fails  = 0;

task check_reg;
    input [4:0] regnum;
    input [31:0] expected;
    input [511:0] label;
    reg [31:0] actual;
    begin
        actual = dut.m_Register.regs[regnum];
        total_checks = total_checks + 1;
        if (actual !== expected) begin
            total_fails = total_fails + 1;
            $display("  FAIL  %0s: x%0d = 0x%08h, expected 0x%08h", label, regnum, actual, expected);
        end else begin
            $display("  pass  %0s: x%0d = 0x%08h", label, regnum, actual);
        end
    end
endtask

task check_mem_word;
    // DataMemory stores bytes little-endian-at-address (byte0=address+0=LSB),
    // matching how DataMemory.v itself packs/unpacks writeData/readData.
    input [31:0] byte_addr;
    input [31:0] expected;
    input [511:0] label;
    reg [31:0] actual;
    begin
        actual = { dut.m_DataMemory.data_memory[byte_addr+3],
                   dut.m_DataMemory.data_memory[byte_addr+2],
                   dut.m_DataMemory.data_memory[byte_addr+1],
                   dut.m_DataMemory.data_memory[byte_addr+0] };
        total_checks = total_checks + 1;
        if (actual !== expected) begin
            total_fails = total_fails + 1;
            $display("  FAIL  %0s: mem[0x%0h] = 0x%08h, expected 0x%08h", label, byte_addr, actual, expected);
        end else begin
            $display("  pass  %0s: mem[0x%0h] = 0x%08h", label, byte_addr, actual);
        end
    end
endtask

task report;
    input [255:0] test_name;
    begin
        if (total_fails == 0)
            $display("PASS  %0s  (%0d checks)", test_name, total_checks);
        else
            $display("FAIL  %0s  (%0d/%0d checks failed)", test_name, total_fails, total_checks);
    end
endtask
