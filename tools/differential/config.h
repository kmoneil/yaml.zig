/* libfyaml's config.h for the differential fuzz target (karte t68),
 * written by hand in place of its configure: the C library's headers,
 * pthreads, and BLAKE3 portable only (no TARGET_HAS_* SIMD), as it only
 * hashes documents, which reading events never does. */
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_WCHAR_H 1
#define HAVE_PTHREAD 1
#define HAVE_SSIZE_T 1
#define HAVE___BUILTIN_BSWAP16 1
#define HAVE___BUILTIN_BSWAP32 1
#define HAVE___BUILTIN_BSWAP64 1
#define STDC_HEADERS 1
#define PACKAGE "libfyaml"
#define PACKAGE_NAME "libfyaml"
#define PACKAGE_VERSION "0.9.6"
#define PACKAGE_STRING "libfyaml 0.9.6"
#define VERSION "0.9.6"
