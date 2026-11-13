/* Forced into libfyaml's fy-tool-dump.c (-include): what its
 * dump_testsuite_event writes to stdout goes to fy_shim_out, a memory
 * stream, so its events are libfyaml's own printing, not a copy of it
 * (karte t68). */
#include <stdio.h>
extern FILE *fy_shim_out;
#undef stdout
#define stdout fy_shim_out
#define printf(...) fprintf(fy_shim_out, __VA_ARGS__)
