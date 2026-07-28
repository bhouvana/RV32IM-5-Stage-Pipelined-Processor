/*
 * Toolchain smoke test (docs/ROADMAP.md Phase 10). Deliberately small and
 * simple -- exercises a global array (.data + .bss), a function call
 * (stack frame, ra save/restore), a loop, and the standard RISC-V calling
 * convention's return-value register (a0/x10) -- before attempting the
 * much larger CoreMark/Dhrystone builds. Debugging a toolchain/linker/
 * elf2mem.py problem here is minutes of work; debugging the same class of
 * problem inside CoreMark's full codebase would not be.
 */

/* Initialized .data (not all-zero, so a working DATA_INIT_FILE pre-load is
 * actually exercised -- an all-zero-initialized array wouldn't distinguish
 * "loaded correctly" from "data memory's own reset-to-zero default"). */
static int values[8] = {10, 20, 30, 40, 50, 60, 70, 80};

/* Uninitialized .bss, to confirm it's correctly zeroed (by crt0.S's loop
 * and/or DataMemoryBRAM.v's own reset -- either is fine, both should agree). */
static int accumulator;

static int
sum_array(const int *arr, int n)
{
    int total = 0;
    for (int i = 0; i < n; i++)
        total += arr[i];
    return total;
}

int
main(void)
{
    accumulator = sum_array(values, 8);
    return accumulator; /* expect 360 (10+20+...+80), in a0/x10 on return */
}
