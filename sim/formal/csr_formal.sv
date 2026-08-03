`include "CSR.v"

// docs/adr/0027-formal-verification.md (Phase L3). Formal harness for
// design/CSR.v's own trap-entry/exit privilege-swap logic -- fully
// self-contained (zero submodule instantiations, confirmed by grep), so
// no blackboxing is needed; every other CSR.v port not relevant to this
// property (fp_flags_*, the HPC event pulses, satp/mtvec/mepc/etc.) is
// left completely free, exactly as a real caller's own inputs would be.
//
// Uses real SVA `|=>` (non-overlapping implication) + `$past` rather than
// hand-rolled shadow registers -- an earlier version of this harness used
// manually-updated "_prev" shadow regs compared against current output
// wires, which produced a spurious counterexample traced (via a parallel
// iverilog -g2012 run of SBY's own generated counterexample testbench)
// to a same-time-step read/settle ordering mismatch between a shadow reg
// (updated in one always block) and a continuous `assign` output driven
// from a reg updating in a DIFFERENT always block the same edge -- not a
// real RTL bug. `|=>`/$past are the standard SVA idiom for exactly this
// "check next cycle" relationship and sidestep that whole class of
// self-inflicted timing confusion.
//
// Properties (the priority order mirrors CSR.v's own single trap_taken >
// mret_taken > sret_taken else-if chain exactly): M-mode trap entry swaps
// MIE->MPIE and clears MIE, records the previous privilege into MPP, and
// moves priv_mode to M; a delegated S-mode trap does the identical swap
// on SIE/SPIE/SPP instead, moving priv_mode to S; `mret` restores MIE
// from MPIE (spec default MPIE=1 after) and restores priv_mode from MPP;
// `sret` does the identical restore via SIE/SPIE/SPP; and -- the real
// invariant tying all four together -- priv_mode never changes on any
// other cycle.
module csr_formal (
    input clk, rst,
    input csr_write_en,
    input [11:0] csr_addr,
    input [1:0] csr_op,
    input [31:0] csr_wdata,
    output [31:0] csr_rdata,
    input trap_taken,
    input [31:0] trap_pc,
    input [31:0] trap_cause,
    input trap_is_interrupt,
    input [31:0] trap_value,
    input mret_taken,
    input sret_taken,
    input fp_flags_we,
    input [4:0] fp_flags_in,
    output [2:0] frm_val,
    input timer_pending,
    input ext_pending,
    output mstatus_mie, mie_mtie, mie_meie,
    output mstatus_mpie, mstatus_sie, mstatus_spie, mstatus_spp,
    output [1:0] mstatus_mpp,
    output [31:0] mtvec_val, mepc_val,
    output [1:0] priv_mode_val,
    output [31:0] stvec_val, sepc_val,
    output trap_target_is_s,
    output satp_mode_val,
    output [21:0] satp_ppn_val,
    input instret_pulse, branch_retired_pulse, mispredict_pulse,
    input icache_hit_pulse, icache_miss_pulse, dcache_hit_pulse, dcache_miss_pulse,
    input stall_cycle_pulse, interrupt_pulse, exception_pulse,
    input stall_hazard_pulse, stall_div_pulse, stall_mem_pulse, stall_fp_pulse,
    input stall_float_lu_pulse, stall_itlb_pulse, stall_dtlb_pulse, stall_icache_pulse,
    input stall_imem_wait_pulse
);
    CSR #(.XLEN(32)) dut (.*);

    // Real integration contract (riscvpipeline.v never issues a CSR write
    // from the same cycle it also raises trap_taken/mret_taken/
    // sret_taken -- a trap preempts whatever instruction was in flight,
    // including a csrrX), not an arbitrary CSR.v-in-isolation guarantee.
    // Confirmed necessary by running: without this, the solver found a
    // real counterexample where csr_write_en targeting MSTATUS fires the
    // same cycle as trap_taken, and CSR.v's own priority chain (trap_taken
    // wins) doesn't defend bit-by-bit against a simultaneous raw overwrite
    // the same cycle -- a combination this module's real caller already
    // prevents structurally, so constraining the environment to match
    // reality (not fuzzing an impossible external combination) is the
    // correct fix, not an RTL change.
    // Also: exactly one EX-stage instruction exists per cycle, so
    // trap_taken/mret_taken/sret_taken (all sourced from that same single
    // instruction's own redirect decision) are pairwise mutually
    // exclusive -- never an arbitrary free combination.
    always @(*) begin
        if (trap_taken || mret_taken || sret_taken)
            assume (!csr_write_en);
        assume ($onehot0({trap_taken, mret_taken, sret_taken}));
    end

    reg past_valid;
    initial past_valid = 1'b0;
    always @(posedge clk) past_valid <= 1'b1;

    // Yosys's SVA subset here supports neither `default clocking`/`default
    // disable iff`, nor module-level named `property ... endproperty`
    // declarations, nor the `|=>`/`->` implication operators themselves
    // (all confirmed by running -- syntax errors on each) -- only plain
    // immediate assertions using $past() and ordinary boolean operators
    // (confirmed working via a minimal isolated test before rewriting this
    // file). `rst && $past(rst)` -- reset held stable across BOTH the
    // triggering cycle and this one -- replaces what `disable iff` would
    // otherwise have expressed.
    always @(posedge clk) begin
        if (rst && $past(rst) && past_valid) begin
            if ($past(trap_taken) && !$past(trap_target_is_s)) begin
                assert (mstatus_mpie == $past(mstatus_mie));  // MPIE <= MIE
                assert (!mstatus_mie);                         // MIE  <= 0
                assert (mstatus_mpp == $past(priv_mode_val));  // MPP  <= previous priv
                assert (priv_mode_val == `PRIV_M);
            end
            else if ($past(trap_taken) && $past(trap_target_is_s)) begin
                assert (mstatus_spie == $past(mstatus_sie));      // SPIE <= SIE
                assert (!mstatus_sie);                             // SIE  <= 0
                assert (mstatus_spp == $past(priv_mode_val[0]));  // SPP  <= previous priv
                assert (priv_mode_val == `PRIV_S);
            end
            else if ($past(mret_taken)) begin
                assert (mstatus_mie == $past(mstatus_mpie));  // MIE  <= MPIE
                assert (mstatus_mpie);                          // MPIE <= 1 (spec default)
                assert (priv_mode_val == $past(mstatus_mpp)); // priv_mode <= MPP
            end
            else if ($past(sret_taken)) begin
                assert (mstatus_sie == $past(mstatus_spie));  // SIE  <= SPIE
                assert (mstatus_spie);                          // SPIE <= 1 (spec default)
                assert (priv_mode_val == {1'b0, $past(mstatus_spp)}); // priv_mode <= SPP
            end
            else begin
                // No trap/mret/sret last cycle: priv_mode must not drift
                // on its own -- the real invariant tying all four cases
                // together (privilege only ever changes via one of them).
                assert (priv_mode_val == $past(priv_mode_val));
            end
        end
    end

endmodule
