/*
 * S-mode test payload entry (docs/adr/0035-minimal-sbi-firmware-phase-s.md).
 * Linked at PAYLOAD_BASE (link_sbi.ld) -- boot.S's own mret lands here with
 * a0=hart id, a1=DTB physical address, exactly the real kernel entry
 * convention this phase's own research confirmed. Passed straight through
 * to payload_main() untouched.
 */
    .section .text.payload
    .globl _payload_start
_payload_start:
    la      sp, _stack_top
    call    payload_main
halt_payload:
    j       halt_payload
