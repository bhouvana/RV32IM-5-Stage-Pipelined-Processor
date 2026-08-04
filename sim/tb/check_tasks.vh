// Shared self-checking primitives for directed testbenches.
// `` `include``d into each per-test .v file (each test is compiled/run as its
// own standalone simulation, so there is no multiple-inclusion hazard here).

integer total_checks = 0;
integer total_fails  = 0;

task check_reg;
    // Generation 2 (Phase M13, docs/adr/0028-rv64-migration-phase-m.md):
    // widened from [31:0] to [63:0] -- no XLEN parameter needed here.
    // Verilog's !== zero-extends both operands to the wider context width
    // before comparing, so a 32-bit `actual` (at an XLEN=32 DUT) against a
    // 32-bit-shaped `expected` literal both zero-extend identically to 64
    // bits and compare exactly as before -- bit-exact for every existing
    // XLEN=32 test, and the only way to actually see a mismatch confined to
    // an RV64 register's upper 32 bits (e.g. sllw vs. a plain 64-bit sll
    // landing on the same low 32 bits but a different sign-extended top
    // half) instead of silently truncating it away.
    input [4:0] regnum;
    input [63:0] expected;
    input [511:0] label;
    reg [63:0] actual;
    begin
        actual = dut.m_Register.regs[regnum];
        total_checks = total_checks + 1;
        if (actual !== expected) begin
            total_fails = total_fails + 1;
            $display("  FAIL  %0s: x%0d = 0x%016h, expected 0x%016h", label, regnum, actual, expected);
        end else begin
            $display("  pass  %0s: x%0d = 0x%016h", label, regnum, actual);
        end
    end
endtask

task check_mem_word;
    // DataMemory stores bytes little-endian-at-address (byte0=address+0=LSB),
    // matching how DataMemory.v itself packs/unpacks writeData/readData.
    // docs/adr/0020-soc-integration.md (Phase D3): one hierarchy level
    // deeper than before -- m_DataMemory is now RamWishboneAdapter.v's
    // Wishbone-wrapper instance name, with the real DataMemoryBRAM.v
    // (and its data_memory array) inside it as m_ram.
    input [31:0] byte_addr;
    input [31:0] expected;
    input [511:0] label;
    reg [31:0] actual;
    begin
        actual = { dut.m_DataMemory.m_ram.data_memory[byte_addr+3],
                   dut.m_DataMemory.m_ram.data_memory[byte_addr+2],
                   dut.m_DataMemory.m_ram.data_memory[byte_addr+1],
                   dut.m_DataMemory.m_ram.data_memory[byte_addr+0] };
        total_checks = total_checks + 1;
        if (actual !== expected) begin
            total_fails = total_fails + 1;
            $display("  FAIL  %0s: mem[0x%0h] = 0x%08h, expected 0x%08h", label, byte_addr, actual, expected);
        end else begin
            $display("  pass  %0s: mem[0x%0h] = 0x%08h", label, byte_addr, actual);
        end
    end
endtask

task check_val;
    // Generic form of check_reg/check_mem_word for anything else worth
    // asserting on directly -- e.g. a CSR module's internal register
    // (docs/adr/0011-csr-and-exceptions.md), passed in by the caller since
    // Verilog-2005 has no dynamic hierarchical-path-by-string lookup.
    // Widened to [63:0] alongside check_reg (Phase M13) -- same bit-exact-
    // at-32-bits reasoning.
    input [63:0] actual;
    input [63:0] expected;
    input [511:0] label;
    begin
        total_checks = total_checks + 1;
        if (actual !== expected) begin
            total_fails = total_fails + 1;
            $display("  FAIL  %0s: 0x%016h, expected 0x%016h", label, actual, expected);
        end else begin
            $display("  pass  %0s: 0x%016h", label, actual);
        end
    end
endtask

task check_freg;
    // docs/adr/0019-f-extension.md: same shape as check_reg, but reads
    // FRegister.v's array instead of Register.v's -- bit-pattern compare is
    // deliberate (IEEE `==` would be wrong for NaN/-0.0, not a concern
    // rehashed here since these are directed non-NaN vectors). FRegister.v
    // stays FLEN=32 regardless of XLEN (RV64F keeps single-precision float
    // registers 32 bits wide, unlike the integer file) -- deliberately NOT
    // widened alongside check_reg/check_val (Phase M13); a 64-bit port here
    // would silently accept a caller passing a 64-bit expected value that
    // could never actually match a real 32-bit float register.
    input [4:0] regnum;
    input [31:0] expected;
    input [511:0] label;
    reg [31:0] actual;
    begin
        actual = dut.m_FRegister.regs[regnum];
        total_checks = total_checks + 1;
        if (actual !== expected) begin
            total_fails = total_fails + 1;
            $display("  FAIL  %0s: f%0d = 0x%08h, expected 0x%08h", label, regnum, actual, expected);
        end else begin
            $display("  pass  %0s: f%0d = 0x%08h", label, regnum, actual);
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
