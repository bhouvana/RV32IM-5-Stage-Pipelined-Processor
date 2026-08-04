#ifndef SBI_H
#define SBI_H

/* Called from trap_entry.S: regs[1..31] are the interrupted code's own
 * x1..x31 (regs[0] unused, x0 is hardwired zero) -- a0..a7 are regs[10..17].
 * SBI return values are written back into regs[10]/regs[11] in place. */
void sbi_dispatch(unsigned long mcause, unsigned long *regs);

#endif
