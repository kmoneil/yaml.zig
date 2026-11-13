/* What the differential fuzz target calls in libfyaml (karte t68): an
 * input's events as `fy-tool --testsuite` writes them, its parser set as
 * that tool's defaults set it (quiet here, which only silences its
 * diagnostics). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libfyaml.h>
#include "fy-tool-util.h"

FILE *fy_shim_out;

/* The first diagnostic of the last parse, for sorting disagreements by
 * libfyaml's reason; diagnostics print nowhere (FYPCF_QUIET alone still
 * prints errors). */
static char first_diagnostic[256];

static void quiet(struct fy_diag *diag, void *user, const char *buf, size_t len)
{
	(void)diag;
	(void)user;
	if (first_diagnostic[0] || len == 0)
		return;
	if (len >= sizeof first_diagnostic)
		len = sizeof first_diagnostic - 1;
	memcpy(first_diagnostic, buf, len);
	first_diagnostic[len] = '\0';
}

/* The first diagnostic fy_shim_events's last parse gave, or "". */
const char *fy_shim_diagnostic(void)
{
	return first_diagnostic;
}

/* Writes the events of `data` into *out, malloc'd, for the caller to
 * free(), its length in *out_len; returns 0 if libfyaml read the stream,
 * 1 if it refused it, -1 if it could not run. */
int fy_shim_events(const char *data, size_t len, char **out, size_t *out_len)
{
	struct fy_parse_cfg cfg = { .search_path = "", .flags = FYPCF_QUIET };
	struct fy_diag_cfg dcfg;
	struct fy_diag *diag;
	struct fy_parser *fyp;
	struct fy_event *fye;
	int refused;

	*out = NULL;
	*out_len = 0;
	first_diagnostic[0] = '\0';
	fy_diag_cfg_default(&dcfg);
	dcfg.fp = NULL;
	dcfg.output_fn = quiet;
	diag = fy_diag_create(&dcfg);
	if (!diag)
		return -1;
	cfg.diag = diag;
	fy_shim_out = open_memstream(out, out_len);
	if (!fy_shim_out) {
		fy_diag_unref(diag);
		return -1;
	}
	fyp = fy_parser_create(&cfg);
	if (!fyp || fy_parser_set_string(fyp, data, len)) {
		if (fyp)
			fy_parser_destroy(fyp);
		fclose(fy_shim_out);
		fy_diag_unref(diag);
		return -1;
	}
	while ((fye = fy_parser_parse(fyp)) != NULL) {
		dump_testsuite_event(fye, 0);
		fy_parser_event_free(fyp, fye);
	}
	refused = fy_parser_get_stream_error(fyp) ? 1 : 0;
	fy_parser_destroy(fyp);
	fclose(fy_shim_out);
	fy_diag_unref(diag);
	return refused;
}
