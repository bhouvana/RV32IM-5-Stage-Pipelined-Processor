`include "ImmGen.v"

// Generation 2 (Phase M, docs/adr/0028-rv64-migration-phase-m.md). Standalone
// unit test for ImmGen.v's Width=64 sign/zero-extension fix, independent of
// the full pipeline. Two DUTs (Width=32 and Width=64) share the same raw
// instruction word for every case: for every arm that must SIGN-extend
// (everything except the shift-immediate shamt field and the CSR address),
// imm64[31:0] must equal imm32[31:0] bit-for-bit (the fix must not disturb
// the pre-existing low-order computation) while imm64[63:32] must equal
// {32{inst[31]}} -- all 1s when the sign source bit is 1, all 0s when it's
// 0, never the pre-fix bug's silent zero-fill regardless of sign. The
// shift-immediate arm is checked separately with explicit numeric values,
// since Width=32 and Width=64 are *expected* to diverge there (5-bit vs
// 6-bit shamt, see riscv_defs.vh's FUNCT6_ALT comment).
module tb_immgen_unit;
    reg  [31:0] inst = 0;
    wire signed [31:0] imm32;
    wire signed [63:0] imm64;

    ImmGen #(.Width(32)) dut32(.inst(inst), .imm(imm32));
    ImmGen #(.Width(64)) dut64(.inst(inst), .imm(imm64));

    integer checks = 0;
    integer fails = 0;

    task check_word64;
        input [63:0] actual, expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: 0x%016h, expected 0x%016h", label, actual, expected);
            end else begin
                $display("pass  %0s: 0x%016h", label, actual);
            end
        end
    endtask

    // Sign-extending arm: low 32 bits identical across widths, high 32
    // bits must equal the sign source replicated, never zero-filled.
    task check_sign_extends;
        input sign_bit;
        input [1023:0] label;
        reg [63:0] expected;
        begin
            expected = {{32{sign_bit}}, imm32};
            check_word64(imm64, expected, label);
        end
    endtask

    // B-type/J-type carry a leading 1'b0 width-filler bit (see ImmGen.v's
    // own comments) that riscvpipeline.v's ShiftLeftOne consumes -- its
    // position depends on Width, so imm64[31:0] is NOT expected to equal
    // imm32[31:0] bit-for-bit the way every other arm's is. The real
    // invariant: apply the same left-shift-by-1 ShiftLeftOne performs, at
    // each width, and confirm both land on the true spec-defined signed
    // byte offset (computed here independently, in the real
    // {sign,fields,1'b0} spec order -- not reusing ImmGen's own internal
    // padded-pre-shift convention, so this is a real cross-check, not a
    // tautology).
    function [63:0] spec_b_imm;
        input [31:0] i;
        reg [12:0] raw;
        begin
            raw = {i[31], i[7], i[30:25], i[11:8], 1'b0};
            spec_b_imm = {{51{raw[12]}}, raw};
        end
    endfunction

    function [63:0] spec_j_imm;
        input [31:0] i;
        reg [20:0] raw;
        begin
            raw = {i[31], i[19:12], i[20], i[30:21], 1'b0};
            spec_j_imm = {{43{raw[20]}}, raw};
        end
    endfunction

    task check_shift_matches_spec;
        input [63:0] spec_expected;
        input [1023:0] label;
        reg [63:0] shifted64;
        reg [31:0] shifted32;
        begin
            shifted64 = {imm64[62:0], 1'b0};
            shifted32 = {imm32[30:0], 1'b0};
            check_word64(shifted64, spec_expected, {label, " (Width=64, post-shift)"});
            check_word64({{32{shifted32[31]}}, shifted32}, spec_expected, {label, " (Width=32, post-shift, sign-extended)"});
        end
    endtask

    initial begin
        // ---- I-type non-shift (addi/andi/ori/.../slti), funct3=000, opcode=OPCODE_I ----
        inst = {12'hFFF, 5'd0, 3'b000, 5'd0, 7'b0010011};
        #1 check_sign_extends(inst[31], "addi-shaped, imm=0xFFF (sign=1)");
        inst = {12'h555, 5'd0, 3'b000, 5'd0, 7'b0010011};
        #1 check_sign_extends(inst[31], "addi-shaped, imm=0x555 (sign=0)");

        // ---- I-type sltiu, funct3=011 ----
        inst = {12'hFFF, 5'd0, 3'b011, 5'd0, 7'b0010011};
        #1 check_sign_extends(inst[31], "sltiu-shaped, imm=0xFFF (sign=1)");
        inst = {12'h555, 5'd0, 3'b011, 5'd0, 7'b0010011};
        #1 check_sign_extends(inst[31], "sltiu-shaped, imm=0x555 (sign=0)");

        // ---- I-type shift-immediate (slli/srli/srai), funct3=001 ----
        // 6-bit field inst[25:20]=6'b100001=33 (bit25 set): Width=64 must
        // zero-extend the full 6 bits (33); Width=32 must drop bit25 and
        // zero-extend only inst[24:20]=5'b00001=1 (today's exact pre-fix
        // behavior -- this is the bit-exact-at-Width=32 regression check).
        inst = {6'b000000, 6'b100001, 5'd0, 3'b001, 5'd0, 7'b0010011};
        #1 check_word64(imm64, 64'd33, "slli-shaped shamt=33 (bit25 set), Width=64 uses full 6 bits");
        checks = checks + 1;
        if (imm32 !== 32'd1) begin
            fails = fails + 1;
            $display("FAIL  slli-shaped shamt=33 (bit25 set), Width=32 must drop bit25: got %0d, expected 1", imm32);
        end else begin
            $display("pass  slli-shaped shamt=33 (bit25 set), Width=32 drops bit25: %0d", imm32);
        end

        // ---- B-type (beq), opcode=OPCODE_BRANCH ----
        inst = {1'b1, 6'b111111, 5'd0, 5'd0, 3'b000, 4'b1111, 1'b1, 7'b1100011};
        #1 check_shift_matches_spec(spec_b_imm(inst), "beq-shaped, all immediate-source bits 1 (sign=1)");
        inst = {1'b0, 6'b010101, 5'd0, 5'd0, 3'b000, 4'b0101, 1'b0, 7'b1100011};
        #1 check_shift_matches_spec(spec_b_imm(inst), "beq-shaped, alternating pattern (sign=0)");

        // ---- S-type (sw), opcode=OPCODE_STORE ----
        inst = {7'b1111111, 5'd0, 5'd0, 3'b010, 5'b11111, 7'b0100011};
        #1 check_sign_extends(inst[31], "sw-shaped, all immediate-source bits 1 (sign=1)");
        inst = {7'b0101010, 5'd0, 5'd0, 3'b010, 5'b01010, 7'b0100011};
        #1 check_sign_extends(inst[31], "sw-shaped, alternating pattern (sign=0)");

        // ---- J-type (jal), opcode=OPCODE_JAL ----
        inst = {1'b1, 10'b1111111111, 1'b1, 8'b11111111, 5'd0, 7'b1101111};
        #1 check_shift_matches_spec(spec_j_imm(inst), "jal-shaped, all immediate-source bits 1 (sign=1)");
        inst = {1'b0, 10'b0101010101, 1'b0, 8'b01010101, 5'd0, 7'b1101111};
        #1 check_shift_matches_spec(spec_j_imm(inst), "jal-shaped, alternating pattern (sign=0)");

        // ---- jalr, opcode=OPCODE_JALR (plain I-type immediate shape) ----
        inst = {12'hFFF, 5'd0, 3'b000, 5'd0, 7'b1100111};
        #1 check_sign_extends(inst[31], "jalr-shaped, imm=0xFFF (sign=1)");
        inst = {12'h555, 5'd0, 3'b000, 5'd0, 7'b1100111};
        #1 check_sign_extends(inst[31], "jalr-shaped, imm=0x555 (sign=0)");

        // ---- lui, opcode=OPCODE_LUI (U-type: spec sign-extends the 32-bit result) ----
        inst = {20'hFFFFF, 5'd0, 7'b0110111};
        #1 check_sign_extends(inst[31], "lui-shaped, imm[31:12]=0xFFFFF (sign=1)");
        inst = {20'h7FFFF, 5'd0, 7'b0110111};
        #1 check_sign_extends(inst[31], "lui-shaped, imm[31:12]=0x7FFFF (sign=0)");

        // ---- SYSTEM/CSR, opcode=OPCODE_SYSTEM: must ZERO-extend, never sign ----
        inst = {12'hFFF, 5'd0, 3'b001, 5'd0, 7'b1110011};
        #1 check_word64(imm64, {32'b0, imm32}, "csr-shaped, csr_addr=0xFFF: zero-extends despite inst[31]=1");

        if (fails == 0)
            $display("PASS  immgen_unit (%0d checks)", checks);
        else
            $display("FAIL  immgen_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
