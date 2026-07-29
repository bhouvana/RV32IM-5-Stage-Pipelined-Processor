`default_nettype none

`include "riscv_defs.vh"

// Machine-mode-only CSR file (docs/adr/0011-csr-and-exceptions.md), plus
// (docs/adr/0019-f-extension.md, Phase C8) the F-extension's fflags/frm/
// fcsr. Seven CSRs total: mstatus (MIE/MPIE only -- no S/U mode, so every
// other field is hardwired 0), mtvec, mscratch, mepc, mcause, fflags, frm
// (fcsr is not separate storage -- it's just {frm, fflags} packed into one
// address, same "one more view onto the same bits" relationship the real
// spec defines). No S-mode/U-mode, no PMP, no real interrupts (this design
// has no interrupt input lines) -- this exists to handle and return from
// the three synchronous exceptions this core can raise (illegal
// instruction, ecall, ebreak), not to be a spec-complete privileged
// architecture.
module CSR #(
    parameter XLEN = 32   // docs/adr/0015-xlen-and-regcount-parameterization.md.
                            // csr_addr stays a fixed 12 bits regardless -- the
                            // CSR address space width is set by the privileged
                            // spec's encoding, not XLEN.
)(
    input clk,
    input rst,

    // csrrw/csrrs/csrrc(+immediate variants), resolved by the caller into a
    // uniform (addr, op, wdata) triple -- riscvpipeline.v handles picking
    // rs1 vs. the zero-extended uimm before this port.
    input csr_write_en,
    input [11:0] csr_addr,
    input [1:0] csr_op,      // == inst[13:12] == funct3[1:0] directly: 2'b01=write(csrrw/csrrwi)
                              // 2'b10=set(csrrs/csrrsi) 2'b11=clear(csrrc/csrrci) -- no remapping
                              // needed at the call site, riscv_defs.vh's CSR_F3_* already follow
                              // this same low-2-bits pattern
    input [XLEN-1:0] csr_wdata,
    output reg [XLEN-1:0] csr_rdata,  // current value at csr_addr, combinational (old value, for rd)

    input trap_taken,
    input [XLEN-1:0] trap_pc,     // faulting instruction's own PC -> mepc
    input [XLEN-1:0] trap_cause,  // -> mcause

    input mret_taken,

    // docs/adr/0019-f-extension.md (Phase C8). Sticky hardware accumulation:
    // every F-extension instruction that actually executes ORs its own
    // exception flags into fflags this same cycle, independent of (and, in
    // legitimate operation, never simultaneous with -- isOpFp_regde/isCsr_regde
    // are mutually exclusive opcodes) an explicit software csrrX write to
    // the same address below. frm_val is the live rounding mode, read by
    // riscvpipeline.v to resolve any instruction whose own rm field is
    // RM_DYN (3'b111) before it ever reaches FALU.v/FMADDUnit.v/FDivider.v/
    // FSqrt.v -- see FALU.v's own header comment for why those modules
    // themselves only ever see an already-resolved rm.
    input fp_flags_we,
    input [4:0] fp_flags_in,
    output [2:0] frm_val,

    output [XLEN-1:0] mtvec_val,  // trap target for the redirect mux
    output [XLEN-1:0] mepc_val    // mret target for the redirect mux
);

    reg [XLEN-1:0] mstatus;  // only bit3 (MIE) and bit7 (MPIE) are real; rest hardwired 0
    reg [XLEN-1:0] mtvec;
    reg [XLEN-1:0] mscratch;
    reg [XLEN-1:0] mepc;
    reg [XLEN-1:0] mcause;
    reg [4:0] fflags;  // {NV, DZ, OF, UF, NX} -- sticky, OR-accumulated, not overwritten by hardware
    reg [2:0] frm;

    assign mtvec_val = mtvec;
    assign mepc_val = mepc;
    assign frm_val = frm;

    always @(*) begin
        case (csr_addr)
            `CSR_ADDR_MSTATUS:  csr_rdata = mstatus;
            `CSR_ADDR_MTVEC:    csr_rdata = mtvec;
            `CSR_ADDR_MSCRATCH: csr_rdata = mscratch;
            `CSR_ADDR_MEPC:     csr_rdata = mepc;
            `CSR_ADDR_MCAUSE:   csr_rdata = mcause;
            `CSR_ADDR_FFLAGS:   csr_rdata = {{(XLEN-5){1'b0}}, fflags};
            `CSR_ADDR_FRM:      csr_rdata = {{(XLEN-3){1'b0}}, frm};
            `CSR_ADDR_FCSR:     csr_rdata = {{(XLEN-8){1'b0}}, frm, fflags};
            default:            csr_rdata = {XLEN{1'b0}};  // unimplemented CSR reads as 0 rather than trapping
        endcase
    end

    wire [XLEN-1:0] new_val = (csr_op == 2'b10) ? (csr_rdata | csr_wdata) :   // csrrs: set
                               (csr_op == 2'b11) ? (csr_rdata & ~csr_wdata) : // csrrc: clear
                                                   csr_wdata;                 // csrrw (2'b01): write

    // Only bits 3 (MIE) and 7 (MPIE) of mstatus are real; every other bit is
    // hardwired 0 regardless of XLEN (this core has no S/U mode, FPU, etc.
    // to back the rest of the real mstatus layout).
    wire [XLEN-1:0] mstatus_masked = ({XLEN{1'b0}} | (new_val[3] << 3) | (new_val[7] << 7));

    always @(posedge clk) begin
        if (~rst) begin
            mstatus  <= {XLEN{1'b0}};
            mtvec    <= {XLEN{1'b0}};
            mscratch <= {XLEN{1'b0}};
            mepc     <= {XLEN{1'b0}};
            mcause   <= {XLEN{1'b0}};
            fflags   <= 5'b0;
            frm      <= 3'b0;
        end
        else begin
            // Independent of the trap/mret/csrrX chain below: fflags is
            // sticky hardware-accumulated state, set as a side effect of
            // *every* F-extension instruction retiring (docs/adr/0019
            // Phase C8), not something only a real csrrX instruction can
            // change. Never actually simultaneous with the CSR_ADDR_FFLAGS
            // write case in the chain below (an instruction is either a
            // float op or a real csrrX op, never both), so there's no
            // meaningful precedence to reason about between the two.
            if (fp_flags_we)
                fflags <= fflags | fp_flags_in;

            if (trap_taken) begin
                mepc   <= trap_pc;
                mcause <= trap_cause;
                mstatus[7] <= mstatus[3];  // MPIE <= MIE
                mstatus[3] <= 1'b0;        // MIE  <= 0 (traps disabled while handling this one)
            end
            else if (mret_taken) begin
                mstatus[3] <= mstatus[7];  // MIE  <= MPIE
                mstatus[7] <= 1'b1;        // MPIE <= 1 (spec default)
            end
            else if (csr_write_en) begin
                case (csr_addr)
                    `CSR_ADDR_MSTATUS:  mstatus  <= mstatus_masked;  // only MIE/MPIE are real
                    `CSR_ADDR_MTVEC:    mtvec    <= new_val;
                    `CSR_ADDR_MSCRATCH: mscratch <= new_val;
                    `CSR_ADDR_MEPC:     mepc     <= new_val;
                    `CSR_ADDR_MCAUSE:   mcause   <= new_val;
                    `CSR_ADDR_FFLAGS:   fflags   <= new_val[4:0];
                    `CSR_ADDR_FRM:      frm      <= new_val[2:0];
                    `CSR_ADDR_FCSR:     {frm, fflags} <= new_val[7:0];
                    default: ; // unimplemented CSR writes are silently dropped, not trapped
                endcase
            end
        end
    end

endmodule

`default_nettype wire
