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

/* Whether `text` is UTF-8 by the checks fy-tool-dump.c's print_escaped
 * makes, which aborts on anything else (and loops for ever on a byte that
 * cannot begin a character, whose width it takes for 0). */
static int is_utf8(const char *text, size_t len)
{
	const unsigned char *p = (const unsigned char *)text;
	size_t i = 0;

	while (i < len) {
		unsigned int c = p[i];
		int w = (c & 0x80) == 0x00 ? 1 :
			(c & 0xe0) == 0xc0 ? 2 :
			(c & 0xf0) == 0xe0 ? 3 :
			(c & 0xf8) == 0xf0 ? 4 : 0;
		int k;

		if (w == 0 || (size_t)w > len - i)
			return 0;
		c &= 0xffu >> w;
		for (k = 1; k < w; k++) {
			if ((p[i + k] & 0xc0) != 0x80)
				return 0;
			c = (c << 6) | (p[i + k] & 0x3f);
		}
		if ((w == 4 && c < 0x10000) || (w == 3 && c < 0x800) ||
		    (w == 2 && c < 0x80) || (c >= 0xd800 && c <= 0xdfff) ||
		    c >= 0x110000)
			return 0;
		i += (size_t)w;
	}
	return 1;
}

/* Writes the events of `data` into *out, malloc'd, for the caller to
 * free(), its length in *out_len; returns 0 if libfyaml read the stream,
 * 1 if it refused it, 2 if it gave a scalar whose text is not UTF-8 (the
 * events before that one written), -1 if it could not run. */
int fy_shim_events(const char *data, size_t len, char **out, size_t *out_len)
{
	struct fy_parse_cfg cfg = { .search_path = "", .flags = FYPCF_QUIET };
	struct fy_diag_cfg dcfg;
	struct fy_diag *diag;
	struct fy_parser *fyp;
	struct fy_event *fye;
	int refused;
	int garbled = 0;

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
		if (fye->type == FYET_SCALAR) {
			size_t n = 0;
			const char *text = fy_token_get_text(fye->scalar.value, &n);

			if (text && !is_utf8(text, n)) {
				fy_parser_event_free(fyp, fye);
				garbled = 1;
				break;
			}
		}
		dump_testsuite_event(fye, 0);
		fy_parser_event_free(fyp, fye);
	}
	refused = garbled ? 2 : fy_parser_get_stream_error(fyp) ? 1 : 0;
	fy_parser_destroy(fyp);
	fclose(fy_shim_out);
	fy_diag_unref(diag);
	return refused;
}
