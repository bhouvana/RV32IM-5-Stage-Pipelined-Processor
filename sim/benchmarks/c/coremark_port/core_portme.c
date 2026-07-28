/*
 * CoreMark port for this core (docs/ROADMAP.md Phase 10). Based on
 * coremark-main/barebones/core_portme.c (see that file's header for the
 * original license/authorship) with barebones_porting.md's documented
 * changes for a target with no timer/UART.
 */
#include "coremark.h"
#include "core_portme.h"
#include <stddef.h>

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* Timing : this core has no timer peripheral (sim/benchmarks/c/README.md).
 * ITERATIONS is always a fixed, nonzero build flag here (see
 * sim/tools/build_c_bench.py's CoreMark invocation), so core_main.c's
 * auto-detect-iteration-count loop -- which spins until barebones_clock()
 * reports >=1 real second elapsed -- never runs; this function only needs
 * to return *some* monotonically increasing value so total_time/
 * time_in_secs() stay well-defined arithmetic, not measure real wall time.
 * Actual cycle counts come from the RTL testbench itself
 * (sim/tb/c_bench_template.v), entirely independent of this. One
 * consequence: main()'s own ">=10 secs for a valid result" check will
 * always fire and increment total_errors by exactly one, regardless of
 * whether the benchmark actually computed correctly -- correctness is
 * verified via core_results.err/crc/crclist/crcmatrix/crcstate directly
 * (captured in portable_fini() below), not via total_errors.
 */
#define CLOCKS_PER_SEC 100
static ee_u32 fake_clock_ticks = 0;

CORETIMETYPE
barebones_clock(void)
{
    fake_clock_ticks += 1;
    return fake_clock_ticks;
}

#define GETMYTIME(_t)              (*_t = barebones_clock())
#define MYTIMEDIFF(fin, ini)       ((fin) - (ini))
#define TIMER_RES_DIVIDER          1
#define SAMPLE_TIME_IMPLEMENTATION 1
#define EE_TICKS_PER_SEC           (CLOCKS_PER_SEC / TIMER_RES_DIVIDER)

static CORETIMETYPE start_time_val, stop_time_val;

void
start_time(void)
{
    GETMYTIME(&start_time_val);
}

void
stop_time(void)
{
    GETMYTIME(&stop_time_val);
}

CORE_TICKS
get_time(void)
{
    CORE_TICKS elapsed
        = (CORE_TICKS)(MYTIMEDIFF(stop_time_val, start_time_val));
    return elapsed;
}

secs_ret
time_in_secs(CORE_TICKS ticks)
{
    secs_ret retval = ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
    return retval;
}

ee_u32 default_num_contexts = 1;

void
portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    p->portable_id = 1;
}

/* Final results: this core has no UART/printf, so ee_printf's usual job of
 * reporting results[0].crc/crclist/crcmatrix/crcstate/err (core_main.c's
 * "output for verification" block) is redirected here instead of
 * discarded. portable_fini() is a real, intended porting hook -- called
 * exactly once, right before main() returns -- and its argument `p` is
 * `&results[0].port`, the *last* member of core_results (coremark.h), so
 * `p`'s address recovers the whole struct via offsetof without touching
 * core_main.c at all. sim/tools/build_c_bench.py reads these fixed,
 * `volatile`-qualified globals (so they survive optimization as real
 * stores) back out of the final data-memory dump.
 */
volatile ee_u16 coremark_result_crc        = 0;
volatile ee_u16 coremark_result_crclist    = 0;
volatile ee_u16 coremark_result_crcmatrix  = 0;
volatile ee_u16 coremark_result_crcstate   = 0;
volatile ee_s16 coremark_result_err        = -1;
volatile ee_u32 coremark_result_iterations = 0;

void
portable_fini(core_portable *p)
{
    core_results *r
        = (core_results *)((char *)p - offsetof(core_results, port));
    coremark_result_crc        = r->crc;
    coremark_result_crclist    = r->crclist;
    coremark_result_crcmatrix  = r->crcmatrix;
    coremark_result_crcstate   = r->crcstate;
    coremark_result_err        = r->err;
    coremark_result_iterations = r->iterations;
    p->portable_id              = 0;
}

/* No UART/stdio on this core. Called unconditionally throughout
 * core_main.c (not gated by HAS_PRINTF), so some definition is required
 * regardless -- the values it would have printed are captured directly
 * out of core_results in portable_fini() above instead. */
int
ee_printf(const char *fmt, ...)
{
    (void)fmt;
    return 0;
}
