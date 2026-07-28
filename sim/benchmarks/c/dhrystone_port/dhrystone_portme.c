/*
 * Port layer for riscv-tests' Dhrystone on this core (docs/ROADMAP.md
 * Phase 10), mirroring sim/benchmarks/c/coremark_port/: dhrystone.c and
 * dhrystone_main.c (the actual Dhrystone 2.1 algorithm, Proc_1..Proc_8/
 * Func_1..Func_3) are used completely unmodified; only what they need
 * from the environment is supplied here.
 *
 * Timing: dhrystone.h's own `#elif defined(__riscv)` branch (reached
 * automatically -- __riscv is predefined by the compiler for this target,
 * and neither TIME nor MSC_CLOCK is defined) expands
 * `Start_Timer()`/`Stop_Timer()` to `read_csr(mcycle)`. This core's
 * design/CSR.v has no mcycle counter (docs/ROADMAP.md Phase 5 added only
 * the M-mode exception CSRs; unimplemented CSR reads return 0, see
 * CSR.v's default case) -- a real `csrr mcycle` would read 0 on both
 * calls, making User_Time permanently 0 and dhrystone_main.c's
 * `while (!Done)` retry loop (which doubts a 0-second measurement and
 * multiplies Number_Of_Runs by 10 to try again) never terminate.
 * sim/tools/build_c_bench.py passes
 * `-Dread_csr(reg)=fake_dhrystone_time()` so no real CSR instruction is
 * ever emitted for this at all -- fake_dhrystone_time() below is a plain
 * incrementing counter, sufficient to clear dhrystone.h's `Too_Small_Time`
 * threshold on the very first measurement. The resulting
 * Microseconds/Dhrystones_Per_Second figures dhrystone_main.c prints are
 * therefore not meaningful (there is no printf output to read anyway --
 * see below); real performance comes from the RTL testbench's own cycle
 * count (sim/tb/c_bench_template.v), same as the CoreMark port.
 */
static unsigned long fake_time_ticks = 0;

unsigned long
fake_dhrystone_time(void)
{
    fake_time_ticks += 1000;
    return fake_time_ticks;
}

/* No hardware event counters on this core -- no-op. */
void
setStats(int enable)
{
    (void)enable;
}

/* No UART/stdio on this core (same situation as CoreMark's ee_printf --
 * see sim/benchmarks/c/coremark_port/core_portme.c). dhrystone_main.c's
 * final printf()s report Microseconds/Dhrystones_Per_Second, which are
 * synthetic per the timing note above; the values worth checking
 * (Int_Glob, Bool_Glob, Ch_1_Glob, Ch_2_Glob, Arr_1_Glob[8],
 * Arr_2_Glob[8][7], Ptr_Glob/Next_Ptr_Glob fields) are plain globals at
 * fixed, link-time-known addresses (readable via `nm`/`objdump` on the
 * compiled ELF) that dhrystone_main.c's own comments document the
 * expected values for -- read directly from the final data-memory dump,
 * not printed. */
int
printf(const char *fmt, ...)
{
    (void)fmt;
    return 0;
}
