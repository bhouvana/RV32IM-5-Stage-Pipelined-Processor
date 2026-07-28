`default_nettype none

`include "riscv_defs.vh"

module PIPELINED #(
    parameter INIT_FILE = "sim/programs/arith.mem",
    parameter MEM_SIZE_BYTES = 128,  // threaded to both memories (docs/ROADMAP.md
                                       // Phase 6/7) -- default matches every
                                       // existing test program's assumptions,
                                       // so this is a no-op unless overridden.
    parameter DATA_INIT_FILE = "",   // docs/ROADMAP.md Phase 10 -- optional
                                       // pre-load for DataMemoryBRAM.v, e.g. a
                                       // compiled-C program's .data section.
                                       // Empty (default): every existing test's
                                       // assumption, data memory just resets to
                                       // zero as it always has.
    // docs/adr/0015-xlen-and-regcount-parameterization.md -- named, not truly
    // variable at other values: this core is RV32I+M only, and RV32I's own
    // instruction encoding hardwires a 32-bit instruction word and 5-bit
    // rs1/rs2/rd fields, so XLEN=32/NUM_REGS=32 are the only ISA-compliant
    // combination today. Threaded through as a single source of truth
    // (matching CQ-1's riscv_defs.vh spirit and docs/adr/0012's memory-size
    // precedent) and as groundwork for a possible future RV64I variant
    // (same instruction encoding, wider XLEN), not to claim arbitrary-width
    // support exists now.
    parameter XLEN = 32,
    parameter NUM_REGS = 32,
    // docs/adr/0016-swappable-hazard-strategy.md (docs/ROADMAP.md Phase 6:
    // "compare hazard strategies"). 0 (default): Hazard.v + Forward.v, this
    // core's original, fully-verified stall-on-load-use-only + forward-
    // everything-else strategy. 1: HazardNoForward.v, a conservative
    // alternate that stalls on *every* RAW hazard instead of forwarding
    // around any of them (Forward.v's muxes are forced to "no forward" in
    // this mode). Both are independently verified (see the ADR); 0 is what
    // every pre-existing test/ADR/benchmark result in this repo assumes.
    parameter HAZARD_STRATEGY = 0,
    // docs/adr/0018-variable-pipeline-depth.md (docs/ROADMAP.md Phase 6:
    // "compare pipeline depths") -- a closed, named enum, not a free integer
    // implying arbitrary stage counts (same honesty convention as
    // docs/adr/0015's XLEN/NUM_REGS). PROFILE_5STAGE (0, default): today's
    // exact IF/ID/EX/MEM/WB structure, bit-exact, what every existing test/
    // ADR/benchmark in this repo assumes. PROFILE_6STAGE_SPLIT_FETCH (1):
    // adds a second fetch-stage relay register (reg1a) ahead of today's IF/ID
    // boundary -- deliberately the structurally cheap alternate depth
    // (Forward.v/Hazard.v/reg2/reg3/reg4/the divider and MEM-stage interlocks
    // all anchor at ID/EX/MEM/WB, none of which a fetch-side split touches).
    // Splitting EX/MEM (branch-resolve-early, cache-miss stalls) remains
    // explicitly out of scope -- the genuinely larger redesign docs/adr/0016
    // already deferred, not attempted here either.
    parameter PIPELINE_PROFILE = 0
)(
    input clk,
    input start,
    output [XLEN-1:0] debug_x10   // read-only tap on x10/a0 (docs/adr/0012-fpga-
                                // readiness.md) -- a bare-metal test program's
                                // natural "write your result here" register
                                // under the standard RISC-V calling
                                // convention. Unused by every existing
                                // testbench (an unconnected output changes
                                // nothing about existing behavior); fpga/top.v
                                // is the first consumer.
);
// Register-address field width, derived once and reused on every
// pipeline-register/Register.v/Forward.v/Hazard.v instantiation below.
localparam REG_ADDR_WIDTH = $clog2(NUM_REGS);

// PIPELINE_PROFILE values (docs/adr/0018-variable-pipeline-depth.md) -- named
// constants purely for readability at the generate/if sites that consume
// this parameter; not yet consumed anywhere as of this commit.
localparam PROFILE_5STAGE = 0;
localparam PROFILE_6STAGE_SPLIT_FETCH = 1;

wire branch;
wire memRead;
wire memtoReg;
wire [1:0] ALUOp;
wire memWrite;
wire ALUSrc;
wire regWrite;
wire [REG_ADDR_WIDTH-1:0] readReg1;
wire [REG_ADDR_WIDTH-1:0] readReg2;
wire [REG_ADDR_WIDTH-1:0] writeReg;
wire [XLEN-1:0] writeData;
wire [XLEN-1:0] readData1;
wire [XLEN-1:0] readData2;
wire [XLEN-1:0] pc_final;
wire [XLEN-1:0] imm_reg_val;
wire zero;
wire [4:0] ALUCtl;
wire [XLEN-1:0] imm;
wire [XLEN-1:0] ALUOut;
wire [XLEN-1:0] imm_sum;
wire [XLEN-1:0] imm_s;
wire [XLEN-1:0] inst;
wire [XLEN-1:0] pc_o;
wire [XLEN-1:0] pc_new;
wire [XLEN-1:0] readData;
wire jump;
wire jalr;
wire lui;
wire auipc;
wire stall;         // load-use hazard (Hazard.v); freezes PC/IF-ID
wire flush;         // load-use hazard (Hazard.v); bubbles ID/EX
wire branch_zero;   // ALU's raw branch-condition output, registered into `zero`
wire pc_stall;      // stall | div_stall (docs/adr/0009) | mem_stall (docs/adr/0013) -- what PC/reg1 actually freeze on
wire isCsr;         // CSR/exceptions (docs/adr/0011-csr-and-exceptions.md)
wire isEcall;
wire isEbreak;
wire isMret;
wire illegalOpcode;
wire [XLEN-1:0] redirect_target;  // imm_sum (branch/jal/jalr), or mtvec/mepc on a trap/mret

// rst is active-low and synchronous: while low, every pipeline register
// and the architectural register file hold their reset values; once
// driven high the pipeline runs. (Named "start" for historical reasons --
// this file began as a single-cycle CPU template.)


 //FETCH

    // Under PROFILE_6STAGE_SPLIT_FETCH (docs/adr/0018-variable-pipeline-
    // depth.md), instruction memory reads reg1a's registered PC instead of
    // PC.v's combinational output directly -- one extra cycle of fetch
    // latency, decoupling PC generation from instruction-memory access.
    // PIPELINE_PROFILE is a parameter (elaboration-time constant), so this
    // ternary collapses to a direct wire connection with no runtime mux --
    // no generate/if needed here, unlike reg1a's own module-instantiation
    // choice, since this is a plain wire select, not a choice between
    // instantiating different modules.
    wire [XLEN-1:0] imem_read_addr = (PIPELINE_PROFILE == PROFILE_5STAGE) ? pc_o : pc_o_reg1a;

    InstructionMemory #(.INIT_FILE(INIT_FILE), .SIZE_BYTES(MEM_SIZE_BYTES), .XLEN(XLEN)) m_InstMem(
    .readAddr(imem_read_addr),
    .inst(inst)
    );
    //
    Mux2to1 #(.size(XLEN)) m_Mux_PC(
        .sel(branch_taken),   // fires on a taken branch, jal/jalr, a trap, or mret -- all resolved in EX
        .s0(pc_new),
        .s1(redirect_target),
        .out(pc_final)

    );
    //
    PC #(.XLEN(XLEN)) m_PC(
        .clk(clk),
        .rst(start),
        .stall(pc_stall),   // Hazard.v's load-use stall, the multi-cycle divide interlock (docs/adr/0009),
                            // or the MEM-stage interlock (docs/adr/0013)
        .pc_i(pc_final),
        .pc_o(pc_o)
    );

    Adder #(.XLEN(XLEN)) m_Adder_1(
        .a(pc_o),
        .b(4),
        .sum(pc_new)
    );

wire [XLEN-1:0] inst_regfd;
wire [XLEN-1:0] pc_o_regfd;

reg1 #(.XLEN(XLEN)) m_reg1(
    .clk(clk),
    .rst(start),
    .stall(pc_stall),
    .inst(inst),
    // Must be the PC that was actually used to fetch `inst` this cycle
    // (imem_read_addr), not PC.v's live pc_o -- under PROFILE_5STAGE these
    // are the same wire, but under PROFILE_6STAGE_SPLIT_FETCH pc_o has
    // already advanced to the *next* PC by the time inst (fetched via
    // reg1a's one-cycle-delayed address) comes back. Pairing inst with the
    // wrong PC here silently corrupts every PC-relative computation
    // downstream (branch/jal targets, auipc, jal's link address) --
    // caught by constrained-random cross-checking at profile 1 before this
    // fix, not assumed correct from the design alone.
    .pc_o(imem_read_addr),
    .branch_regde(branch_regde),
    .zero(zero),
    // jal/jalr, or a trap/mret (docs/adr/0011) -- see branch_taken's
    // definition -- ORed with redirect_squash_extend_r (docs/adr/0018),
    // which is always 0 under PROFILE_5STAGE, so this term is a genuine
    // no-op at the default profile.
    .jump(unconditional_redirect | redirect_squash_extend_r),
    .inst_regfd(inst_regfd),
    .pc_o_regfd(pc_o_regfd)
);

// IF1/IF2 relay register (docs/adr/0018-variable-pipeline-depth.md). Only
// instantiated (and only meaningful) under PROFILE_6STAGE_SPLIT_FETCH --
// same elaboration-time generate/if template docs/adr/0016 established for
// HAZARD_STRATEGY, so PROFILE_5STAGE's branch costs nothing and isn't even
// instantiated. A plain, unconditional relay -- no squash notion of its
// own; see reg1a.v's header comment for the two rejected designs (an
// infinite loop, then a duplicated fetch) and redirect_squash_extend_r
// below for where the actual fix lives.
wire [XLEN-1:0] pc_o_reg1a;
generate
if (PIPELINE_PROFILE == PROFILE_5STAGE) begin : gen_fetch_5stage
    assign pc_o_reg1a = pc_o;  // unused under this profile; tied off for cleanliness, not read anywhere
end else begin : gen_fetch_6stage_split_fetch
    reg1a #(.XLEN(XLEN)) m_reg1a(
        .clk(clk),
        .rst(start),
        .stall(pc_stall),
        .pc_o(pc_o),
        .pc_o_reg1a(pc_o_reg1a)
    );
end
endgenerate

// Under PROFILE_6STAGE_SPLIT_FETCH, a redirect needs reg1 (IF2/ID) to
// squash for one EXTRA cycle beyond what PROFILE_5STAGE needs -- an
// honest architectural cost, not a workaround: the extra fetch stage
// (reg1a) means one additional instruction is already "in flight," fetched
// using a now-stale address reg1a held before the redirect corrected it,
// by the time the redirect is discovered. Registers `branch_taken` one
// cycle so reg1's squash condition (fed via its `jump` port below) can OR
// it in; always 0 under PROFILE_5STAGE (the condition that sets it is
// itself gated on the split-fetch profile), so this is a genuine no-op at
// the default profile, not just a harmless-in-practice one. A real bug
// found by running constrained-random programs at this profile, not
// reasoned out in advance: without this, a redirect immediately followed
// by another instruction that depends on the redirect target's own
// results computes wrong values, because the duplicate/stale fetch this
// extra squash cycle discards would otherwise flow into reg2 and (for a
// CSR instruction specifically) apply its side effect an extra, spurious
// time.
reg redirect_squash_extend_r;
always @(posedge clk) begin
    if (~start)
        redirect_squash_extend_r <= 1'b0;
    else
        redirect_squash_extend_r <= (PIPELINE_PROFILE == PROFILE_6STAGE_SPLIT_FETCH) ? branch_taken : 1'b0;
end

wire [2:0] funct3_control;
wire [6:0] funct7_control;


 //DECODE
    Control m_Control(
        .opcode(inst_regfd[6:0]),
        .funt7(inst_regfd[31:25]),
        .funt3(inst_regfd[14:12]),
        .csr_imm12(inst_regfd[31:20]),
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
        .auipc(auipc),
        .isCsr(isCsr),
        .isEcall(isEcall),
        .isEbreak(isEbreak),
        .isMret(isMret),
        .illegalOpcode(illegalOpcode)
    );
//
    ImmGen #(.Width(XLEN)) m_ImmGen(
        .inst(inst_regfd),
        .imm(imm)
    );
//
    Register #(.XLEN(XLEN), .NUM_REGS(NUM_REGS), .SP_INIT(MEM_SIZE_BYTES)) m_Register(
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

    // Hazard strategy select (docs/adr/0016-swappable-hazard-strategy.md) --
    // elaboration-time choice between the two hazard units; whichever one
    // is NOT selected isn't even instantiated, so this costs nothing in the
    // default (HAZARD_STRATEGY=0) build.
    generate
    if (HAZARD_STRATEGY == 0) begin : gen_hazard_forwarding
        Hazard #(.NUM_REGS(NUM_REGS)) m_Hazard(
            .readReg1_fd(inst_regfd[19:15]),
            .readReg2_fd(inst_regfd[24:20]),
            .la_memRead(memRead_regde),
            .la_dest(write_to_Reg_regde),
            .flush(flush),
            .stall(stall)
        );
    end else begin : gen_hazard_no_forward
        HazardNoForward #(.NUM_REGS(NUM_REGS)) m_HazardNoForward(
            .readReg1_fd(inst_regfd[19:15]),
            .readReg2_fd(inst_regfd[24:20]),
            .regWrite_regde(regWrite_regde),
            .write_to_Reg_regde(write_to_Reg_regde),
            .regWrite_regem(regWrite_regem),
            .write_to_Reg_regem(write_to_Reg_regem),
            .branch_taken(branch_taken),
            .flush(flush),
            .stall(stall)
        );
    end
    endgenerate
//
    wire branch_regde;
    wire memRead_regde;
    wire memtoReg_regde;
    wire memWrite_regde;
    wire ALUSrc_regde;
    wire regWrite_regde;
    wire [1:0] ALUOp_regde;
    wire [REG_ADDR_WIDTH-1:0] writeReg_regde;
    wire [XLEN-1:0] pc_o_regde;
    wire [XLEN-1:0] readData1_regde;
    wire [XLEN-1:0] readData2_regde;
    wire [XLEN-1:0] imm_regde;
    wire [XLEN-1:0] inst_regde;
    wire [REG_ADDR_WIDTH-1:0] readReg1_regde;
    wire [REG_ADDR_WIDTH-1:0] readReg2_regde;
    wire [1:0] forwardA;
    wire [1:0] forwardB;
    wire jump_regde;
    wire jalr_regde;
    wire lui_regde;
    wire auipc_regde;
    wire isCsr_regde;
    wire isEcall_regde;
    wire isEbreak_regde;
    wire isMret_regde;
    wire illegalOpcode_regde;
    //
reg2 #(.XLEN(XLEN), .NUM_REGS(NUM_REGS)) m_reg2(
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
    .hold(reg2_hold),   // multi-cycle divide interlock (docs/adr/0009) OR MEM-stage
                         // interlock (docs/adr/0013) -- either way, ID/EX must not
                         // advance past the instruction reg3 isn't ready to accept yet.
    .readReg1(inst_regfd[19:15]),
    .readReg2(inst_regfd[24:20]),
    .jump(jump),
    .jalr(jalr),
    .lui(lui),
    .auipc(auipc),
    .isCsr(isCsr),
    .isEcall(isEcall),
    .isEbreak(isEbreak),
    .isMret(isMret),
    .illegalOpcode(illegalOpcode),

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
    .auipc_regde(auipc_regde),
    .isCsr_regde(isCsr_regde),
    .isEcall_regde(isEcall_regde),
    .isEbreak_regde(isEbreak_regde),
    .isMret_regde(isMret_regde),
    .illegalOpcode_regde(illegalOpcode_regde)
);

wire [6:0] funct7_regde;
wire [2:0] funct3_regde;
wire [XLEN-1:0] readData1_final;
wire [XLEN-1:0] readData2_final;
wire branch_taken;
wire unconditional_redirect;  // jal/jalr | trap | mret -- see the assign below, and docs/adr/0011
// Fires on a taken branch, an unconditional jal/jalr, a synchronous
// exception, or mret -- all resolved here in EX, all squash the two
// younger in-flight instructions (see reg1.jump / reg2.branch_taken).
assign branch_taken = (branch_regde & zero) | unconditional_redirect;

// forwarding unit (docs/adr/0016-swappable-hazard-strategy.md: only
// instantiated under the default forwarding strategy -- the alternate
// HazardNoForward.v strategy ties forwardA/B to "no forward" directly,
// relying entirely on stalling plus Register.v's existing write-first
// bypass instead).
generate
if (HAZARD_STRATEGY == 0) begin : gen_forward
    // fwd_valid/fwd_dest are farthest-producer-first (index 0 = MEM/WB,
    // index 1 = EX/MEM), matching Forward.v's NUM_FWD_SRC=2 default -- see
    // its own comment for why that order makes the nearest producer win
    // ties.
    Forward #(.NUM_REGS(NUM_REGS)) m_Forward(
        .readReg1_regde(readReg1_regde),
        .readReg2_regde(readReg2_regde),
        .fwd_valid({regWrite_regem, regWrite_regwb}),
        .fwd_dest({write_to_Reg_regem, write_to_Reg_regwb}),
        .forwardA(forwardA),
        .forwardB(forwardB)
    );
end else begin : gen_no_forward
    assign forwardA = 2'b00;
    assign forwardB = 2'b00;
end
endgenerate

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
    wire [XLEN-1:0] target_base = jalr_regde ? readData1_final : pc_o_regde;
    wire [XLEN-1:0] target_off  = jalr_regde ? imm_regde : imm_s;
    wire [XLEN-1:0] imm_sum_raw;
    Adder #(.XLEN(XLEN)) m_Adder_2(
    .a(target_base),
    .b(target_off),
    .sum(imm_sum_raw)
    );
    assign imm_sum = {imm_sum_raw[XLEN-1:1], 1'b0};  // clear bit0 (only jalr needs this; branch/jal sums are already even)

    // Link value for jal (rd = PC+4). Reuses the generic Adder the same way
    // Adder_1 (fetch, PC+4) and Adder_2 (branch/jump target) already do.
    wire [XLEN-1:0] pc_plus4_regde;
    Adder #(.XLEN(XLEN)) m_Adder_3(
    .a(pc_o_regde),
    .b(32'd4),
    .sum(pc_plus4_regde)
    );

    // EX/MEM forwarding must hand out the *architectural* result of the EX/MEM
    // instruction, not the raw ALU output -- for jal those differ (ALUOut is
    // unused/meaningless for jal; the real result is PC+4). Forwarded from
    // MEM/WB (writeData_regwb, s1 below) is unaffected: that value is formed
    // by the WB-stage jal-override mux and is already correct.
    wire [XLEN-1:0] exmem_fwd_val;
    assign exmem_fwd_val = jump_regem ? pc_plus4_regem : ALUOut_regem;

    // src bus must match Forward.v's fwd_dest ordering above (index 0 =
    // MEM/WB, index 1 = EX/MEM) so forwardA/B's encoding selects the right
    // value.
    MuxN #(.size(XLEN)) m_Mux_ALU_A(
    .sel(forwardA),
    .s0(readData1_regde),
    .src({exmem_fwd_val, writeData_regwb}),
    .out(readData1_final)
    );

    MuxN #(.size(XLEN)) m_Mux_ALU_B(
    .sel(forwardB),
    .s0(readData2_regde),
    .src({exmem_fwd_val, writeData_regwb}),
    .out(readData2_final)
    );




//
    Mux2to1 #(.size(XLEN)) m_Mux_ALU(
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
    wire [XLEN-1:0] aluA;
    Mux4to1 #(.size(XLEN)) m_Mux_ALU_A_Src(
    .sel({auipc_regde, lui_regde}),
    .s0(readData1_final),
    .s1({XLEN{1'b0}}),
    .s2(pc_o_regde),
    .out(aluA)
    );

    ALU #(.XLEN(XLEN)) m_ALU(
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
    wire [XLEN-1:0] div_quotient, div_remainder;

    Divider #(.XLEN(XLEN)) m_Divider(
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

    // MEM-stage interlock (docs/adr/0013-mem-stage-retiming.md). DataMemoryBRAM's
    // read is registered: a load's `readData` isn't valid until the cycle
    // *after* its address/memRead are presented, one cycle later than the old
    // combinational DataMemory.v. `mem_stall` is true for exactly that one
    // extra cycle a fresh load spends in reg3 (EX/MEM) -- mirrors div_stall's
    // shape one stage later: freezes PC/reg1/reg2 (via pc_stall/reg2.hold) and
    // now also reg3 AND reg4 themselves (each a new `hold` input, same
    // empty-branch idiom docs/adr/0009 used for reg2 -- NOT a bubble for
    // reg4, see its port comment for why that first attempt was wrong)
    // instead of either latching not-yet-valid readData or evicting a value
    // still needed for forwarding.
    //
    // mem_stall_done_r tracks "has the load currently latched in reg3 already
    // had its one stall cycle." A first attempt derived this from
    // DataMemoryBRAM's own registered "read happened last cycle" signal
    // instead of tracking it here -- that failed on back-to-back loads
    // (verified by running mem_bytes.s, not just reasoned about): a load
    // held in reg3 for its stall cycle keeps memRead asserted for 2 cycles,
    // so by the time the *next* load freshly arrives, the memory's own
    // signal is still reporting the *previous* load's read as having just
    // completed -- exactly the busy/done "re-triggering on the done cycle"
    // ambiguity docs/adr/0009 hit with the divider, and for the same
    // underlying reason: a bare level signal can't distinguish "still the
    // same request" from "a new request that happens to look the same."
    // Tracking readiness against reg3's own occupancy here (reset to 0
    // whenever mem_stall was 0 last cycle, which is exactly when reg3 is
    // about to accept a new occupant) sidesteps that ambiguity entirely.
    reg mem_stall_done_r;
    wire mem_stall = memRead_regem && !mem_stall_done_r;
    always @(posedge clk) begin
        if (~start) mem_stall_done_r <= 1'b0;
        else mem_stall_done_r <= mem_stall;
    end

    assign pc_stall = stall | div_stall | mem_stall;

    // reg2's own hold condition, factored out for reuse below (CSR.v's write
    // gating needs to know exactly the same thing reg2 does: "is this
    // instruction's stay in EX not over yet".
    wire reg2_hold = div_stall | mem_stall;

    wire [XLEN-1:0] div_result = (ALUCtl == `ALUCTL_DIV || ALUCtl == `ALUCTL_DIVU) ? div_quotient : div_remainder;

    // CSR / synchronous exceptions (docs/adr/0011-csr-and-exceptions.md).
    // M-mode only, no real interrupts -- illegal instruction, ecall, ebreak,
    // and the csrrw/csrrs/csrrc(+i) instructions plus mret to act on them.
    // Both exception sources resolve in EX, same stage as branch/jal/jalr:
    // illegalOpcode_regde came from Control.v at decode time (an
    // unrecognized opcode, or SYSTEM/funct3=0 with an unrecognized
    // funct12), while ALUCtl==ILLEGAL is only known now, after ALUCtrl has
    // decoded a *recognized* opcode's funct7/funct3 and found no valid op.
    wire exception_taken = illegalOpcode_regde | (ALUCtl == `ALUCTL_ILLEGAL) | isEcall_regde | isEbreak_regde;
    wire [XLEN-1:0] trap_cause = (illegalOpcode_regde | (ALUCtl == `ALUCTL_ILLEGAL)) ? `MCAUSE_ILLEGAL_INSTRUCTION :
                              isEbreak_regde ? `MCAUSE_BREAKPOINT :
                              isEcall_regde  ? `MCAUSE_ECALL_FROM_M :
                              {XLEN{1'b0}};

    // csrrwi/csrrsi/csrrci (funct3[2]=1) source their write data from a
    // zero-extended 5-bit immediate sitting in rs1's *field position*
    // (inst[19:15]) rather than a real register read; csrrw/csrrs/csrrc
    // (funct3[2]=0) use the actual (forwarded) rs1 value.
    wire [XLEN-1:0] csr_wdata = funct3_regde[2] ? {{(XLEN-5){1'b0}}, inst_regde[19:15]} : readData1_final;
    wire [XLEN-1:0] csr_old_val;
    wire [XLEN-1:0] mtvec_val, mepc_val;

    // csr_write_en/trap_taken/mret_taken must NOT simply be isCsr_regde/
    // exception_taken/isMret_regde directly: those are combinational, live
    // off reg2's *current* output, which stays constant across every cycle
    // reg2 is held (docs/adr/0013's mem_stall, e.g. an unrelated load
    // immediately preceding this instruction) -- unlike jal/branch (whose
    // redirect is naturally protected by reg2's hold-priority over its own
    // branch_taken squash, plus reg3 only ever capturing pre-edge values),
    // CSR.v is an external stateful module with no notion of "already
    // applied this instruction's effect." Left ungated, a held CSR/trap/mret
    // instruction would write on *every* held cycle, not just its last one:
    // csr_rdata (the value handed to rd) would reflect an already-applied
    // write instead of the true old value, and mstatus's MIE/MPIE swap
    // (self-referencing: mstatus[7]<=mstatus[3]) would corrupt itself on the
    // second application. Found by constrained-random cross-checking after
    // extending random_gen.py to generate CSR instructions -- not by any
    // directed test, none of which happen to put a CSR/trap/mret instruction
    // immediately after a load. Gating by !reg2_hold suppresses the write on
    // every held cycle and lets it fire exactly once, on the same cycle
    // reg3 finally accepts this instruction's other outputs.
    CSR #(.XLEN(XLEN)) m_CSR(
    .clk(clk),
    .rst(start),
    .csr_write_en(isCsr_regde && !reg2_hold),
    .csr_addr(imm_regde[11:0]),   // ImmGen.v zero-extends inst[31:20] into imm for OPCODE_SYSTEM
    .csr_op(funct3_regde[1:0]),
    .csr_wdata(csr_wdata),
    .csr_rdata(csr_old_val),
    .trap_taken(exception_taken && !reg2_hold),
    .trap_pc(pc_o_regde),
    .trap_cause(trap_cause),
    .mret_taken(isMret_regde && !reg2_hold),
    .mtvec_val(mtvec_val),
    .mepc_val(mepc_val)
    );

    // What EX "produces" this cycle: the CSR's old value on a real csrrX op,
    // the divider's result on div/rem (valid only when div_done, but only
    // consumed downstream on that exact cycle -- see reg3_bubble below),
    // the ALU's result otherwise. No forwarding correction needed for CSR
    // reads either (same reasoning as lui/auipc, docs/adr/0009): ex_result
    // is already correct by the time reg3 latches it.
    wire [XLEN-1:0] ex_result = isCsr_regde ? csr_old_val : (isDivRem ? div_result : ALUOut);

    assign unconditional_redirect = jump_regde | exception_taken | isMret_regde;
    assign redirect_target = exception_taken ? mtvec_val :
                              isMret_regde    ? mepc_val :
                                                 imm_sum;  // existing branch/jal/jalr target path

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
wire [REG_ADDR_WIDTH-1:0] write_to_Reg_regde;
wire memtoReg_regem;
wire regWrite_regem;
wire memRead_regem;
wire memWrite_regem;
wire [XLEN-1:0] ALUOut_regem;
wire [XLEN-1:0] readData2_regem;
wire [REG_ADDR_WIDTH-1:0] write_to_Reg_regem;
wire jump_regem;
wire [XLEN-1:0] pc_plus4_regem;
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
    wire [REG_ADDR_WIDTH-1:0] destReg_to_reg3 = reg3_bubble ? {REG_ADDR_WIDTH{1'b0}}  : write_to_Reg_regde;

reg3 #(.XLEN(XLEN), .NUM_REGS(NUM_REGS)) m_reg3(
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
    .hold(mem_stall),   // MEM-stage interlock (docs/adr/0013): freeze reg3 while
                        // the load it's currently holding hasn't come back from
                        // DataMemoryBRAM yet -- reg2 must not be allowed to push
                        // the next instruction in on top of it.

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

// Compiled in only with -DASSERT_ON (see sim/run_tests.sh). reg3 latches
// unconditionally every cycle for a store (its docs/adr/0013 `hold` input
// only ever fires on a load, mem_stall being gated on memRead_regem, which
// is mutually exclusive with memWrite_regem), so readData2_regem this cycle
// must equal readData2_final as it was one cycle ago. This is exactly the
// property docs/adr/0003-store-data-forwarding.md's bug violated (reg3 was
// wired to the raw readData2_regde instead of the forwarded value) --
// this assertion would have caught that wiring mistake immediately instead
// of needing a directed test (store_load.s) to stumble into it.
`ifdef ASSERT_ON
reg [XLEN-1:0] expected_store_data;
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
    // Synchronous-read BRAM (docs/adr/0013-mem-stage-retiming.md), replacing
    // the old combinational-read DataMemory.v -- readData is only valid the
    // cycle *after* a load's address/memRead are presented, which is exactly
    // what mem_stall (declared above, with the rest of the EX-stage hazard
    // logic) exists to accommodate.
    DataMemoryBRAM #(.SIZE_BYTES(MEM_SIZE_BYTES), .XLEN(XLEN), .DATA_INIT_FILE(DATA_INIT_FILE)) m_DataMemory(
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
wire [XLEN-1:0] readData_regwb;
wire [XLEN-1:0] ALUOut_regwb;
wire [XLEN-1:0] readData_regem;
wire [REG_ADDR_WIDTH-1:0] write_to_Reg_regwb;
wire [XLEN-1:0] writeData_regwb;
wire jump_regwb;
wire [XLEN-1:0] pc_plus4_regwb;

//
reg4 #(.XLEN(XLEN), .NUM_REGS(NUM_REGS)) m_reg4(
    .clk(clk),
    .rst(start),
    .memtoReg_regem(memtoReg_regem),
    .regWrite_regem(regWrite_regem),
    .readData(readData),
    .ALUOut_regem(ALUOut_regem),
    .write_to_Reg_regem(write_to_Reg_regem),
    .jump_regem(jump_regem),
    .pc_plus4_regem(pc_plus4_regem),
    .hold(mem_stall),   // MEM-stage interlock (docs/adr/0013): freeze reg4 while
                        // the load reg3 is holding hasn't come back from
                        // DataMemoryBRAM yet. A hold, not a bubble -- reg4 may
                        // currently hold an unrelated, already-complete
                        // instruction still within its MEM/WB forwarding
                        // window (needed by whatever's parked in reg2 during
                        // the stall), which must stay visible rather than
                        // being evicted a cycle early. See the ADR: an
                        // earlier bubble-based attempt broke exactly this
                        // case, caught by random cross-checking.
    .memtoReg_regwb(memtoReg_regwb),
    .regWrite_regwb(regWrite_regwb),
    .readData_regwb(readData_regwb),
    .ALUOut_regwb(ALUOut_regwb),
    .write_to_Reg_regwb(write_to_Reg_regwb),
    .jump_regwb(jump_regwb),
    .pc_plus4_regwb(pc_plus4_regwb)
);

//WRITEBACK
    wire [XLEN-1:0] writeData_regwb_mem_alu;
    Mux2to1 #(.size(XLEN)) m_Mux_WriteData(
    .sel(memtoReg_regwb),
    .s0(ALUOut_regwb),
    .s1(readData_regwb),
    .out(writeData_regwb_mem_alu)
    );

    // jal's result (PC+4) overrides the normal ALU/memory writeback value.
    Mux2to1 #(.size(XLEN)) m_Mux_WriteData_Jump(
    .sel(jump_regwb),
    .s0(writeData_regwb_mem_alu),
    .s1(pc_plus4_regwb),
    .out(writeData_regwb)
    );

    assign debug_x10 = m_Register.regs[10];

endmodule

`default_nettype wire
