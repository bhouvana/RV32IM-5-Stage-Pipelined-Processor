`default_nettype none

`include "riscv_defs.vh"

// Top-level integration for the 5-stage (or, under PROFILE_6STAGE_SPLIT_FETCH,
// 6-stage) RV32I+M pipeline: IF -> ID -> EX -> MEM -> WB, connected by
// reg1/reg2/reg3/reg4 (plus reg1a under the split-fetch profile). Forwarding
// (Forward.v) and load-use hazard detection (Hazard.v, or HazardNoForward.v
// under the alternate strategy) resolve RAW hazards; EX-stage branch/jump
// resolution, CSR/exception traps, and mret all redirect through the same
// `unconditional_redirect`/`branch_taken` squash machinery. See
// docs/ARCHITECTURE.md sec 1 for the block diagram this module implements,
// and the module inventory table (sec 2) for what each instantiated module
// below does.
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
    parameter PIPELINE_PROFILE = 0,
    // docs/adr/0020-soc-integration.md (Phase D5). Uart.v's bit-shift-timing
    // divisor -- small by default so every existing/simulation test stays
    // fast (the framing logic itself doesn't care about the actual value,
    // only that it counts correctly, so a small divisor is just as valid a
    // correctness test as a realistic one). A real FPGA target instantiation
    // would override this to match a real baud rate against a real clock
    // frequency (e.g. 115200 baud at 50MHz needs 434).
    parameter UART_CLKS_PER_BIT = 4,
    // docs/adr/0021-branch-prediction.md (Phase E). A closed, named enum
    // (same docs/adr/0015 honesty convention as PIPELINE_PROFILE/
    // HAZARD_STRATEGY above -- never a free integer). PREDICTOR_STATIC (0,
    // default): today's exact behavior, unchanged and bit-exact forever --
    // fetch always guesses "not taken," every taken branch/jal/jalr/trap/
    // mret costs a fixed 2-bubble squash, discovered only once EX resolves
    // it. PREDICTOR_DYNAMIC_BHT_BTB (1): a per-PC 2-bit-saturating-counter
    // branch-history table (Bht.v) plus a branch-target buffer (Btb.v) let
    // fetch speculatively redirect *before* EX resolves anything; a correct
    // prediction costs zero bubbles, a misprediction still costs the same
    // 2-bubble squash as today, now discovered by comparing EX's ground-
    // truth outcome against the prediction that traveled alongside the
    // instruction, not by fetch simply never having guessed in the first
    // place. Not yet consumed anywhere as of this commit (E1).
    parameter BRANCH_PREDICTOR = 0,
    // docs/adr/0021-branch-prediction.md. Bht.v/Btb.v table size, only
    // meaningful under PREDICTOR_DYNAMIC_BHT_BTB. Must be a power of 2 (see
    // Bht.v/Btb.v's own indexing). Small by default -- this core's test
    // programs are tiny (32-instruction budget per sim/run_tests.sh), so a
    // bigger table buys nothing measurable without a benchmark large enough
    // to exercise it; a real FPGA target running larger programs could
    // override this.
    parameter BHT_BTB_ENTRIES = 32
)(
    input clk,
    input start,
    output [XLEN-1:0] debug_x10,   // read-only tap on x10/a0 (docs/adr/0012-fpga-
                                // readiness.md) -- a bare-metal test program's
                                // natural "write your result here" register
                                // under the standard RISC-V calling
                                // convention. Unused by every existing
                                // testbench (an unconnected output changes
                                // nothing about existing behavior); fpga/top.v
                                // is the first consumer.
    // docs/adr/0020-soc-integration.md (Phase D5). Real UART serial pins,
    // the same "tap for external use, unconnected changes nothing" shape
    // as debug_x10 above -- every existing testbench that doesn't
    // instantiate its own external UART peer simply leaves rx idle-high
    // (matching a real disconnected serial line) and ignores tx.
    output uart_tx,
    input  uart_rx
);
// Register-address field width, derived once and reused on every
// pipeline-register/Register.v/Forward.v/Hazard.v instantiation below.
localparam REG_ADDR_WIDTH = $clog2(NUM_REGS);

// PIPELINE_PROFILE values (docs/adr/0018-variable-pipeline-depth.md) -- named
// constants purely for readability at the generate/if sites that consume
// this parameter; not yet consumed anywhere as of this commit.
localparam PROFILE_5STAGE = 0;
localparam PROFILE_6STAGE_SPLIT_FETCH = 1;

// BRANCH_PREDICTOR values (docs/adr/0021-branch-prediction.md) -- named
// constants purely for readability at the generate/if sites that consume
// this parameter; not yet consumed anywhere as of this commit.
localparam PREDICTOR_STATIC = 0;
localparam PREDICTOR_DYNAMIC_BHT_BTB = 1;

wire branch;
wire memRead;
wire memtoReg;
wire [1:0] ALUOp;
wire memWrite;
wire ALUSrc;
wire regWrite;
wire fRegWrite;    // docs/adr/0019-f-extension.md: writes FRegister.v instead of Register.v
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
wire [XLEN-1:0] pc_speculative;  // docs/adr/0021-branch-prediction.md: pc_new, or the predictor's guessed target
wire predict_taken_if;           // live query result for whatever pc_o is fetching THIS cycle
wire [XLEN-1:0] predict_target_if;
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
wire isSret;         // docs/adr/00NN-mmu-sv32.md (Phase F2) -- no live consumer yet (F3)
wire isSfenceVma;    // docs/adr/00NN-mmu-sv32.md (Phase F2) -- no live consumer yet (F5)
wire illegalOpcode;
wire [XLEN-1:0] redirect_target;  // imm_sum (branch/jal/jalr), or mtvec/mepc on a trap/mret

// rst is active-low and synchronous: while low, every pipeline register
// and the architectural register file hold their reset values; once
// driven high the pipeline runs. (Named "start" for historical reasons --
// this file began as a single-cycle CPU template.)


 // ==========================================================================
 // IF -- Instruction Fetch
 // ==========================================================================

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
    // docs/adr/0021-branch-prediction.md (Phase E4). Speculative arm: if the
    // predictor guesses this cycle's fetch is a taken branch/jump, override
    // the default sequential `pc_new` with its guessed target -- a second
    // Mux2to1 chained in front of the pre-existing redirect mux below,
    // which keeps top priority (an authoritative EX-stage
    // redirect/misprediction-correction always wins over a stale guess).
    // Under PREDICTOR_STATIC, predict_taken_if is tied to 0 (see
    // gen_predictor/gen_no_predictor below), so this mux always selects
    // s0=pc_new -- a pure no-op, bit-exact with today's single-mux fetch.
    Mux2to1 #(.size(XLEN)) m_Mux_PC_Speculative(
        .sel(predict_taken_if),
        .s0(pc_new),
        .s1(predict_target_if),
        .out(pc_speculative)
    );
    //
    Mux2to1 #(.size(XLEN)) m_Mux_PC(
        .sel(branch_taken),   // fires on a misprediction, a trap, or mret -- all resolved in EX
                               // (PREDICTOR_STATIC: fires on any taken branch/jal/jalr instead,
                               // exactly as before this phase -- see branch_or_jump_redirect below)
        .s0(pc_speculative),
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
wire predict_taken_regfd;               // docs/adr/0021-branch-prediction.md
wire [XLEN-1:0] predict_target_regfd;

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
    // docs/adr/0021-branch-prediction.md (Phase E4). Tied to 0 rather than
    // fed the real branch_regde/zero wires: unconditional_redirect below
    // now fully covers the branch/jump redirect condition on its own
    // (branch_or_jump_redirect, folded in below) for BOTH BRANCH_PREDICTOR
    // values -- under PREDICTOR_STATIC branch_or_jump_redirect reduces to
    // exactly (branch_regde&zero)|jump_regde, the same condition this
    // module would otherwise recompute itself, so tying these off and
    // routing everything through `jump` instead is bit-exact, not just
    // convenient. Under PREDICTOR_DYNAMIC_BHT_BTB it's essential, not just
    // tidy: feeding the raw (unfiltered-by-prediction) branch_regde/zero
    // here would squash every actually-taken branch regardless of whether
    // it was correctly predicted, defeating the entire feature.
    .branch_regde(1'b0),
    .zero(1'b0),
    // Fires on a misprediction, a trap, or mret (PREDICTOR_DYNAMIC_BHT_BTB)
    // or on any taken branch/jal/jalr/trap/mret (PREDICTOR_STATIC, bit-
    // exact with pre-Phase-E behavior) -- see unconditional_redirect's own
    // definition below. ORed with redirect_squash_extend_r (docs/adr/0018),
    // which is always 0 under PROFILE_5STAGE, so this term is a genuine
    // no-op at the default profile.
    .jump(unconditional_redirect | redirect_squash_extend_r),
    // docs/adr/0021-branch-prediction.md (Phase E4). The prediction made
    // for THIS fetch (query_pc == imem_read_addr, the same address `inst`
    // came from), latched alongside it -- see predict_taken_fetch/
    // predict_target_fetch's own definitions below for the
    // PIPELINE_PROFILE-aware selection (mirrors imem_read_addr's own
    // pc_o-vs-pc_o_reg1a pattern exactly, for the same reason: under
    // PROFILE_6STAGE_SPLIT_FETCH, the prediction that mattered for this
    // specific instruction was made one cycle earlier, when reg1a's own PC
    // was live, not whatever pc_o/predict_taken_if currently is).
    .predict_taken(predict_taken_fetch),
    .predict_target(predict_target_fetch),
    .inst_regfd(inst_regfd),
    .pc_o_regfd(pc_o_regfd),
    .predict_taken_regfd(predict_taken_regfd),
    .predict_target_regfd(predict_target_regfd)
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
wire predict_taken_reg1a;               // docs/adr/0021-branch-prediction.md
wire [XLEN-1:0] predict_target_reg1a;
generate
if (PIPELINE_PROFILE == PROFILE_5STAGE) begin : gen_fetch_5stage
    assign pc_o_reg1a = pc_o;  // unused under this profile; tied off for cleanliness, not read anywhere
    assign predict_taken_reg1a = 1'b0;
    assign predict_target_reg1a = {XLEN{1'b0}};
end else begin : gen_fetch_6stage_split_fetch
    reg1a #(.XLEN(XLEN)) m_reg1a(
        .clk(clk),
        .rst(start),
        .stall(pc_stall),
        .pc_o(pc_o),
        .pc_o_reg1a(pc_o_reg1a),
        .predict_taken(predict_taken_if),
        .predict_target(predict_target_if),
        .predict_taken_reg1a(predict_taken_reg1a),
        .predict_target_reg1a(predict_target_reg1a)
    );
end
endgenerate

// docs/adr/0021-branch-prediction.md (Phase E4). Which prediction pairs
// correctly with imem_read_addr's own PIPELINE_PROFILE-aware selection
// just above -- same reasoning, same pattern: under PROFILE_5STAGE the
// live combinational query (predict_taken_if, queried this cycle at pc_o)
// is exactly the prediction that was made for whatever imem_read_addr==
// pc_o just fetched; under PROFILE_6STAGE_SPLIT_FETCH, imem_read_addr is
// reg1a's one-cycle-delayed relay of a PAST pc_o, so the prediction that
// matters is reg1a's own equally-delayed relay of that past query
// (predict_taken_reg1a), not today's live one.
wire predict_taken_fetch = (PIPELINE_PROFILE == PROFILE_5STAGE) ? predict_taken_if : predict_taken_reg1a;
wire [XLEN-1:0] predict_target_fetch = (PIPELINE_PROFILE == PROFILE_5STAGE) ? predict_target_if : predict_target_reg1a;

// docs/adr/0021-branch-prediction.md (Phase E4). The predictor itself:
// only instantiated under PREDICTOR_DYNAMIC_BHT_BTB (the unselected branch
// isn't even elaborated, same convention as HAZARD_STRATEGY/
// PIPELINE_PROFILE above) -- queried combinationally every cycle at pc_o
// (the same live PC pc_new's own Adder_1 uses, not imem_read_addr -- the
// "what should fetch do next" decision always operates on PC.v's current
// live output regardless of profile, exactly like pc_new already does;
// only the value LATCHED for later comparison needs the profile-aware
// relay above). A hit requires BOTH tables to agree there's something
// useful here: Bht.v's own direction counter predicting taken, AND
// Btb.v actually having a target on file for this PC -- a direction-only
// "taken" with no known target has nowhere useful to speculatively
// redirect to. bp_update_valid/bp_update_pc/bp_update_taken/
// bp_update_target (trained from EX's real resolution) are declared where
// desired_taken/desired_target themselves are, further below.
wire bp_update_valid;
wire [XLEN-1:0] bp_update_pc;
wire bp_update_taken;
wire [XLEN-1:0] bp_update_target;
generate
if (BRANCH_PREDICTOR == PREDICTOR_DYNAMIC_BHT_BTB) begin : gen_predictor
    wire bht_predict_taken_q;
    wire btb_hit_q;
    wire [XLEN-1:0] btb_target_q;
    Bht #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Bht(
        .clk(clk), .rst(start),
        .query_pc(pc_o), .predict_taken(bht_predict_taken_q),
        .update_valid(bp_update_valid), .update_pc(bp_update_pc), .update_taken(bp_update_taken)
    );
    Btb #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Btb(
        .clk(clk), .rst(start),
        .query_pc(pc_o), .hit(btb_hit_q), .target(btb_target_q),
        .update_valid(bp_update_valid & bp_update_taken), .update_pc(bp_update_pc), .update_target(bp_update_target)
    );
    assign predict_taken_if = bht_predict_taken_q & btb_hit_q;
    assign predict_target_if = btb_target_q;
end else begin : gen_no_predictor
    assign predict_taken_if = 1'b0;
    assign predict_target_if = {XLEN{1'b0}};
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


 // ==========================================================================
 // ID -- Instruction Decode
 // ==========================================================================
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
        .isSret(isSret),
        .isSfenceVma(isSfenceVma),
        .illegalOpcode(illegalOpcode),
        .fRegWrite(fRegWrite)
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

    // docs/adr/0019-f-extension.md (Phase C6): parallel float register file.
    // Always instantiated and always reading rs1/rs2/rs3's bit positions
    // regardless of instruction type -- harmless when unused, the same
    // convention Register.v's own readReg1/readReg2 already follow.
    // writeReg/writeData are shared verbatim with Register.v above: the two
    // files' own regWrite/fRegWrite enables are mutually exclusive by
    // construction (Control.v never sets both for the same instruction), so
    // sharing the destination-index and write-value wires is safe, not a
    // race -- exactly one of the two actually commits a write each cycle.
    wire [XLEN-1:0] freadData1, freadData2, freadData3;
    FRegister #(.XLEN(XLEN), .NUM_REGS(NUM_REGS)) m_FRegister(
        .clk(clk),
        .rst(start),
        .regWrite(fRegWrite_regwb),
        .readReg1(inst_regfd[19:15]),
        .readReg2(inst_regfd[24:20]),
        .readReg3(inst_regfd[31:27]),
        .writeReg(write_to_Reg_regwb),
        .writeData(writeData_regwb),
        .readData1(freadData1),
        .readData2(freadData2),
        .readData3(freadData3)
    );

    // Opcode/funct5 classification, ID stage (inst_regfd) -- computed
    // directly from the raw instruction bits rather than as new Control.v
    // output ports, since these are needed in more than one place (register-
    // read routing here, the conservative float-hazard stall below) and are
    // cheap, pure combinational functions of bits Control.v already receives
    // anyway. A second, one-cycle-later copy exists at the EX stage
    // (inst_regde-based, see below) for actual execution dispatch -- the
    // same "decode the same thing twice, one cycle apart" shape
    // Control.v/ALUCtrl.v already use.
    wire [6:0] opcode_fd = inst_regfd[6:0];
    wire isOpFp_fd = (opcode_fd == `OPCODE_FP);
    wire isStoreFp_fd = (opcode_fd == `OPCODE_STORE_FP);
    wire isFma_fd = (opcode_fd == `OPCODE_MADD) || (opcode_fd == `OPCODE_MSUB) ||
                    (opcode_fd == `OPCODE_NMSUB) || (opcode_fd == `OPCODE_NMADD);
    // docs/adr/0019-f-extension.md (Phase C7): which of this ID-stage
    // instruction's rs1/rs2/rs3 *positions* are float reads -- same
    // "always read, harmless when unused" convention FRegister.v's own
    // read ports already follow, so this doesn't need to sub-decode which
    // specific OP-FP sub-op actually consumes which operand. rs1 is the one
    // position that's sometimes INTEGER despite an OP-FP opcode
    // (fcvt.s.w/fcvt.s.wu/fmv.w.x) -- mirrors rs1_is_float_regde's EX-stage
    // twin below exactly, one cycle earlier.
    wire [4:0] funct5_fd = inst_regfd[31:27];
    wire rs1_is_float_fd = isOpFp_fd &&
        !(funct5_fd == `FUNCT5_FCVT_S_W || funct5_fd == `FUNCT5_FMV_W_X);
    wire rs2_is_float_fd = isOpFp_fd || isStoreFp_fd || isFma_fd;
    wire rs3_is_float_fd = isFma_fd;
    // Real, register-indexed load-use hazard for flw -- the one float
    // hazard forwarding genuinely cannot resolve (flw's loaded value isn't
    // available until MEM completes, one cycle after FForward.v's EX/MEM
    // source could supply it), exactly mirroring Hazard.v's own lw
    // load-use check one cycle upstream (isLoadFp_regde is the EX-stage,
    // inst_regde-based twin of isOpFp_fd/isStoreFp_fd/isFma_fd -- see its
    // own declaration below). Replaces C6's placeholder maximally-
    // conservative "any float write anywhere in flight" stall now that
    // FForward.v resolves every other float RAW hazard by forwarding.
    wire float_load_use_hazard = isLoadFp_regde &&
        ((rs1_is_float_fd && (write_to_Reg_regde == inst_regfd[19:15])) ||
         (rs2_is_float_fd && (write_to_Reg_regde == inst_regfd[24:20])) ||
         (rs3_is_float_fd && (write_to_Reg_regde == inst_regfd[31:27])));

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
    wire fRegWrite_regde;
    wire [1:0] ALUOp_regde;
    wire [REG_ADDR_WIDTH-1:0] writeReg_regde;
    wire [XLEN-1:0] pc_o_regde;
    wire [XLEN-1:0] readData1_regde;
    wire [XLEN-1:0] readData2_regde;
    wire [XLEN-1:0] freadData1_regde;
    wire [XLEN-1:0] freadData2_regde;
    wire [XLEN-1:0] freadData3_regde;
    wire [XLEN-1:0] imm_regde;
    wire [XLEN-1:0] inst_regde;
    wire [REG_ADDR_WIDTH-1:0] readReg1_regde;
    wire [REG_ADDR_WIDTH-1:0] readReg2_regde;
    wire [REG_ADDR_WIDTH-1:0] readReg3_regde;
    wire predict_taken_regde;               // docs/adr/0021-branch-prediction.md
    wire [XLEN-1:0] predict_target_regde;
    wire [1:0] forwardA;
    wire [1:0] forwardB;
    wire [1:0] fforwardA;
    wire [1:0] fforwardB;
    wire [1:0] fforwardC;
    wire jump_regde;
    wire jalr_regde;
    wire lui_regde;
    wire auipc_regde;
    wire isCsr_regde;
    wire isEcall_regde;
    wire isEbreak_regde;
    wire isMret_regde;
    wire isSret_regde;
    wire isSfenceVma_regde;
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
    .fRegWrite(fRegWrite),
    .writeReg(inst_regfd[11:7]),
    .funct7(funct7_control),
    .funct3(funct3_control),
    .ALUOp(ALUOp),
    .pc_o_regfd(pc_o_regfd),
    .readData1(readData1),
    .readData2(readData2),
    .freadData1(freadData1),
    .freadData2(freadData2),
    .freadData3(freadData3),
    .imm(imm),
    .inst_regfd(inst_regfd),
    .flush(flush | float_load_use_hazard),  // docs/adr/0019 (Phase C7): bubble reg2 while an flw
                                          // load-use hazard clears, same "insert a nop, real
                                          // instruction retries from IF/ID" shape as Hazard.v's own
    .branch_taken(branch_taken),
    .hold(reg2_hold),   // multi-cycle divide interlock (docs/adr/0009) OR MEM-stage
                         // interlock (docs/adr/0013) -- either way, ID/EX must not
                         // advance past the instruction reg3 isn't ready to accept yet.
    .readReg1(inst_regfd[19:15]),
    .readReg2(inst_regfd[24:20]),
    .readReg3(inst_regfd[31:27]),
    // docs/adr/0021-branch-prediction.md (Phase E4). The prediction reg1
    // already latched for this instruction, carried one more stage to EX.
    .predict_taken(predict_taken_regfd),
    .predict_target(predict_target_regfd),
    .jump(jump),
    .jalr(jalr),
    .lui(lui),
    .auipc(auipc),
    .isCsr(isCsr),
    .isEcall(isEcall),
    .isEbreak(isEbreak),
    .isMret(isMret),
    .isSret(isSret),
    .isSfenceVma(isSfenceVma),
    .illegalOpcode(illegalOpcode),

    .branch_regde(branch_regde),
    .memRead_regde(memRead_regde),
    .memtoReg_regde(memtoReg_regde),
    .memWrite_regde(memWrite_regde),
    .ALUSrc_regde(ALUSrc_regde),
    .regWrite_regde(regWrite_regde),
    .fRegWrite_regde(fRegWrite_regde),
    .ALUOp_regde(ALUOp_regde),
    .write_to_Reg_regde(write_to_Reg_regde),
    .pc_o_regde(pc_o_regde),
    .readData1_regde(readData1_regde),
    .readData2_regde(readData2_regde),
    .freadData1_regde(freadData1_regde),
    .freadData2_regde(freadData2_regde),
    .freadData3_regde(freadData3_regde),
    .imm_regde(imm_regde),
    .inst_regde(inst_regde),
    .funct7_regde(funct7_regde),
    .funct3_regde(funct3_regde),
    .readReg1_regde(readReg1_regde),
    .readReg2_regde(readReg2_regde),
    .readReg3_regde(readReg3_regde),
    .predict_taken_regde(predict_taken_regde),
    .predict_target_regde(predict_target_regde),
    .jump_regde(jump_regde),
    .jalr_regde(jalr_regde),
    .lui_regde(lui_regde),
    .auipc_regde(auipc_regde),
    .isCsr_regde(isCsr_regde),
    .isEcall_regde(isEcall_regde),
    .isEbreak_regde(isEbreak_regde),
    .isMret_regde(isMret_regde),
    .isSret_regde(isSret_regde),
    .isSfenceVma_regde(isSfenceVma_regde),
    .illegalOpcode_regde(illegalOpcode_regde)
);

wire [6:0] funct7_regde;
wire [2:0] funct3_regde;
wire [XLEN-1:0] readData1_final;
wire [XLEN-1:0] readData2_final;
wire branch_taken;
wire unconditional_redirect;  // branch/jal/jalr (mispredict-gated under docs/adr/0021) | trap | mret
// Fires on a taken branch, an unconditional jal/jalr, a synchronous
// exception, or mret -- all resolved here in EX, all squash the two
// younger in-flight instructions (see reg1.jump / reg2.branch_taken).
// docs/adr/0021-branch-prediction.md (Phase E4): unconditional_redirect's
// own definition (below, near desired_taken/mispredict) now folds the
// branch/jal/jalr condition in directly (branch_or_jump_redirect) rather
// than this wire adding (branch_regde&zero) back on top of a narrower
// unconditional_redirect the way it did before this phase -- the two
// wires are therefore now always numerically identical; kept as two names
// because every existing consumer of either already has its own settled
// meaning and comment trail, not because they differ.
assign branch_taken = unconditional_redirect;

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

// ==========================================================================
// EX -- Execute
// ==========================================================================
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

    // docs/adr/0019-f-extension.md (Phase C7): float forwarding, replacing
    // C6's maximally-conservative placeholder stall. Mirrors the integer
    // network immediately above almost exactly -- same fwd_valid/fwd_dest
    // ordering (index 0 = MEM/WB, index 1 = EX/MEM), same EX/MEM-forwarded
    // value (exmem_fwd_val is already correct for float ops unmodified:
    // jump_regem is always 0 for an F-extension instruction, so it reduces
    // to plain ALUOut_regem, which already carries fp_result via ex_result
    // -- see reg3's own instantiation below), same MEM/WB-forwarded value
    // (writeData_regwb, already generic over which register file the
    // result is destined for). Not gated by HAZARD_STRATEGY: that
    // parameter is specifically the *integer* Hazard.v/HazardNoForward.v
    // research-platform toggle (docs/adr/0016) and doesn't apply here --
    // float forwarding is unconditional, additive infrastructure per the
    // plan's own explicitly-out-of-scope note.
    FForward #(.NUM_REGS(NUM_REGS)) m_FForward(
        .readReg1_regde(readReg1_regde),
        .readReg2_regde(readReg2_regde),
        .readReg3_regde(readReg3_regde),
        .fwd_valid({fRegWrite_regem, fRegWrite_regwb}),
        .fwd_dest({write_to_Reg_regem, write_to_Reg_regwb}),
        .forwardA(fforwardA),
        .forwardB(fforwardB),
        .forwardC(fforwardC)
    );

    wire [XLEN-1:0] freadData1_final;
    wire [XLEN-1:0] freadData2_final;
    wire [XLEN-1:0] freadData3_final;
    MuxN #(.size(XLEN)) m_Mux_FPU_A(
    .sel(fforwardA),
    .s0(freadData1_regde),
    .src({exmem_fwd_val, writeData_regwb}),
    .out(freadData1_final)
    );

    MuxN #(.size(XLEN)) m_Mux_FPU_B(
    .sel(fforwardB),
    .s0(freadData2_regde),
    .src({exmem_fwd_val, writeData_regwb}),
    .out(freadData2_final)
    );

    MuxN #(.size(XLEN)) m_Mux_FPU_C(
    .sel(fforwardC),
    .s0(freadData3_regde),
    .src({exmem_fwd_val, writeData_regwb}),
    .out(freadData3_final)
    );

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

    // ==========================================================================
    // F-extension execute (docs/adr/0019-f-extension.md, Phase C6). Opcode/
    // funct5 classification, EX stage (inst_regde) -- see the ID-stage
    // (inst_regfd-based) copy above for why this is computed twice, one
    // cycle apart, rather than threaded as a dedicated Control.v output.
    // ==========================================================================
    wire [6:0] opcode_regde = inst_regde[6:0];
    wire isOpFp_regde = (opcode_regde == `OPCODE_FP);
    wire isLoadFp_regde = (opcode_regde == `OPCODE_LOAD_FP);
    wire isStoreFp_regde = (opcode_regde == `OPCODE_STORE_FP);
    wire isFma_regde = (opcode_regde == `OPCODE_MADD) || (opcode_regde == `OPCODE_MSUB) ||
                       (opcode_regde == `OPCODE_NMSUB) || (opcode_regde == `OPCODE_NMADD);
    // OP-FP's funct5 (inst[31:27]) occupies the exact bits R-type's funct7
    // does, so it's already sitting in funct7_regde's top 5 bits -- no new
    // reg2 field needed to carry it. rm (rounding mode) is likewise already
    // funct3_regde; RM_DYN (rm==111) resolution against fcsr's live frm
    // happens right below (docs/adr/0019 Phase C8) -- FALU.v/FMADDUnit.v/
    // FDivider.v/FSqrt.v all expect an already-resolved rm, by design (see
    // FALU.v's own header comment).
    wire [4:0] funct5_regde = funct7_regde[6:2];
    // docs/adr/0019-f-extension.md (Phase C9 bugfix): MADD/MSUB/NMSUB/NMADD
    // (7'b1000011/1000111/1001011/1001111) are distinguished by bits[3:2],
    // NOT bits[4:3] -- bit4 is 0 for all four, so the original [4:3] slice
    // silently aliased fmadd.s with fmsub.s (both decoded as op=00) and
    // fnmsub.s with fnmadd.s (both decoded as op=01), each pair collapsing
    // to whichever op the *lower* opcode of the pair actually meant. Found
    // building sim/tools/iss.py's independent float model (C9) -- none of
    // C6/C7/C8's directed tests happened to exercise fmsub.s/fnmsub.s/
    // fnmadd.s, only fmadd.s, which has op=00 either way and so never
    // surfaced the bug.
    wire [1:0] fma_op_regde = opcode_regde[3:2];  // negate-product/negate-addend -- see FMADDUnit.v's header comment
    // docs/adr/0019-f-extension.md (Phase C8). frm_live comes from CSR.v
    // (instantiated below); resolving RM_DYN here, once, before any FPU
    // unit sees it, is what lets every one of those modules stay ignorant
    // of `fcsr`/CSR.v entirely. Safe to apply this substitution
    // unconditionally to funct3_regde even though that same field doubles
    // as a sub-op selector for FSGNJ/FMINMAX/FCMP/FMV_X_W_FCLASS (funct3
    // values 000/001/010 there): those families never legitimately encode
    // funct3==111 (RM_DYN's own encoding) at all -- it's a reserved
    // encoding for them -- so the substitution only ever fires for
    // instructions where funct3 genuinely means "rounding mode".
    wire [2:0] fpu_rm = (funct3_regde == `RM_DYN) ? frm_live : funct3_regde;
    // rs1 is the one operand that's sometimes INTEGER despite an OP-FP
    // opcode (fcvt.s.w/fcvt.s.wu/fmv.w.x) -- rs2/rs3 are float whenever
    // they're real operands at all for this core's op set.
    wire rs1_is_float_regde = isOpFp_regde &&
        !(funct5_regde == `FUNCT5_FCVT_S_W || funct5_regde == `FUNCT5_FMV_W_X);
    wire fpu_uses_a_regde = rs1_is_float_regde || isFma_regde;
    // docs/adr/0019-f-extension.md (Phase C7): *_final (forwarded), not
    // *_regde (raw ID-latched) -- same "forwarding sits between the
    // pipeline register and the execute unit" shape readData1_final/
    // readData2_final already established for the integer file.
    wire [XLEN-1:0] fpu_operand_a = fpu_uses_a_regde ? freadData1_final : readData1_final;

    wire [31:0] falu_result;
    wire [4:0] falu_flags;
    FALU m_FALU(
        .funct5(funct5_regde),
        .funct3(fpu_rm),
        .rs2_sel(readReg2_regde),   // inst[24:20] doubles as a real rs2 index or an op-selector, same bits either way
        .a(fpu_operand_a),
        .b(freadData2_final),
        .result(falu_result),
        .flags(falu_flags)
    );

    wire [31:0] fmadd_result;
    wire [4:0] fmadd_flags;
    FMADDUnit m_FMADDUnit(
        .op(fma_op_regde),
        .rm(fpu_rm),
        .a(freadData1_final),
        .b(freadData2_final),
        .c(freadData3_final),
        .result(fmadd_result),
        .flags(fmadd_flags)
    );

    // Multi-cycle fdiv.s/fsqrt.s (docs/adr/0019 Phase C4), wired in with the
    // exact same busy/done interlock shape div_stall already established
    // above -- `start` tied to the level condition, not a pulse, relying on
    // each unit's own internal `start && !busy && !done` guard the same way
    // Divider.v's does.
    wire isFpDiv_regde = isOpFp_regde && (funct5_regde == `FUNCT5_FDIV);
    wire isFpSqrt_regde = isOpFp_regde && (funct5_regde == `FUNCT5_FSQRT);
    wire fdiv_busy, fdiv_done;
    wire [31:0] fdiv_result;
    wire [4:0] fdiv_flags;
    FDivider m_FDivider(
        .clk(clk),
        .rst(start),
        .start(isFpDiv_regde),
        .rm(fpu_rm),
        .a(fpu_operand_a),
        .b(freadData2_final),
        .busy(fdiv_busy),
        .done(fdiv_done),
        .result(fdiv_result),
        .flags(fdiv_flags)
    );
    wire fsqrt_busy, fsqrt_done;
    wire [31:0] fsqrt_result;
    wire [4:0] fsqrt_flags;
    FSqrt m_FSqrt(
        .clk(clk),
        .rst(start),
        .start(isFpSqrt_regde),
        .rm(fpu_rm),
        .a(fpu_operand_a),
        .busy(fsqrt_busy),
        .done(fsqrt_done),
        .result(fsqrt_result),
        .flags(fsqrt_flags)
    );

    // True from the cycle an fdiv.s/fsqrt.s enters EX until (not including)
    // the cycle its result becomes valid -- mirrors div_stall exactly, one
    // more OR term alongside it wherever the pipeline freezes/holds for a
    // still-computing multi-cycle EX operation.
    wire fp_stall = (isFpDiv_regde && !fdiv_done) || (isFpSqrt_regde && !fsqrt_done);

    // What the F-extension's own execute step produced this cycle,
    // regardless of which of the four units actually computed it -- muxed
    // into ex_result below alongside the existing CSR/div/ALU sources.
    // flw/fsw deliberately do NOT go through this mux: their address is
    // computed by the existing ALU path exactly like lw/sw (Control.v sets
    // ALUSrc/ALUOp for them the same way), so ALUOut already holds the right
    // value for those two ops without any change here.
    wire [31:0] fp_result = isFma_regde   ? fmadd_result :
                            isFpDiv_regde ? fdiv_result   :
                            isFpSqrt_regde? fsqrt_result  :
                                            falu_result;    // every other OP-FP op

    // docs/adr/0019-f-extension.md (Phase C8): same shape as fp_result,
    // for the exception flags each unit computed alongside its result --
    // ORed into CSR.v's sticky fflags on the exact cycle this instruction
    // actually commits (see fp_flags_we below), not before.
    wire [4:0] fp_flags = isFma_regde    ? fmadd_flags :
                          isFpDiv_regde  ? fdiv_flags   :
                          isFpSqrt_regde ? fsqrt_flags  :
                                           falu_flags;
    // isOpFp_regde covers feq.s/flt.s/fle.s/fcvt.w.s/fcvt.wu.s too (they
    // still route through FALU.v and can still raise NV/NX despite writing
    // the *integer* file) -- fmv.x.w/fmv.w.x/fclass.s also pass through
    // here but FALU.v always reports 5'b0 flags for those (pure bit
    // manipulation, nothing to flag). Gated by !reg2_hold for exactly the
    // same reason CSR.v's own csr_write_en/trap_taken/mret_taken are
    // (see m_CSR's instantiation comment below): an instruction held in EX
    // across multiple cycles (e.g. mem_stall from an unrelated older load)
    // must only commit its flags once, not once per held cycle.
    wire fp_flags_we = (isOpFp_regde || isFma_regde) && !reg2_hold;

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

    assign pc_stall = stall | div_stall | mem_stall | fp_stall | float_load_use_hazard;

    // reg2's own hold condition, factored out for reuse below (CSR.v's write
    // gating needs to know exactly the same thing reg2 does: "is this
    // instruction's stay in EX not over yet". fp_stall joins div_stall/
    // mem_stall here the same way it joins them in pc_stall above --
    // float_load_use_hazard deliberately does NOT: that stall's cause (a
    // hazard against an *older* in-flight instruction) is resolved in ID,
    // not EX, so it has no business holding reg2's own occupant in place --
    // exactly the same reasoning Hazard.v's own load-use flush/stall
    // already follows for the integer file's lw case.
    wire reg2_hold = div_stall | mem_stall | fp_stall;

    wire [XLEN-1:0] div_result = (ALUCtl == `ALUCTL_DIV || ALUCtl == `ALUCTL_DIVU) ? div_quotient : div_remainder;

    // CSR / synchronous exceptions (docs/adr/0011-csr-and-exceptions.md).
    // M-mode only -- illegal instruction, ecall, ebreak, and the
    // csrrw/csrrs/csrrc(+i) instructions plus mret to act on them. (Real
    // asynchronous interrupts -- timer and UART RX -- are a separate
    // detection point below, docs/adr/0020-soc-integration.md Phase D9.)
    // Both exception sources resolve in EX, same stage as branch/jal/jalr:
    // illegalOpcode_regde came from Control.v at decode time (an
    // unrecognized opcode, or SYSTEM/funct3=0 with an unrecognized
    // funct12), while ALUCtl==ILLEGAL is only known now, after ALUCtrl has
    // decoded a *recognized* opcode's funct7/funct3 and found no valid op.
    // docs/adr/00NN-mmu-sv32.md (Phase F3). priv_mode_w is CSR.v's own
    // live priv_mode_val output (declared as a port since F1, unconnected
    // until now). Three new privilege-violation sources, each a real
    // illegal-instruction exception, not a separate cause of its own:
    // (1) any CSR access below that CSR address's own required privilege
    // (bits[9:8] of the CSR address, per spec -- 00=U/01=S/11=M, already
    // numerically ordered so a plain `<` compare works); (2) mret executed
    // anywhere but M; (3) sret executed from U (S and M may both execute
    // it -- M-mode using sret is unusual but not spec-illegal). Without
    // these, U-mode/S-mode would not actually be a protection boundary --
    // any program could read/write mstatus/satp/mideleg/etc, or return to
    // an arbitrary privilege via mret, regardless of its own current level.
    wire csr_priv_violation = isCsr_regde & (priv_mode_w < imm_regde[9:8]);
    wire mret_priv_violation = isMret_regde & (priv_mode_w != `PRIV_M);
    wire sret_priv_violation = isSret_regde & (priv_mode_w == `PRIV_U);
    // The real mret/sret behavior (redirect via mepc/sepc, restore
    // priv_mode/mstatus) only ever applies when NOT a privilege violation
    // -- a violating mret/sret instead becomes a plain illegal-instruction
    // exception (via exception_taken below), redirecting through the
    // ordinary trap path instead of actually returning anywhere.
    wire mret_real = isMret_regde & !mret_priv_violation;
    wire sret_real = isSret_regde & !sret_priv_violation;

    wire exception_taken = illegalOpcode_regde | (ALUCtl == `ALUCTL_ILLEGAL) | isEcall_regde | isEbreak_regde |
                            csr_priv_violation | mret_priv_violation | sret_priv_violation;
    // docs/adr/00NN-mmu-sv32.md (Phase F3): ecall's cause is now
    // privilege-dependent (it was unconditionally MCAUSE_ECALL_FROM_M
    // through Phase E, since M was the only privilege that existed) --
    // every existing test still boots and stays in M throughout, so this
    // is bit-exact for all of them. The three new violation sources all
    // map to the same illegal-instruction cause an ordinary illegal
    // opcode does.
    wire [XLEN-1:0] trap_cause = (illegalOpcode_regde | (ALUCtl == `ALUCTL_ILLEGAL) |
                                   csr_priv_violation | mret_priv_violation | sret_priv_violation)
                                      ? `MCAUSE_ILLEGAL_INSTRUCTION :
                              isEbreak_regde ? `MCAUSE_BREAKPOINT :
                              isEcall_regde  ? ((priv_mode_w == `PRIV_M) ? `MCAUSE_ECALL_FROM_M :
                                                 (priv_mode_w == `PRIV_S) ? `MCAUSE_ECALL_FROM_S :
                                                                             `MCAUSE_ECALL_FROM_U) :
                              {XLEN{1'b0}};

    // docs/adr/0021-branch-prediction.md (Phase E4). Ground truth for
    // whatever branch/jal/jalr instruction is now in EX -- desired_taken/
    // desired_target are the exact same expressions this file always used
    // ((branch_regde&zero)|jump_regde, and imm_sum) before this phase,
    // simply given names so they can be compared against a prediction
    // instead of consumed directly. fallthrough reuses pc_plus4_regde
    // (already computed above for jal's own link value -- pc_o_regde+4 is
    // pc_o_regde+4 regardless of why it's needed) rather than a second,
    // redundant adder.
    wire desired_taken = (branch_regde & zero) | jump_regde;
    wire [XLEN-1:0] desired_target = imm_sum;
    wire [XLEN-1:0] fallthrough_pc_regde = pc_plus4_regde;

    // Did fetch's earlier guess (predict_taken_regde/predict_target_regde,
    // latched alongside this instruction all the way from IF, two cycles
    // ago) disagree with what actually happened? Three ways to disagree:
    // predicted taken but really wasn't (or this was never a branch/jump
    // at all -- predict_taken_regde=1 for an ordinary instruction, e.g.
    // from an aliased Bht.v/Btb.v hit, is exactly as wrong as mispredicting
    // a real branch, and this XOR catches both identically); predicted
    // not-taken but it really was; predicted taken *and* it really was, but
    // to a different target than a stale Btb.v entry guessed. Under
    // PREDICTOR_STATIC, predict_taken_regde is always 0 (riscvpipeline.v
    // never feeds reg1 anything else -- see predict_taken_fetch/
    // gen_no_predictor above), so `mispredict` collapses to exactly
    // `desired_taken` -- today's exact "squash on every taken branch/jump"
    // behavior, bit-exact. `branch_or_jump_redirect`/`branch_or_jump_target`
    // are the two values every existing consumer below actually needs;
    // `mispredict` itself is unused (harmlessly, just dead logic) under
    // PREDICTOR_STATIC.
    wire mispredict = (predict_taken_regde != desired_taken) |
                       (desired_taken & (predict_target_regde != desired_target));
    wire branch_or_jump_redirect = (BRANCH_PREDICTOR == PREDICTOR_DYNAMIC_BHT_BTB) ? mispredict : desired_taken;
    wire [XLEN-1:0] branch_or_jump_target =
        (BRANCH_PREDICTOR == PREDICTOR_DYNAMIC_BHT_BTB && !desired_taken) ? fallthrough_pc_regde : desired_target;

    // Bht.v/Btb.v training, from this same ground truth -- gated !reg2_hold
    // for exactly the same reason csr_write_en/trap_taken/mret_taken/
    // fp_flags_we already are (docs/adr/0011/0019 D9's own comment below):
    // an instruction held in EX across multiple cycles (e.g. mem_stall from
    // an unrelated older load still in MEM) must train the tables exactly
    // once, on its real resolution, not once per held cycle -- desired_taken
    // would otherwise be (harmlessly) recomputed identically each held
    // cycle, but a write-side effect like this genuinely needs the gate, the
    // same distinction CSR.v's own write logic already draws. Btb.v is
    // trained only when desired_taken (no target to record for a not-taken
    // resolution); Bht.v trains on every resolution, taken or not, so the
    // direction counter actually learns both directions.
    assign bp_update_valid = (branch_regde | jump_regde) & !reg2_hold;
    assign bp_update_pc = pc_o_regde;
    assign bp_update_taken = desired_taken;
    assign bp_update_target = desired_target;

    // docs/adr/0020-soc-integration.md (Phase D9). Interrupt detection --
    // independent of whatever instruction (if any) currently sits in EX,
    // unlike the synchronous exceptions above. mip's two real bits are
    // exactly Uart.v's rx_irq / Timer.v's pending (uart_rx_irq/
    // timer_pending_w, wired below at the bus instantiation, D5/D8); mie's
    // enable bits and mstatus.MIE are CSR.v's own live outputs (D7).
    // Spec-mandated priority when both are pending and enabled: machine-
    // external over machine-timer.
    wire mei_pending = mie_meie & uart_rx_irq;
    wire mti_pending = mie_mtie & timer_pending_w;

    // Does EX's current occupant already want to redirect PC for its own
    // reasons this cycle (a taken branch, jal/jalr, a synchronous
    // exception, or mret)? If so, defer the interrupt one cycle rather
    // than contest the same redirect_target mux this same cycle -- mip is
    // level-pending (it doesn't clear itself), so nothing is lost, only
    // recognized one cycle later once whatever's already redirecting
    // finishes. Deliberately the *pre*-interrupt value of what becomes
    // branch_taken/unconditional_redirect below, built from their raw
    // constituent signals rather than those wires themselves (referencing
    // them here would be a combinational self-reference). docs/adr/0021
    // (Phase E4): branch_or_jump_redirect replaces the old raw
    // (branch_regde&zero)|jump_regde term -- itself built from
    // predict_taken_regde/desired_taken, not interrupt_taken, so no
    // circularity is introduced.
    // docs/adr/00NN-mmu-sv32.md (Phase F3): mret_real replaces the raw
    // isMret_regde -- a privilege-violating mret doesn't itself redirect
    // via mepc (it's folded into exception_taken instead, above), so it
    // must not double-count here either. sret_real (a new redirect source
    // this phase adds) joins the same list.
    wire other_redirect_taken = branch_or_jump_redirect | exception_taken | mret_real | sret_real;

    // Gated on !pc_stall, not just !reg2_hold (docs/adr/0009/0013's
    // multi-cycle div/mem/fp interlock) -- reg1.v's own squash-on-jump
    // takes priority over its *own* stall input (see reg1.v: the
    // branch_regde&zero|jump check is tested before stall), so asserting
    // an interrupt's `jump` into reg1 during an ordinary Hazard.v load-use
    // stall (`stall`, folded into pc_stall but NOT into reg2_hold) would
    // incorrectly discard the very instruction that stall exists to hold
    // in place -- not just a multi-cycle EX operation. Found by tracing
    // reg1.v's own priority ordering before implementing this (the same
    // "found by careful tracing, not assumed" standard docs/adr/0009/0013
    // set), not by hitting the bug at runtime.
    wire interrupt_taken = mstatus_mie & (mei_pending | mti_pending) & !pc_stall & !other_redirect_taken;
    wire [XLEN-1:0] interrupt_cause = mei_pending ? `MCAUSE_INT_MACHINE_EXTERNAL : `MCAUSE_INT_MACHINE_TIMER;

    // Tracks "is reg1's current output (pc_o_regfd/inst_regfd) a real
    // fetched instruction, or a squash-produced bubble" -- mirrors reg1.v's
    // own priority ordering exactly (squash > stall-hold > fresh latch) so
    // it always agrees with what reg1 itself actually did last edge.
    // redirect_squash_extend_r joins branch_taken here for the same reason
    // reg1's own `jump` port does (docs/adr/0018): under
    // PROFILE_6STAGE_SPLIT_FETCH the squash window is one cycle longer.
    reg id_bubble_r;
    always @(posedge clk) begin
        if (~start)
            id_bubble_r <= 1'b1;  // reg1 resets to a bubble too
        else if (branch_taken | redirect_squash_extend_r)
            id_bubble_r <= 1'b1;
        else if (pc_stall)
            id_bubble_r <= id_bubble_r;  // holds, same as reg1 itself
        else
            id_bubble_r <= 1'b0;
    end

    // mepc for an interrupt is the PC of the instruction that *would have
    // executed next* -- normally reg1's current output (pc_o_regfd, the
    // ID-stage instruction about to enter EX), which this same redirect
    // squashes via reg2's own branch_taken port exactly like any other
    // redirect -- deliberately NOT pc_o_regde (EX's *current* occupant,
    // used by the exception path above): unlike a synchronous exception,
    // this instruction did nothing wrong and is left to retire normally
    // this same cycle; only what comes *after* it is deferred. Exception:
    // if reg1's current output is itself a squash-produced bubble
    // (id_bubble_r, above) rather than a real fetched instruction -- e.g.
    // the cycle right after any other taken redirect -- pc_o_regfd is a
    // meaningless 0 (reg1.v's own squash value), and the real "next
    // instruction" is instead whatever pc_o (IF's own live PC) currently
    // is, since that's exactly the address the redirect that produced the
    // bubble already retargeted fetch to. Found by tracing the bubble
    // timing through reg1.v before implementing this, the same way the
    // !pc_stall gating above was -- not something any directed test
    // happened to hit first.
    wire [XLEN-1:0] interrupt_mepc = id_bubble_r ? pc_o : pc_o_regfd;

    // csrrwi/csrrsi/csrrci (funct3[2]=1) source their write data from a
    // zero-extended 5-bit immediate sitting in rs1's *field position*
    // (inst[19:15]) rather than a real register read; csrrw/csrrs/csrrc
    // (funct3[2]=0) use the actual (forwarded) rs1 value.
    wire [XLEN-1:0] csr_wdata = funct3_regde[2] ? {{(XLEN-5){1'b0}}, inst_regde[19:15]} : readData1_final;
    wire [XLEN-1:0] csr_old_val;
    wire [XLEN-1:0] mtvec_val, mepc_val;
    wire [2:0] frm_live;  // docs/adr/0019 Phase C8 -- CSR.v's live frm, for RM_DYN resolution above

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
    // docs/adr/00NN-mmu-sv32.md (Phase F3): a privilege-violating CSR
    // access must not actually commit its write (the read side needs no
    // extra gating -- exception_taken already squashes this instruction
    // before its rd write could ever retire, see riscvpipeline.v's own
    // csr_priv_violation comment).
    .csr_write_en(isCsr_regde && !reg2_hold && !csr_priv_violation),
    .csr_addr(imm_regde[11:0]),   // ImmGen.v zero-extends inst[31:20] into imm for OPCODE_SYSTEM
    .csr_op(funct3_regde[1:0]),
    .csr_wdata(csr_wdata),
    .csr_rdata(csr_old_val),
    // docs/adr/0020-soc-integration.md (Phase D9). exception_taken and
    // interrupt_taken are mutually exclusive by construction
    // (other_redirect_taken, folded into interrupt_taken's own gating,
    // already excludes exception_taken) -- the OR below is safe, exactly
    // one of the two (or neither) is ever true on a given cycle.
    // trap_pc/trap_cause mux the same way: pc_o_regde/trap_cause for a
    // synchronous exception, interrupt_mepc/interrupt_cause for an
    // interrupt (see their own definitions above for why these two
    // deliberately differ from the exception path's values).
    .trap_taken((exception_taken && !reg2_hold) || interrupt_taken),
    .trap_pc(interrupt_taken ? interrupt_mepc : pc_o_regde),
    .trap_cause(interrupt_taken ? interrupt_cause : trap_cause),
    .trap_is_interrupt(interrupt_taken),
    // docs/adr/00NN-mmu-sv32.md (Phase F3). No real page fault exists yet
    // (F5) -- tied to 0 for now, the same tie-off-then-real-wire staging
    // D7/D8 used for timer_pending/ext_pending; CSR.v's own interface
    // needs no further changes once F5 replaces this.
    .trap_value({XLEN{1'b0}}),
    .mret_taken(mret_real && !reg2_hold),
    .sret_taken(sret_real && !reg2_hold),
    .fp_flags_we(fp_flags_we),
    .fp_flags_in(fp_flags),
    .frm_val(frm_live),
    // docs/adr/0020-soc-integration.md (Phase D8, D9). timer_pending/
    // ext_pending wired to the real Timer.v/Uart.v (PLIC-lite) live
    // signals declared below -- CSR.v's own interface needed no changes
    // for this, exactly as D7 anticipated. mstatus_mie/mie_mtie/mie_meie
    // now feed interrupt_taken's own condition above (D9).
    .timer_pending(timer_pending_w),
    .ext_pending(uart_rx_irq),
    .mstatus_mie(mstatus_mie),
    .mie_mtie(mie_mtie),
    .mie_meie(mie_meie),
    .mtvec_val(mtvec_val),
    .mepc_val(mepc_val),
    // docs/adr/00NN-mmu-sv32.md (Phase F3).
    .priv_mode_val(priv_mode_w),
    .stvec_val(stvec_val),
    .sepc_val(sepc_val),
    .trap_target_is_s(trap_target_is_s)
    );
    wire mstatus_mie, mie_mtie, mie_meie;
    wire [1:0] priv_mode_w;
    wire [XLEN-1:0] stvec_val, sepc_val;
    wire trap_target_is_s;

    // What EX "produces" this cycle: an F-extension result (docs/adr/0019)
    // on any OP-FP/FMA op -- checked first since isOpFp_regde/isFma_regde
    // are mutually exclusive with isCsr_regde/isDivRem by construction (an
    // instruction is never both) -- the CSR's old value on a real csrrX op,
    // the divider's result on div/rem (valid only when div_done, but only
    // consumed downstream on that exact cycle -- see reg3_bubble below),
    // the ALU's result otherwise (this last case is also what flw/fsw use,
    // since their address is computed by the ordinary ALU path, not routed
    // through fp_result -- see fp_result's own comment above). No
    // forwarding correction needed for CSR reads either (same reasoning as
    // lui/auipc, docs/adr/0009): ex_result is already correct by the time
    // reg3 latches it.
    wire [XLEN-1:0] ex_result = (isOpFp_regde || isFma_regde) ? fp_result :
                                 isCsr_regde ? csr_old_val : (isDivRem ? div_result : ALUOut);

    // docs/adr/0020-soc-integration.md (Phase D9). interrupt_taken joins
    // the same squash machinery jal/jalr/exception/mret already use --
    // reg1.jump/reg2.branch_taken don't need to know or care *why*
    // unconditional_redirect fired, only that it did (see reg1.v/reg2.v).
    // mtvec is a single, non-vectored trap target either way (this core
    // has no vectored-interrupt mode), so interrupt_taken shares
    // exception_taken's redirect_target arm. docs/adr/0021 (Phase E4):
    // branch_or_jump_redirect/branch_or_jump_target replace the old raw
    // jump_regde / imm_sum terms -- under PREDICTOR_STATIC these reduce to
    // exactly (branch_regde&zero)|jump_regde / imm_sum, bit-exact with
    // this file's behavior before this phase; under
    // PREDICTOR_DYNAMIC_BHT_BTB, a redirect only fires on an actual
    // misprediction, to whichever of the real target or the real
    // fall-through address the misprediction needs.
    // docs/adr/00NN-mmu-sv32.md (Phase F3): mret_real/sret_real replace
    // the raw isMret_regde (a privilege-violating mret/sret redirects via
    // exception_taken's own mtvec/stvec arm instead, never mepc/sepc --
    // see mret_real/sret_real's own definitions above). redirect_target's
    // trap arm now also picks between M's and S's vector/return-address
    // pair using CSR.v's own trap_target_is_s decision (mideleg/medeleg-
    // aware, computed there since it already owns that state) --
    // interrupt_taken shares this same delegation-aware selection, unlike
    // before this phase when it always meant mtvec unconditionally (this
    // core has no vectored-interrupt mode either way, M or S).
    assign unconditional_redirect = branch_or_jump_redirect | exception_taken | mret_real | sret_real | interrupt_taken;
    assign redirect_target = (exception_taken | interrupt_taken) ? (trap_target_is_s ? stvec_val : mtvec_val) :
                              mret_real                           ? mepc_val :
                              sret_real                           ? sepc_val :
                                                                     branch_or_jump_target;

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
wire fRegWrite_regem;
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
    // fp_stall joins div_stall here for the exact same reason: while an
    // fdiv.s/fsqrt.s is still computing, reg2/EX keeps presenting that same
    // instruction cycle after cycle, and without bubbling, reg3 would latch
    // its (fRegWrite=1) control signals on every one of those cycles too.
    wire reg3_bubble = div_stall | fp_stall;
    wire memtoReg_to_reg3      = reg3_bubble ? 1'b0 : memtoReg_regde;
    wire regWrite_to_reg3      = reg3_bubble ? 1'b0 : regWrite_regde;
    wire fRegWrite_to_reg3     = reg3_bubble ? 1'b0 : fRegWrite_regde;
    wire memRead_to_reg3       = reg3_bubble ? 1'b0 : memRead_regde;
    wire memWrite_to_reg3      = reg3_bubble ? 1'b0 : memWrite_regde;
    wire jump_to_reg3          = reg3_bubble ? 1'b0 : jump_regde;
    wire [REG_ADDR_WIDTH-1:0] destReg_to_reg3 = reg3_bubble ? {REG_ADDR_WIDTH{1'b0}}  : write_to_Reg_regde;

reg3 #(.XLEN(XLEN), .NUM_REGS(NUM_REGS)) m_reg3(
    .clk(clk),
    .rst(start),
    .memtoReg_regde(memtoReg_to_reg3),
    .regWrite_regde(regWrite_to_reg3),
    .fRegWrite_regde(fRegWrite_to_reg3),
    .memRead_regde(memRead_to_reg3),
    .memWrite_regde(memWrite_to_reg3),
    .ALUOut(ex_result),
    // Store data must come from the forwarded value for both sw
    // (readData2_final) and fsw (freadData2_final, forwarded by FForward.v
    // since Phase C7) -- docs/adr/0003's lesson (store data is a separate
    // path to reg3/DataMemory, easy to silently leave on the raw/stale
    // decode-stage value) applies to the float case just as much as the
    // original integer one it was found for.
    .readData2_regde(isStoreFp_regde ? freadData2_final : readData2_final),
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
    .fRegWrite_regem(fRegWrite_regem),
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
// must equal (readData2_final, or fsw's freadData2_final -- see reg3's own
// instantiation above) as it was one cycle ago. This is exactly the
// property docs/adr/0003-store-data-forwarding.md's bug violated (reg3 was
// wired to the raw readData2_regde instead of the forwarded value) --
// this assertion would have caught that wiring mistake immediately instead
// of needing a directed test (store_load.s) to stumble into it.
`ifdef ASSERT_ON
reg [XLEN-1:0] expected_store_data;
always @(posedge clk) begin
    expected_store_data <= (isStoreFp_regde ? freadData2_final : readData2_final);
    if (start && memWrite_regem && (readData2_regem !== expected_store_data))
        begin
            $display("ASSERTION FAILED @t=%0t: reg3 store-data mismatch: readData2_regem=%0d, expected (last cycle's forwarded readData2_final)=%0d",
                      $time, readData2_regem, expected_store_data);
            $finish;
        end
end
`endif

// ==========================================================================
// MEM -- Memory Access
// ==========================================================================
    // docs/adr/0020-soc-integration.md (Phase D3). The LSU-to-bus
    // translation ("WbMaster") is plain combinational wiring here rather
    // than its own module -- it's a direct level-based re-expression of
    // signals riscvpipeline.v already has (memRead_regem/memWrite_regem/
    // ALUOut_regem/readData2_regem/funct3_regem), and this project avoids
    // introducing a module for a passthrough nothing else will ever reuse
    // (Phase B's own "avoid the premature abstraction trap" convention).
    // `lsu_sel` is derived from funct3_regem's width bits for any future
    // slave that cares about byte lanes (today's sole slave, RamWishbone-
    // Adapter, doesn't -- see its own header comment for why it takes
    // `funct3` as a side-band tag instead).
    wire lsu_cyc = memRead_regem | memWrite_regem;
    wire lsu_stb = lsu_cyc;
    wire lsu_we  = memWrite_regem;
    wire [3:0] lsu_sel = (funct3_regem[1:0] == 2'b00) ? (4'b0001 << ALUOut_regem[1:0]) :  // byte
                          (funct3_regem[1:0] == 2'b01) ? (4'b0011 << ALUOut_regem[1:0]) :  // halfword
                                                          4'b1111;                          // word
    wire lsu_ack;  // reserved for a future variable-latency-peripheral generalization --
                    // see mem_stall's own comment below for why it is deliberately NOT
                    // consumed here.

    // docs/adr/0020-soc-integration.md (Phase D8). NUM_SLAVES=3: slave 0
    // is RAM, slave 1 is Uart.v, slave 2 is Timer.v -- indices/BASE/SIZE
    // must stay in lockstep across the three flattened buses below (the
    // same convention WbDecoder.v's own header comment documents).
    wire [2:0] wb_s_cyc, wb_s_stb, wb_s_ack;
    wire wb_s_we;
    wire [XLEN-1:0] wb_s_addr, wb_s_data_o;
    wire [3:0] wb_s_sel;
    wire [3*XLEN-1:0] wb_s_data_i;

    WbDecoder #(.XLEN(XLEN), .NUM_SLAVES(3),
                .BASE({`TIMER_BASE, `UART_BASE, 32'd0}),
                .SIZE({`TIMER_SIZE, `UART_SIZE, MEM_SIZE_BYTES})) m_WbDecoder(
        .m_cyc(lsu_cyc), .m_stb(lsu_stb), .m_we(lsu_we),
        .m_addr(ALUOut_regem), .m_data_o(readData2_regem), .m_sel(lsu_sel),
        .m_data_i(readData), .m_ack(lsu_ack),
        .s_cyc(wb_s_cyc), .s_stb(wb_s_stb), .s_we(wb_s_we),
        .s_addr(wb_s_addr), .s_data_o(wb_s_data_o), .s_sel(wb_s_sel),
        .s_data_i(wb_s_data_i), .s_ack(wb_s_ack)
    );

    RamWishboneAdapter #(.SIZE_BYTES(MEM_SIZE_BYTES), .XLEN(XLEN), .DATA_INIT_FILE(DATA_INIT_FILE)) m_DataMemory(
        .clk(clk), .rst(start),
        .s_cyc(wb_s_cyc[0]), .s_stb(wb_s_stb[0]), .s_we(wb_s_we),
        .s_addr(wb_s_addr), .s_data_o(wb_s_data_o), .s_sel(wb_s_sel),
        .funct3(funct3_regem),
        .s_data_i(wb_s_data_i[0*XLEN +: XLEN]), .s_ack(wb_s_ack[0])
    );

    wire uart_rx_irq;  // docs/adr/0020 Phase D8: the PLIC-lite's sole external source -> mip.MEIP
    Uart #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) m_Uart(
        .clk(clk), .rst(start),
        .s_cyc(wb_s_cyc[1]), .s_stb(wb_s_stb[1]), .s_we(wb_s_we),
        .s_addr(wb_s_addr), .s_data_o(wb_s_data_o), .s_sel(wb_s_sel),
        .s_data_i(wb_s_data_i[1*XLEN +: XLEN]), .s_ack(wb_s_ack[1]),
        .tx(uart_tx), .rx(uart_rx), .rx_irq(uart_rx_irq)
    );

    wire timer_pending_w;  // docs/adr/0020 Phase D8: -> mip.MTIP
    Timer #(.XLEN(XLEN)) m_Timer(
        .clk(clk), .rst(start),
        .s_cyc(wb_s_cyc[2]), .s_stb(wb_s_stb[2]), .s_we(wb_s_we),
        .s_addr(wb_s_addr), .s_data_o(wb_s_data_o), .s_sel(wb_s_sel),
        .s_data_i(wb_s_data_i[2*XLEN +: XLEN]), .s_ack(wb_s_ack[2]),
        .pending(timer_pending_w)
    );
//
wire memtoReg_regwb;
wire regWrite_regwb;
wire fRegWrite_regwb;
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
    .fRegWrite_regem(fRegWrite_regem),
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
    .fRegWrite_regwb(fRegWrite_regwb),
    .readData_regwb(readData_regwb),
    .ALUOut_regwb(ALUOut_regwb),
    .write_to_Reg_regwb(write_to_Reg_regwb),
    .jump_regwb(jump_regwb),
    .pc_plus4_regwb(pc_plus4_regwb)
);

// ==========================================================================
// WB -- Writeback
// ==========================================================================
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
