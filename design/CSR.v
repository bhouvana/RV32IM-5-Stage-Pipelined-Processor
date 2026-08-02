`default_nettype none

`include "riscv_defs.vh"

// Machine-mode-only CSR file (docs/adr/0011-csr-and-exceptions.md), plus
// (docs/adr/0019-f-extension.md, Phase C8) the F-extension's fflags/frm/
// fcsr, plus (docs/adr/0020-soc-integration.md, Phase D7) mie/mip. Nine
// CSRs total: mstatus (MIE/MPIE only -- no S/U mode, so every other field
// is hardwired 0), mie, mtvec, mscratch, mepc, mcause, mip, fflags, frm
// (fcsr is not separate storage -- it's just {frm, fflags} packed into one
// address, same "one more view onto the same bits" relationship the real
// spec defines). No S-mode/U-mode, no PMP -- this core is M-mode only
// throughout, same scope docs/adr/0011 originally drew for exceptions, now
// extended to the two interrupt sources docs/adr/0020 adds (a timer and
// one external device, UART RX) rather than a spec-complete privileged
// architecture.
//
// mie/mip only ever have two real bits each (`MIE_MTIE_BIT`/`MIE_MEIE_BIT`,
// riscv_defs.vh) -- machine software-interrupt (MSIP) is not implemented
// (no second hart exists to send one), and no S-mode/U-mode delegation
// bits exist either. mip is read-only from software's perspective (its
// two real bits, MTIP/MEIP, are hardware-driven straight from
// Timer.v's/the PLIC-lite's own live pending signals -- see
// `timer_pending`/`ext_pending` below); a csrrX write to its address is
// silently dropped, the same "unimplemented CSR writes are silently
// dropped" default every other unimplemented address already gets.
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
    input [XLEN-1:0] trap_pc,     // faulting instruction's own PC (exception) or the PC of the
                                    // instruction that would have executed next (interrupt) -> mepc
    input [XLEN-1:0] trap_cause,  // low bits only (never bit31 set) -> mcause[30:0]
    // docs/adr/0020-soc-integration.md (Phase D9). Set by riscvpipeline.v's
    // interrupt_taken exactly when this trap is an interrupt rather than a
    // synchronous exception -> mcause[31], the spec's own
    // interrupt-vs-exception disambiguating bit. trap_cause's low bits are
    // already the correct code either way (riscv_defs.vh's MCAUSE_* and
    // MCAUSE_INT_* deliberately share the low-bit numbering space, per
    // their own header comment) -- this bit is the only thing that tells
    // them apart.
    input trap_is_interrupt,
    // docs/adr/00NN-mmu-sv32.md (Phase F3). The faulting virtual address,
    // for mtval/stval -- 0 for every cause this phase itself raises (a
    // spec-legal choice; mtval's content for non-page-fault causes is
    // implementation-defined and this core simply doesn't bother). F5
    // wires the real value in for page faults with zero further changes
    // needed here, the same tie-off-then-real-wire staging D7/D8 used for
    // timer_pending/ext_pending.
    input [XLEN-1:0] trap_value,

    input mret_taken,
    input sret_taken,  // docs/adr/00NN-mmu-sv32.md (Phase F3) -- riscvpipeline.v
                         // gates this off before it ever reaches here (see
                         // sret_real there), same as mret_taken already is

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

    // docs/adr/0020-soc-integration.md (Phase D7/D8). Live hardware pending
    // state -- Timer.v's own `pending` output and the PLIC-lite's single
    // external source (Uart.v's `rx_irq`) -- feeding mip's two real,
    // read-only bits. Tied to 1'b0 by riscvpipeline.v until D8 wires the
    // real peripherals in; CSR.v's own interface needs no further changes
    // at that point.
    input timer_pending,
    input ext_pending,

    // docs/adr/0020-soc-integration.md (Phase D9). Consumed by
    // riscvpipeline.v's interrupt-detection condition (mstatus_mie &
    // ((mip.MEIP & mie.MEIE) | (mip.MTIP & mie.MTIE))) -- CSR.v's own
    // interface needed no further changes to support it, exactly as D7
    // anticipated.
    output mstatus_mie,  // mstatus[3], the global trap/interrupt enable
    output mie_mtie,     // mie's machine-timer-interrupt enable bit
    output mie_meie,     // mie's machine-external-interrupt enable bit

    output [XLEN-1:0] mtvec_val,  // trap target for the redirect mux
    output [XLEN-1:0] mepc_val,   // mret target for the redirect mux

    // Phase F of the redesign (docs/adr/00NN-mmu-sv32.md; docs/adr/0011/0020
    // both explicitly deferred this).
    output [1:0] priv_mode_val,   // current privilege -- PRIV_U/PRIV_S/PRIV_M
    // docs/adr/00NN-mmu-sv32.md (Phase F3). stvec_val/sepc_val mirror
    // mtvec_val/mepc_val for the S-mode redirect targets; trap_target_is_s
    // tells riscvpipeline.v's redirect mux which pair to use for THIS
    // trap, computed here (not there) since the decision needs mideleg/
    // medeleg/priv_mode, all of which already live in this module.
    output [XLEN-1:0] stvec_val,
    output [XLEN-1:0] sepc_val,
    output trap_target_is_s
);

    reg [XLEN-1:0] mstatus;  // bit3(MIE)/bit7(MPIE) real since docs/adr/0011; bit1(SIE)/bit5(SPIE)/
                               // bit8(SPP)/bits12:11(MPP) real as of this phase (F1) -- see mstatus_masked
    reg [XLEN-1:0] mie;      // MIE_MTIE_BIT/MIE_MEIE_BIT real since D7; MIE_SSIE_BIT/MIE_STIE_BIT/
                               // MIE_SEIE_BIT real as of this phase -- see mie_masked
    reg [XLEN-1:0] mtvec;
    reg [XLEN-1:0] mscratch;
    reg [XLEN-1:0] mepc;
    reg [XLEN-1:0] mcause;
    reg [4:0] fflags;  // {NV, DZ, OF, UF, NX} -- sticky, OR-accumulated, not overwritten by hardware
    reg [2:0] frm;

    // Phase F additions (storage only in this commit -- see the module
    // header/priv_mode_val's own comment above). sstatus/sie/sip are
    // deliberately NOT separate storage -- read/write VIEWS onto mstatus/
    // mie/mip's S-mode-visible bit subset, mirroring fcsr's existing
    // view-of-{frm,fflags} relationship (this IS how the real privileged
    // spec itself defines sstatus's relationship to mstatus, not a
    // shortcut taken here). mtval is new M-mode storage (this core never
    // implemented it before -- a real page fault, added in F5, is the
    // first thing that actually needs it).
    reg [1:0] priv_mode;      // PRIV_U/PRIV_S/PRIV_M -- reset to PRIV_M (spec boot behavior);
                               // held at PRIV_M until F3 adds mret/sret/trap-entry mutation
    reg [XLEN-1:0] sscratch;
    reg [XLEN-1:0] sepc;
    reg [XLEN-1:0] scause;
    reg [XLEN-1:0] stval;
    reg [XLEN-1:0] mtval;
    reg [XLEN-1:0] stvec;
    reg [XLEN-1:0] satp;
    reg [XLEN-1:0] mideleg;  // only the two real interrupt causes (bits 7/11, matching mie/mip's
                               // own MIE_MTIE_BIT/MIE_MEIE_BIT) are meaningful; every other bit
                               // reads/writes as 0 since no other interrupt source exists
    reg [XLEN-1:0] medeleg;  // exception causes; every bit this core can actually raise
                               // (illegal instruction, breakpoint, ecall from U/S, the three
                               // page faults) is independently delegable per spec

    // mip: bits 7(MTIP)/11(MEIP) stay exactly as before this phase --
    // read-only, hardware-driven straight from Timer.v/the PLIC-lite,
    // never software-writable. Phase F adds three more real bits, but
    // unlike MTIP/MEIP these ARE software-writable per spec (a real
    // platform's own S-level software/timer/external interrupt sources are
    // conventionally driven by software -- e.g. M-mode's own trap handler
    // -- not fixed hardware the way this core's one real timer/UART are).
    // mip_sw holds exactly those three bits (SSIP@1/STIP@5/SEIP@9); every
    // other mip bit (including the two hardware ones) is either the fixed
    // hardware OR-in below or hardwired 0.
    reg [XLEN-1:0] mip_sw;
    wire [XLEN-1:0] mip = mip_sw | (timer_pending << `MIE_MTIE_BIT) | (ext_pending << `MIE_MEIE_BIT);

    // sstatus/sie/sip: NOT separate storage -- masked VIEWS onto mstatus/
    // mie/mip's S-mode-visible bit subset (SIE@1/SPIE@5/SPP@8 of mstatus;
    // SSIE@1/STIE@5/SEIE@9 of mie; SSIP@1/STIP@5/SEIP@9 of mip), the same
    // relationship fcsr already has onto {frm,fflags}. Genuinely
    // independent bit *positions* from mstatus's own MIE@3/MPIE@7 or
    // mie/mip's own MTIE/MEIE@7/11 -- per the real privileged spec, these
    // are different, coexisting interrupt-enable/pending bits sharing one
    // physical register, not aliases of the machine-level ones.
    wire [XLEN-1:0] sstatus_view = {XLEN{1'b0}} |
        (mstatus[`MSTATUS_SPP_BIT]  << `MSTATUS_SPP_BIT) |
        (mstatus[`MSTATUS_SPIE_BIT] << `MSTATUS_SPIE_BIT) |
        (mstatus[`MSTATUS_SIE_BIT]  << `MSTATUS_SIE_BIT);
    wire [XLEN-1:0] sie_view = {XLEN{1'b0}} |
        (mie[`MIE_SEIE_BIT] << `MIE_SEIE_BIT) |
        (mie[`MIE_STIE_BIT] << `MIE_STIE_BIT) |
        (mie[`MIE_SSIE_BIT] << `MIE_SSIE_BIT);
    wire [XLEN-1:0] sip_view = {XLEN{1'b0}} |
        (mip[`MIE_SEIE_BIT] << `MIE_SEIE_BIT) |
        (mip[`MIE_STIE_BIT] << `MIE_STIE_BIT) |
        (mip[`MIE_SSIE_BIT] << `MIE_SSIE_BIT);

    assign mtvec_val = mtvec;
    assign mepc_val = mepc;
    assign frm_val = frm;
    assign mstatus_mie = mstatus[3];
    assign mie_mtie = mie[`MIE_MTIE_BIT];
    assign mie_meie = mie[`MIE_MEIE_BIT];
    assign priv_mode_val = priv_mode;
    assign stvec_val = stvec;
    assign sepc_val = sepc;

    // docs/adr/00NN-mmu-sv32.md (Phase F3). Delegation decision: a trap is
    // taken directly into S (rather than M) iff it's NOT sourced from M
    // itself (a trap that occurs while already in M is never delegated,
    // per spec -- there's nowhere lower to hand it to from M's own
    // perspective) AND the matching mideleg/medeleg bit is set. Indexed by
    // the same low 5 bits mcause itself uses (every real cause code this
    // core raises fits in 0-31); trap_is_interrupt picks which of the two
    // delegation registers applies, exactly mirroring how it already picks
    // between MCAUSE_INT_*/plain MCAUSE_* numbering for mcause itself.
    wire trap_delegated = trap_is_interrupt ? mideleg[trap_cause[4:0]] : medeleg[trap_cause[4:0]];
    assign trap_target_is_s = trap_taken && (priv_mode != `PRIV_M) && trap_delegated;

    always @(*) begin
        case (csr_addr)
            `CSR_ADDR_MSTATUS:  csr_rdata = mstatus;
            `CSR_ADDR_MIE:      csr_rdata = mie;
            `CSR_ADDR_MTVEC:    csr_rdata = mtvec;
            `CSR_ADDR_MSCRATCH: csr_rdata = mscratch;
            `CSR_ADDR_MEPC:     csr_rdata = mepc;
            `CSR_ADDR_MCAUSE:   csr_rdata = mcause;
            `CSR_ADDR_MIP:      csr_rdata = mip;
            `CSR_ADDR_FFLAGS:   csr_rdata = {{(XLEN-5){1'b0}}, fflags};
            `CSR_ADDR_FRM:      csr_rdata = {{(XLEN-3){1'b0}}, frm};
            `CSR_ADDR_FCSR:     csr_rdata = {{(XLEN-8){1'b0}}, frm, fflags};
            // Phase F additions (storage only in this commit -- see the
            // module header). sstatus/sie/sip read their masked views;
            // everything else reads its own real, independent storage.
            `CSR_ADDR_SSTATUS:  csr_rdata = sstatus_view;
            `CSR_ADDR_SIE:      csr_rdata = sie_view;
            `CSR_ADDR_SIP:      csr_rdata = sip_view;
            `CSR_ADDR_STVEC:    csr_rdata = stvec;
            `CSR_ADDR_SSCRATCH: csr_rdata = sscratch;
            `CSR_ADDR_SEPC:     csr_rdata = sepc;
            `CSR_ADDR_SCAUSE:   csr_rdata = scause;
            `CSR_ADDR_STVAL:    csr_rdata = stval;
            `CSR_ADDR_SATP:     csr_rdata = satp;
            `CSR_ADDR_MTVAL:    csr_rdata = mtval;
            `CSR_ADDR_MIDELEG:  csr_rdata = mideleg;
            `CSR_ADDR_MEDELEG:  csr_rdata = medeleg;
            default:            csr_rdata = {XLEN{1'b0}};  // unimplemented CSR reads as 0 rather than trapping
        endcase
    end

    wire [XLEN-1:0] new_val = (csr_op == 2'b10) ? (csr_rdata | csr_wdata) :   // csrrs: set
                               (csr_op == 2'b11) ? (csr_rdata & ~csr_wdata) : // csrrc: clear
                                                   csr_wdata;                 // csrrw (2'b01): write

    // Bit masks identifying exactly which mstatus/mie bits sstatus/sie
    // expose -- used for read-modify-write preservation of the machine-
    // only bits a write through the S-mode address must never touch.
    localparam [XLEN-1:0] SSTATUS_BITS = ({XLEN{1'b0}} |
        (1 << `MSTATUS_SIE_BIT) | (1 << `MSTATUS_SPIE_BIT) | (1 << `MSTATUS_SPP_BIT));
    localparam [XLEN-1:0] SIE_BITS = ({XLEN{1'b0}} |
        (1 << `MIE_SSIE_BIT) | (1 << `MIE_STIE_BIT) | (1 << `MIE_SEIE_BIT));

    // mstatus's real bits as of this phase: MIE@3/MPIE@7 (docs/adr/0011),
    // plus SIE@1/SPIE@5/SPP@8/MPP@12:11 (Phase F). Used when the write
    // targets `mstatus` directly -- every real bit can be set this way.
    wire [XLEN-1:0] mstatus_masked = ({XLEN{1'b0}} | (new_val[3] << 3) | (new_val[7] << 7) |
        (new_val[`MSTATUS_SIE_BIT]  << `MSTATUS_SIE_BIT) |
        (new_val[`MSTATUS_SPIE_BIT] << `MSTATUS_SPIE_BIT) |
        (new_val[`MSTATUS_SPP_BIT]  << `MSTATUS_SPP_BIT) |
        (new_val[12:11] << `MSTATUS_MPP_LO));

    // A write THROUGH `sstatus` (not `mstatus` directly) must only ever
    // affect the S-visible subset (SIE/SPIE/SPP) -- never MIE/MPIE/MPP,
    // even if the raw bit pattern software supplies (e.g. via csrrw, which
    // ignores the read side entirely) happens to have those bits set. Real
    // spec requirement: sstatus is a *restricted* window, not just a
    // same-bits alias with a different name.
    wire [XLEN-1:0] sstatus_write_masked = {XLEN{1'b0}} |
        (new_val[`MSTATUS_SIE_BIT]  << `MSTATUS_SIE_BIT) |
        (new_val[`MSTATUS_SPIE_BIT] << `MSTATUS_SPIE_BIT) |
        (new_val[`MSTATUS_SPP_BIT]  << `MSTATUS_SPP_BIT);

    // mie's real bits as of this phase: MTIE@7/MEIE@11 (docs/adr/0020),
    // plus SSIE@1/STIE@5/SEIE@9 (Phase F, genuinely independent bits from
    // the machine-level ones -- see mip_sw's own comment above for why).
    // Used when the write targets `mie` directly.
    wire [XLEN-1:0] mie_masked = ({XLEN{1'b0}} |
        (new_val[`MIE_MTIE_BIT] << `MIE_MTIE_BIT) | (new_val[`MIE_MEIE_BIT] << `MIE_MEIE_BIT) |
        (new_val[`MIE_SSIE_BIT] << `MIE_SSIE_BIT) | (new_val[`MIE_STIE_BIT] << `MIE_STIE_BIT) |
        (new_val[`MIE_SEIE_BIT] << `MIE_SEIE_BIT));

    // A write through `sie` must only ever affect SSIE/STIE/SEIE -- same
    // restricted-window reasoning as sstatus_write_masked above.
    wire [XLEN-1:0] sie_write_masked = {XLEN{1'b0}} |
        (new_val[`MIE_SSIE_BIT] << `MIE_SSIE_BIT) | (new_val[`MIE_STIE_BIT] << `MIE_STIE_BIT) |
        (new_val[`MIE_SEIE_BIT] << `MIE_SEIE_BIT);

    // mip_sw's three real bits (SSIP/STIP/SEIP) are the only ones software
    // can ever write, via either `mip` or `sip` -- MTIP/MEIP are never
    // storage at all (see mip_sw's own declaration above), so there's
    // nothing address-dependent to distinguish here, unlike mstatus/mie.
    wire [XLEN-1:0] mip_sw_masked = {XLEN{1'b0}} |
        (new_val[`MIE_SSIE_BIT] << `MIE_SSIE_BIT) | (new_val[`MIE_STIE_BIT] << `MIE_STIE_BIT) |
        (new_val[`MIE_SEIE_BIT] << `MIE_SEIE_BIT);

    // mideleg/medeleg: only the causes this core can actually raise are
    // real bits; everything else is hardwired 0 (mirrors mie/mip's own
    // "only the bits with a real source behind them" convention).
    // mideleg allows delegating this core's own two real hardware
    // interrupt sources (bits 7/11) directly, alongside the conventionally-
    // S-level software/timer/external bits (1/5/9) -- a real but slightly
    // non-standard choice for this core's minimal 2-source design: see
    // docs/adr/00NN-mmu-sv32.md for why (no separate S-level hardware
    // timer/external source exists, so bits 7/11 are the only way to give
    // S-mode direct access to this core's one real timer/UART interrupt).
    wire [XLEN-1:0] mideleg_masked = {XLEN{1'b0}} |
        (new_val[`MIE_SSIE_BIT] << `MIE_SSIE_BIT) | (new_val[`MIE_STIE_BIT] << `MIE_STIE_BIT) |
        (new_val[`MIE_MTIE_BIT] << `MIE_MTIE_BIT) |
        (new_val[`MIE_SEIE_BIT] << `MIE_SEIE_BIT) | (new_val[`MIE_MEIE_BIT] << `MIE_MEIE_BIT);
    wire [XLEN-1:0] medeleg_masked = {XLEN{1'b0}} |
        (new_val[2] << 2) | (new_val[3] << 3) |
        (new_val[8] << 8) | (new_val[9] << 9) | (new_val[11] << 11) |
        (new_val[12] << 12) | (new_val[13] << 13) | (new_val[15] << 15);

    always @(posedge clk) begin
        if (~rst) begin
            mstatus  <= {XLEN{1'b0}};
            mie      <= {XLEN{1'b0}};
            mtvec    <= {XLEN{1'b0}};
            mscratch <= {XLEN{1'b0}};
            mepc     <= {XLEN{1'b0}};
            mcause   <= {XLEN{1'b0}};
            fflags   <= 5'b0;
            frm      <= 3'b0;
            // Phase F additions. priv_mode resets to PRIV_M -- the spec's
            // own boot behavior (a hart always starts in machine mode) --
            // and, as of this commit (F1), is never written anywhere else;
            // F3 adds the mret/sret/trap-entry logic that actually moves
            // it. Every other new register resets to 0, same convention as
            // every existing CSR.
            priv_mode <= `PRIV_M;
            mip_sw    <= {XLEN{1'b0}};
            sscratch  <= {XLEN{1'b0}};
            sepc      <= {XLEN{1'b0}};
            scause    <= {XLEN{1'b0}};
            stval     <= {XLEN{1'b0}};
            mtval     <= {XLEN{1'b0}};
            stvec     <= {XLEN{1'b0}};
            satp      <= {XLEN{1'b0}};
            mideleg   <= {XLEN{1'b0}};
            medeleg   <= {XLEN{1'b0}};
        end
        else begin
            // docs/adr/0020-soc-integration.md (Phase D11). Each register
            // below is updated by its own independent if/else-if chain,
            // not one shared chain covering every register at once --
            // found necessary (by a real 60-seed random-cross-check
            // mismatch, not by design review) once D9 made trap_taken
            // includable for reasons entirely unrelated to whatever
            // instruction currently sits in EX (an interrupt). Before D9,
            // trap_taken/mret_taken were only ever true for the *same*
            // instruction csr_write_en could be true for, and that
            // instruction is never both (an opcode is either ecall/ebreak/
            // illegal/mret or a real csrrX, never both) -- so one shared
            // "trap_taken > mret_taken > csr_write_en" chain correctly
            // treated them as mutually exclusive. An interrupt breaks that:
            // it can fire on the exact same cycle an *unrelated*, perfectly
            // legitimate csrrX instruction elsewhere in EX is retiring its
            // own CSR write. A shared chain would silently drop that write
            // whenever a same-cycle interrupt happened to also be taken
            // (found via mcause/mstatus.MIE-swap being fine but an
            // ordinary mtvec/mscratch/fflags/frm/mie write vanishing on
            // exactly that cycle). Splitting by register fixes this while
            // preserving the *genuine* collisions (trap_taken/mret_taken
            // racing an ordinary write to the specific registers they
            // themselves also touch -- mstatus/mepc/mcause) exactly as
            // before, trap/mret still winning there.
            if (fp_flags_we)
                fflags <= fflags | fp_flags_in;
            else if (csr_write_en && (csr_addr == `CSR_ADDR_FFLAGS || csr_addr == `CSR_ADDR_FCSR))
                fflags <= new_val[4:0];

            if (csr_write_en && csr_addr == `CSR_ADDR_FRM)
                frm <= new_val[2:0];
            else if (csr_write_en && csr_addr == `CSR_ADDR_FCSR)
                frm <= new_val[7:5];

            // docs/adr/00NN-mmu-sv32.md (Phase F3). trap_taken now splits
            // on trap_target_is_s -- a trap delegated to S touches
            // sepc/scause/stval/mstatus's S-half instead of M's. mepc/
            // mcause/mtval themselves are UNTOUCHED by a delegated trap
            // (real spec behavior: M's own trap state is only ever
            // updated by a trap M itself is handling), so each still
            // falls through to its own plain csrrX-write arm otherwise.
            if (trap_taken && !trap_target_is_s) begin
                mepc <= trap_pc;
            end
            else if (csr_write_en && csr_addr == `CSR_ADDR_MEPC)
                mepc <= new_val;

            if (trap_taken && !trap_target_is_s) begin
                // docs/adr/0020-soc-integration.md (Phase D9). mcause[31]
                // is the spec's interrupt-vs-exception bit; trap_cause
                // itself never sets it (riscv_defs.vh's MCAUSE_*/
                // MCAUSE_INT_* constants are all small values, well under
                // bit31).
                mcause <= {trap_is_interrupt, trap_cause[30:0]};
            end
            else if (csr_write_en && csr_addr == `CSR_ADDR_MCAUSE)
                mcause <= new_val;

            if (trap_taken && !trap_target_is_s)
                mtval <= trap_value;
            else if (csr_write_en && csr_addr == `CSR_ADDR_MTVAL)
                mtval <= new_val;

            // docs/adr/00NN-mmu-sv32.md (Phase F3). sepc/scause/stval are
            // the S-mode mirror of mepc/mcause/mtval above, touched only
            // when THIS trap is delegated -- an M-targeted trap leaves
            // them alone (they fall through to their own plain csrrX-write
            // arm, same as before this phase).
            if (trap_taken && trap_target_is_s)
                sepc <= trap_pc;
            else if (csr_write_en && csr_addr == `CSR_ADDR_SEPC)
                sepc <= new_val;

            if (trap_taken && trap_target_is_s)
                scause <= {trap_is_interrupt, trap_cause[30:0]};
            else if (csr_write_en && csr_addr == `CSR_ADDR_SCAUSE)
                scause <= new_val;

            if (trap_taken && trap_target_is_s)
                stval <= trap_value;
            else if (csr_write_en && csr_addr == `CSR_ADDR_STVAL)
                stval <= new_val;

            // docs/adr/00NN-mmu-sv32.md (Phase F3). mstatus's MIE/MPIE
            // swap (docs/adr/0011) now only fires for an M-targeted trap;
            // a delegated trap swaps SIE/SPIE instead, and both trap
            // arms additionally record the *previous* privilege (MPP for
            // M, SPP for S) so mret/sret know what to restore. mret/sret
            // restore their own half symmetrically -- MPP resets to
            // PRIV_U (spec: "the least-privileged supported mode", which
            // for this core is U) after mret; SPP is reset to 0 (U) after
            // sret too, for the same reason, though the real spec text is
            // less explicit about SPP specifically since it's a single
            // bit already fully overwritten by the next delegated trap
            // regardless.
            if (trap_taken && !trap_target_is_s) begin
                mstatus[7] <= mstatus[3];       // MPIE <= MIE
                mstatus[3] <= 1'b0;             // MIE  <= 0 (traps disabled while handling this one)
                mstatus[12:11] <= priv_mode;    // MPP  <= previous privilege
            end
            else if (trap_taken && trap_target_is_s) begin
                mstatus[`MSTATUS_SPIE_BIT] <= mstatus[`MSTATUS_SIE_BIT];  // SPIE <= SIE
                mstatus[`MSTATUS_SIE_BIT]  <= 1'b0;                        // SIE  <= 0
                mstatus[`MSTATUS_SPP_BIT]  <= priv_mode[0];  // SPP <= previous privilege (U=0/S=1 fits in 1 bit;
                                                               // never delegated when previous priv is M, see
                                                               // trap_target_is_s's own !=PRIV_M condition above)
            end
            else if (mret_taken) begin
                mstatus[3] <= mstatus[7];  // MIE  <= MPIE
                mstatus[7] <= 1'b1;        // MPIE <= 1 (spec default)
                mstatus[12:11] <= `PRIV_U; // MPP  <= U (spec: least-privileged supported mode)
            end
            else if (sret_taken) begin
                mstatus[`MSTATUS_SIE_BIT]  <= mstatus[`MSTATUS_SPIE_BIT];  // SIE  <= SPIE
                mstatus[`MSTATUS_SPIE_BIT] <= 1'b1;                         // SPIE <= 1 (spec default)
                mstatus[`MSTATUS_SPP_BIT]  <= 1'b0;                         // SPP  <= U
            end
            else if (csr_write_en && csr_addr == `CSR_ADDR_MSTATUS)
                mstatus <= mstatus_masked;  // MIE/MPIE/SIE/SPIE/SPP/MPP are real (Phase F extends this)
            // A write through `sstatus` only ever touches the S-visible
            // subset -- SIE_BITS/SSTATUS_BITS below preserve every other
            // mstatus/mie bit exactly, the same restricted-window
            // reasoning sstatus_write_masked's own comment explains.
            else if (csr_write_en && csr_addr == `CSR_ADDR_SSTATUS)
                mstatus <= (mstatus & ~SSTATUS_BITS) | sstatus_write_masked;

            // docs/adr/00NN-mmu-sv32.md (Phase F3). priv_mode itself: a
            // trap always raises it (to S if delegated, M otherwise);
            // mret/sret each restore it from their own saved field.
            // Mutually exclusive with each other by construction (a
            // single instruction is never trap-taken and mret/sret at
            // once), so a plain if/else-if chain (no `reg2_hold`
            // collision risk beyond what trap_taken/mret_taken/sret_taken
            // themselves already carry from riscvpipeline.v) is correct.
            if (trap_taken)
                priv_mode <= trap_target_is_s ? `PRIV_S : `PRIV_M;
            else if (mret_taken)
                priv_mode <= mstatus[12:11];
            else if (sret_taken)
                priv_mode <= {1'b0, mstatus[`MSTATUS_SPP_BIT]};

            // mie/mtvec/mscratch are never touched by trap_taken/mret_taken
            // at all -- no collision to arbitrate, a real csrrX write is
            // the only source, ever. (Phase F: sie is a second address that
            // reaches the same underlying `mie` storage, read-modify-write
            // preserving the machine-only bits sie itself never exposes.)
            if (csr_write_en && csr_addr == `CSR_ADDR_MIE)
                mie <= mie_masked;
            else if (csr_write_en && csr_addr == `CSR_ADDR_SIE)
                mie <= (mie & ~SIE_BITS) | sie_write_masked;

            if (csr_write_en && csr_addr == `CSR_ADDR_MTVEC)
                mtvec <= new_val;

            if (csr_write_en && csr_addr == `CSR_ADDR_MSCRATCH)
                mscratch <= new_val;

            // Phase F additions. Every one of these is a plain csrrX-only
            // write in this commit (F1) -- no trap_taken/mret_taken
            // involvement yet (that's F3's job, extending sepc/scause/
            // stval/priv_mode/mstatus's SPP-MPP swap the same way mepc/
            // mcause/mstatus's own MIE-MPIE swap already work). mip_sw is
            // reachable via either `mip` or `sip`'s own address -- both
            // ever only touch the same three real bits, so no
            // read-modify-write preservation is needed the way mstatus/mie
            // need for sstatus/sie (see mip_sw_masked's own comment).
            if (csr_write_en && (csr_addr == `CSR_ADDR_MIP || csr_addr == `CSR_ADDR_SIP))
                mip_sw <= mip_sw_masked;

            if (csr_write_en && csr_addr == `CSR_ADDR_SSCRATCH)
                sscratch <= new_val;

            // sepc/scause/stval/mtval's own plain csrrX-write arms live
            // above now, folded into their trap-aware if/else-if chains
            // (docs/adr/00NN-mmu-sv32.md Phase F3) -- not repeated here.

            if (csr_write_en && csr_addr == `CSR_ADDR_STVEC)
                stvec <= new_val;

            if (csr_write_en && csr_addr == `CSR_ADDR_SATP)
                satp <= new_val;

            if (csr_write_en && csr_addr == `CSR_ADDR_MIDELEG)
                mideleg <= mideleg_masked;

            if (csr_write_en && csr_addr == `CSR_ADDR_MEDELEG)
                medeleg <= medeleg_masked;
        end
    end

endmodule

`default_nettype wire
