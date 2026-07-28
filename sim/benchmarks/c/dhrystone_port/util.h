/*
 * Minimal stand-in for riscv-tests/benchmarks/common/util.h, used only so
 * dhrystone_main.c's unmodified `#include "util.h"` resolves (docs/
 * ROADMAP.md Phase 10). The real util.h pulls in riscv-tests' own
 * encoding.h (CSR name definitions for its `stats()` macro/HTIF-based
 * benchmarks) and defines verify()/barrier()/lfsr() helpers -- none of
 * which dhrystone_main.c actually calls; the only thing it uses from this
 * header is the setStats() declaration below (dhrystone_portme.c provides
 * a no-op definition -- this core has no hardware event counters to
 * toggle).
 */
#ifndef __UTIL_H
#define __UTIL_H

extern void setStats(int enable);

#endif
