`default_nettype none

`include "riscv_defs.vh"

module PIPELINED #(
    parameter INIT_FILE = "sim/programs/arith.mem"
)(
    input clk,
    input start
);
wire branch;
wire memRead;
wire memtoReg;
wire [1:0] ALUOp;
wire memWrite;
wire ALUSrc;
wire regWrite;
wire [4:0] readReg1;
wire [4:0] readReg2;
wire [4:0] writeReg;
wire [31:0] writeData;
wire [31:0] readData1;
wire [31:0] readData2;
wire [31:0] pc_final;
wire [31:0] imm_reg_val;
wire zero;
wire [4:0] ALUCtl;
wire [31:0] imm;
wire [31:0] ALUOut;
wire [31:0] address;
wire [31:0] imm_sum;
wire [31:0] imm_s;
wire [31:0] inst;
wire [31:0] pc_i;
wire [31:0] pc_o;
wire [31:0] pc_new;
//wire funct7;
//wire [2:0] funct3;
wire [31:0] readData;
wire jump;
wire jalr;
wire lui;
wire auipc;
wire stall;         // load-use hazard (Hazard.v); freezes PC/IF-ID
wire flush;         // load-use hazard (Hazard.v); bubbles ID/EX
wire branch_zero;   // ALU's raw branch-condition output, registered into `zero`
wire pc_stall;      // stall | div_stall (docs/adr/0009) -- what PC/reg1 actually freeze on

// rst is active-low and synchronous: while low, every pipeline register
// and the architectural register file hold their reset values; once
// driven high the pipeline runs. (Named "start" for historical reasons --
// this file began as a single-cycle CPU template.)


 //FETCH

    InstructionMemory #(.INIT_FILE(INIT_FILE)) m_InstMem(
    .readAddr(pc_o),
    .inst(inst)
    );
    //
    Mux2to1 #(.size(32)) m_Mux_PC(
        .sel(branch_taken),   // fires on a taken branch OR an unconditional jal, both resolved in EX
        .s0(pc_new),
        .s1(imm_sum),
        .out(pc_final)

    );
    //
    PC m_PC(
        .clk(clk),
        .rst(start),
        .stall(pc_stall),   // Hazard.v's load-use stall OR the multi-cycle divide interlock (docs/adr/0009)
        .pc_i(pc_final),
        .pc_o(pc_o)
    );

    Adder m_Adder_1(
        .a(pc_o),
        .b(4),
        .sum(pc_new)
    );

wire [31:0] inst_regfd;
wire [31:0] pc_o_regfd;

reg1 m_reg1(
    .clk(clk),
    .rst(start),
    .stall(pc_stall),
    .inst(inst),
    .pc_o(pc_o),
    .branch_regde(branch_regde),
    .zero(zero),
    .jump(jump_regde),
    .inst_regfd(inst_regfd),
    .pc_o_regfd(pc_o_regfd)
);

wire [2:0] funct3_control;
wire [6:0] funct7_control;


 //DECODE
    Control m_Control(
        .opcode(inst_regfd[6:0]),
        .funt7(inst_regfd[31:25]),
        .funt3(inst_regfd[14:12]),
        .branch(branch),
        .memRead(memRead),
        .memtoReg(memtoReg),
        .ALUOp(ALUOp),
        .memWrite(memWrite),
        .ALUSrc(ALUSrc),
        .regWrite(regWrite),
        .funct3(funct3_control),
        .funct7(funct7_control),
        .jump(jump),
        .jalr(jalr),
        .lui(lui),
        .auipc(auipc)
    );
//
    ImmGen #(.Width(32)) m_ImmGen(
        .inst(inst_regfd),
        .imm(imm)
    );
//
    Register m_Register(
        .clk(clk),
        .rst(start),
        .regWrite(regWrite_regwb),
        .readReg1(inst_regfd[19:15]),
        .readReg2(inst_regfd[24:20]),
        .writeReg(write_to_Reg_regwb),
        .writeData(writeData_regwb),
        .readData1(readData1),
        .readData2(readData2)
    );

    Hazard m_Hazard(
        .readReg1_fd(inst_regfd[19:15]),
        .readReg2_fd(inst_regfd[24:20]),
        .write_to_Reg_regde(write_to_Reg_regde),
        .memRead_regde(memRead_regde),
        .flush(flush),
        .stall(stall)
    );
//
    wire branch_regde;
    wire memRead_regde;
    wire memtoReg_regde;
    wire memWrite_regde;
    wire ALUSrc_regde;
    wire regWrite_regde;
    wire [1:0] ALUOp_regde;
    wire [4:0] writeReg_regde;
    wire [31:0] pc_o_regde;
    wire [31:0] readData1_regde;
    wire [31:0] readData2_regde;
    wire [31:0] imm_regde;
    wire [31:0] inst_regde;
    wire [4:0] readReg1_regde;
    wire [4:0] readReg2_regde;
    wire [1:0] forwardA;
    wire [1:0] forwardB;
    wire jump_regde;
    wire jalr_regde;
    wire lui_regde;
    wire auipc_regde;
    //
reg2 m_reg2(
    .clk(clk),
    .rst(start),
    .branch(branch),
    .memRead(memRead),
    .memtoReg(memtoReg),
    .memWrite(memWrite),
    .ALUSrc(ALUSrc),
    .regWrite(regWrite),
    .writeReg(inst_regfd[11:7]),
    .funct7(funct7_control),
    .funct3(funct3_control),
    .ALUOp(ALUOp),
    .pc_o_regfd(pc_o_regfd),
    .readData1(readData1),
    .readData2(readData2),
    .imm(imm),
    .inst_regfd(inst_regfd),
    .flush(flush),
    .branch_taken(branch_taken),
    .hold(div_stall),   // multi-cycle divide interlock, see docs/adr/0009-multicycle-divider.md
    .readReg1(inst_regfd[19:15]),
    .readReg2(inst_regfd[24:20]),
    .jump(jump),
    .jalr(jalr),
    .lui(lui),
    .auipc(auipc),

    .branch_regde(branch_regde),
    .memRead_regde(memRead_regde),
    .memtoReg_regde(memtoReg_regde),
    .memWrite_regde(memWrite_regde),
    .ALUSrc_regde(ALUSrc_regde),
    .regWrite_regde(regWrite_regde),
    .ALUOp_regde(ALUOp_regde),
    .write_to_Reg_regde(write_to_Reg_regde),
    .pc_o_regde(pc_o_regde),
    .readData1_regde(readData1_regde),
    .readData2_regde(readData2_regde),
    .imm_regde(imm_regde),
    .inst_regde(inst_regde),
    .funct7_regde(funct7_regde),
    .funct3_regde(funct3_regde),
    .readReg1_regde(readReg1_regde),
    .readReg2_regde(readReg2_regde),
    .jump_regde(jump_regde),
    .jalr_regde(jalr_regde),
    .lui_regde(lui_regde),
    .auipc_regde(auipc_regde)
);

wire [6:0] funct7_regde;
wire [14:12] funct3_regde;
wire [31:0] readData1_final;
wire [31:0] readData2_final;
wire branch_taken;
// Fires on a taken branch or an unconditional jal -- both resolved here in EX,
// both squash the two younger in-flight instructions (see reg1.jump / reg2.branch_taken).
assign branch_taken = (branch_regde & zero) | jump_regde;

// forwarding unit
Forward m_Forward(
    .readReg1_regde(readReg1_regde),
    .readReg2_regde(readReg2_regde),
    .write_to_Reg_regem(write_to_Reg_regem),
    .write_to_Reg_regwb(write_to_Reg_regwb),
    .regWrite_regwb(regWrite_regwb),
    .regWrite_regem(regWrite_regem),
    .forwardA(forwardA),
    .forwardB(forwardB)
);

//EXCECUTE
    ShiftLeftOne m_ShiftLeftOne(
    .i(imm_regde),
    .o(imm_s)
    );
//
    // Target-address base/offset: branch/jal use PC + (shifted immediate);
    // jalr uses rs1 + (plain, unshifted immediate) with bit0 cleared per
    // spec. Same adder, muxed inputs -- avoids a second dedicated adder for
    // what is otherwise identical redirect-target-computation plumbing.
    wire [31:0] target_base = jalr_regde ? readData1_final : pc_o_regde;
    wire [31:0] target_off  = jalr_regde ? imm_regde : imm_s;
    wire [31:0] imm_sum_raw;
    Adder m_Adder_2(
    .a(target_base),
    .b(target_off),
    .sum(imm_sum_raw)
    );
    assign imm_sum = {imm_sum_raw[31:1], 1'b0};  // clear bit0 (only jalr needs this; branch/jal sums are already even)

    // Link value for jal (rd = PC+4). Reuses the generic Adder the same way
    // Adder_1 (fetch, PC+4) and Adder_2 (branch/jump target) already do.
    wire [31:0] pc_plus4_regde;
    Adder m_Adder_3(
    .a(pc_o_regde),
    .b(32'd4),
    .sum(pc_plus4_regde)
    );

    // EX/MEM forwarding must hand out the *architectural* result of the EX/MEM
    // instruction, not the raw ALU output -- for jal those differ (ALUOut is
    // unused/meaningless for jal; the real result is PC+4). Forwarded from
    // MEM/WB (writeData_regwb, s1 below) is unaffected: that value is formed
    // by the WB-stage jal-override mux and is already correct.
    wire [31:0] exmem_fwd_val;
    assign exmem_fwd_val = jump_regem ? pc_plus4_regem : ALUOut_regem;

    Mux4to1 #(.size(32)) m_Mux_ALU_A(
    .sel(forwardA),
    .s0(readData1_regde),
    .s1(writeData_regwb),
    .s2(exmem_fwd_val),
    .out(readData1_final)
    );

    Mux4to1 #(.size(32)) m_Mux_ALU_B(
    .sel(forwardB),
    .s0(readData2_regde),
    .s1(writeData_regwb),
    .s2(exmem_fwd_val),
    .out(readData2_final)
    );




//
    Mux2to1 #(.size(32)) m_Mux_ALU(
    .sel(ALUSrc_regde),
    .s0(readData2_final),
    .s1(imm_regde),
    .out(imm_reg_val)
    );
//



    ALUCtrl m_ALUCtrl(
    .ALUOp(ALUOp_regde),
    //.functi(inst_regde)
    .funct7_c(funct7_regde),
    .funct3_c(funct3_regde),
    .ALUCtl(ALUCtl)
    );
//
    // lui/auipc have no real rs1 (those instruction bits are part of the
    // U-type immediate) -- they reuse the ALU's ADD by overriding its A
    // operand: 0 for lui (result = imm), PC for auipc (result = PC+imm).
    // This is why lui/auipc need no writeback-mux override or forwarding
    // correction the way jal/jalr did: ALUOut is already the right value,
    // so it flows through the existing EX/MEM path untouched.
    wire [31:0] aluA;
    Mux4to1 #(.size(32)) m_Mux_ALU_A_Src(
    .sel({auipc_regde, lui_regde}),
    .s0(readData1_final),
    .s1(32'b0),
    .s2(pc_o_regde),
    .out(aluA)
    );

    ALU m_ALU(
    .ALUCtl(ALUCtl),
    .A(aluA),
    .B(imm_reg_val),
    .ALUOut(ALUOut),
    .zero(zero),
    .branch_zero(branch_zero)
    );

    // Multi-cycle division interlock (docs/adr/0009-multicycle-divider.md).
    // Unlike mul (single-cycle via the ALU above), div/rem route through a
    // dedicated iterative unit and are NOT ready the same cycle they enter
    // EX. `start` is tied to `isDivRem` at the *level* (not a pulse) --
    // Divider.v's own `start && !busy` guard means it only actually latches
    // new operands once, on the first cycle, and naturally ignores `start`
    // staying asserted for the rest of the (many-cycle) computation.
    wire isDivRem = (ALUCtl == `ALUCTL_DIV) || (ALUCtl == `ALUCTL_DIVU) ||
                    (ALUCtl == `ALUCTL_REM) || (ALUCtl == `ALUCTL_REMU);
    wire isDivSigned = (ALUCtl == `ALUCTL_DIV) || (ALUCtl == `ALUCTL_REM);
    wire div_busy, div_done;
    wire [31:0] div_quotient, div_remainder;

    Divider m_Divider(
    .clk(clk),
    .rst(start),
    .start(isDivRem),
    .isSigned(isDivSigned),
    .dividend(aluA),
    .divisor(imm_reg_val),
    .busy(div_busy),
    .done(div_done),
    .quotient(div_quotient),
    .remainder(div_remainder)
    );

    // True from the cycle a div/rem enters EX until (not including) the
    // cycle its result becomes valid -- freezes PC/IF-ID (via pc_stall) and
    // holds ID/EX (reg2.hold) for exactly that span. False the rest of the
    // time, including every cycle occupied by a non-div/rem instruction, so
    // it never affects normal single-cycle execution.
    wire div_stall = isDivRem && !div_done;
    assign pc_stall = stall | div_stall;

    wire [31:0] div_result = (ALUCtl == `ALUCTL_DIV || ALUCtl == `ALUCTL_DIVU) ? div_quotient : div_remainder;
    // What EX "produces" this cycle: the divider's result on div/rem
    // (valid only when div_done, but only consumed downstream on that exact
    // cycle -- see reg3_bubble below), the ALU's result otherwise.
    wire [31:0] ex_result = isDivRem ? div_result : ALUOut;

    // Compiled in only with -DCOVERAGE (see sim/tools/coverage_report.py,
    // docs/ROADMAP.md V-5). Not a real statement/branch coverage tool (none
    // was available in this environment) -- functional coverage: how many
    // times each ALUCtl operation and each hazard/stall/branch-outcome class
    // was actually exercised, dumped to a fixed file per run and aggregated
    // across the whole suite by the Python driver. Zero synthesis/simulation
    // impact when the macro isn't defined.
    `ifdef COVERAGE
    integer cov_alu_ctl [0:31];
    integer cov_branch_taken [0:7];
    integer cov_branch_not_taken [0:7];
    integer cov_stall_cycles;
    integer cov_flush_cycles;
    integer cov_div_cycles;
    integer cov_jump_cycles;
    integer cov_i;
    integer cov_fd;
    initial begin
        for (cov_i = 0; cov_i < 32; cov_i = cov_i + 1) cov_alu_ctl[cov_i] = 0;
        for (cov_i = 0; cov_i < 8; cov_i = cov_i + 1) begin
            cov_branch_taken[cov_i] = 0;
            cov_branch_not_taken[cov_i] = 0;
        end
        cov_stall_cycles = 0;
        cov_flush_cycles = 0;
        cov_div_cycles = 0;
        cov_jump_cycles = 0;
    end
    always @(posedge clk) begin
        if (start) begin
            cov_alu_ctl[ALUCtl] = cov_alu_ctl[ALUCtl] + 1;
            if (stall) cov_stall_cycles = cov_stall_cycles + 1;
            if (flush) cov_flush_cycles = cov_flush_cycles + 1;
            if (div_stall) cov_div_cycles = cov_div_cycles + 1;
            if (jump_regde) cov_jump_cycles = cov_jump_cycles + 1;
            if (ALUOp_regde == `ALUOP_BRANCH) begin
                if (branch_zero) cov_branch_taken[funct3_regde] = cov_branch_taken[funct3_regde] + 1;
                else cov_branch_not_taken[funct3_regde] = cov_branch_not_taken[funct3_regde] + 1;
            end
        end
    end
    // Verilog-2005 (this project's language mode, see docs/ROADMAP.md CQ-5)
    // has no `final` block -- that's SystemVerilog. Exposed as a task
    // instead; each testbench calls `dut.dump_coverage;` immediately before
    // its own $finish (sim/run_tests.sh passes -DCOVERAGE and every tb_*.v
    // was updated to include the call, guarded the same way).
    task dump_coverage;
        begin
            cov_fd = $fopen("coverage.txt", "w");
            for (cov_i = 0; cov_i < 32; cov_i = cov_i + 1)
                $fdisplay(cov_fd, "alu_ctl %0d %0d", cov_i, cov_alu_ctl[cov_i]);
            for (cov_i = 0; cov_i < 8; cov_i = cov_i + 1) begin
                $fdisplay(cov_fd, "branch_taken %0d %0d", cov_i, cov_branch_taken[cov_i]);
                $fdisplay(cov_fd, "branch_not_taken %0d %0d", cov_i, cov_branch_not_taken[cov_i]);
            end
            $fdisplay(cov_fd, "stall_cycles %0d", cov_stall_cycles);
            $fdisplay(cov_fd, "flush_cycles %0d", cov_flush_cycles);
            $fdisplay(cov_fd, "div_cycles %0d", cov_div_cycles);
            $fdisplay(cov_fd, "jump_cycles %0d", cov_jump_cycles);
            $fclose(cov_fd);
        end
    endtask
    `endif

//
wire [4:0] write_to_Reg_regde;
wire memtoReg_regem;
wire regWrite_regem;
wire memRead_regem;
wire memWrite_regem;
wire [31:0] ALUOut_regem;
wire [31:0] readData2_regem;
wire [4:0] write_to_Reg_regem;
wire jump_regem;
wire [31:0] pc_plus4_regem;
wire [2:0] funct3_regem;
//
    // While a div/rem is still computing (div_stall), reg2/EX keeps
    // presenting the *same* div/rem instruction cycle after cycle (that's
    // the whole point of `hold`) -- without this mux, reg3 would latch that
    // instruction's control signals (regWrite=1 for any R-type op) every
    // one of those cycles, i.e. ~32 spurious register-file writes of a
    // not-yet-valid result before the real one. Bubbling the control
    // signals (not the data signals -- harmless once their gating control
    // bit is 0) makes this show up correctly everywhere downstream expects
    // "one instruction, one completion": the register file, forwarding,
    // and the pipeline viewer's trace. See docs/adr/0009-multicycle-divider.md.
    wire reg3_bubble = div_stall;
    wire memtoReg_to_reg3      = reg3_bubble ? 1'b0 : memtoReg_regde;
    wire regWrite_to_reg3      = reg3_bubble ? 1'b0 : regWrite_regde;
    wire memRead_to_reg3       = reg3_bubble ? 1'b0 : memRead_regde;
    wire memWrite_to_reg3      = reg3_bubble ? 1'b0 : memWrite_regde;
    wire jump_to_reg3          = reg3_bubble ? 1'b0 : jump_regde;
    wire [4:0] destReg_to_reg3 = reg3_bubble ? 5'b0  : write_to_Reg_regde;

reg3 m_reg3(
    .clk(clk),
    .rst(start),
    .memtoReg_regde(memtoReg_to_reg3),
    .regWrite_regde(regWrite_to_reg3),
    .memRead_regde(memRead_to_reg3),
    .memWrite_regde(memWrite_to_reg3),
    .ALUOut(ex_result),
    // Store data must come from the forwarded value (readData2_final), not
    // the raw decode-stage readData2_regde: Forward.v/Mux4to1 already
    // compute the correct EX/MEM- or MEM/WB-forwarded rs2 value for the ALU
    // path, but store data is a separate path to reg3/DataMemory that was
    // bypassing it entirely -- a `sw` whose data register was written 1-2
    // instructions earlier stored stale data. See docs/adr/0003-store-data-forwarding.md.
    .readData2_regde(readData2_final),
    .write_to_Reg_regde(destReg_to_reg3),
    .jump_regde(jump_to_reg3),
    .pc_plus4_regde(pc_plus4_regde),
    .funct3_regde(funct3_regde),

    .memtoReg_regem(memtoReg_regem),
    .regWrite_regem(regWrite_regem),
    .memRead_regem(memRead_regem),
    .memWrite_regem(memWrite_regem),
    .ALUOut_regem(ALUOut_regem),
    .readData2_regem(readData2_regem),
    .write_to_Reg_regem(write_to_Reg_regem),
    .jump_regem(jump_regem),
    .pc_plus4_regem(pc_plus4_regem),
    .funct3_regem(funct3_regem)
);

// Compiled in only with -DASSERT_ON (see sim/run_tests.sh). reg3 is a plain
// one-cycle pipeline register (readData2_regem <= readData2_regde every
// cycle, no stall/flush handling of its own), so readData2_regem this cycle
// must equal readData2_final as it was one cycle ago. This is exactly the
// property docs/adr/0003-store-data-forwarding.md's bug violated (reg3 was
// wired to the raw readData2_regde instead of the forwarded value) --
// this assertion would have caught that wiring mistake immediately instead
// of needing a directed test (store_load.s) to stumble into it.
`ifdef ASSERT_ON
reg [31:0] expected_store_data;
always @(posedge clk) begin
    expected_store_data <= readData2_final;
    if (start && memWrite_regem && (readData2_regem !== expected_store_data))
        begin
            $display("ASSERTION FAILED @t=%0t: reg3 store-data mismatch: readData2_regem=%0d, expected (last cycle's forwarded readData2_final)=%0d",
                      $time, readData2_regem, expected_store_data);
            $finish;
        end
end
`endif

//MEMORY
    DataMemory m_DataMemory(
    .rst(start),
    .clk(clk),
    .memWrite(memWrite_regem),
    .memRead(memRead_regem),
    .address(ALUOut_regem),
    .writeData(readData2_regem),
    .funct3(funct3_regem),
    .readData(readData)
    );
//
wire memtoReg_regwb;
wire regWrite_regwb;
wire [31:0] readData_regwb;
wire [31:0] ALUOut_regwb;
wire [31:0] readData_regem;
wire [4:0] write_to_Reg_regwb;
wire [31:0] writeData_regwb;
wire jump_regwb;
wire [31:0] pc_plus4_regwb;

//
reg4 m_reg4(
    .clk(clk),
    .rst(start),
    .memtoReg_regem(memtoReg_regem),
    .regWrite_regem(regWrite_regem),
    .readData(readData),
    .ALUOut_regem(ALUOut_regem),
    .write_to_Reg_regem(write_to_Reg_regem),
    .jump_regem(jump_regem),
    .pc_plus4_regem(pc_plus4_regem),
    .memtoReg_regwb(memtoReg_regwb),
    .regWrite_regwb(regWrite_regwb),
    .readData_regwb(readData_regwb),
    .ALUOut_regwb(ALUOut_regwb),
    .write_to_Reg_regwb(write_to_Reg_regwb),
    .jump_regwb(jump_regwb),
    .pc_plus4_regwb(pc_plus4_regwb)
);

//WRITEBACK
    wire [31:0] writeData_regwb_mem_alu;
    Mux2to1 #(.size(32)) m_Mux_WriteData(
    .sel(memtoReg_regwb),
    .s0(ALUOut_regwb),
    .s1(readData_regwb),
    .out(writeData_regwb_mem_alu)
    );

    // jal's result (PC+4) overrides the normal ALU/memory writeback value.
    Mux2to1 #(.size(32)) m_Mux_WriteData_Jump(
    .sel(jump_regwb),
    .s0(writeData_regwb_mem_alu),
    .s1(pc_plus4_regwb),
    .out(writeData_regwb)
    );

endmodule

`default_nettype wire
