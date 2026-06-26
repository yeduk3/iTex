#ifndef ITEX_TECTONIC_H
#define ITEX_TECTONIC_H

#include <stddef.h>

/* C-FFI over Tectonic for iTex (docs/03 §3.7, docs/04 §4.1).
 * Compile UTF-8 LaTeX to PDF in-process — the only path that works on iOS. */

/* Returns a heap pointer to PDF bytes (free with itex_tectonic_free) and writes the length to
 * *out_len. Returns NULL on error (and sets *out_len = 0). */
unsigned char *itex_tectonic_compile(const unsigned char *input,
                                     size_t input_len,
                                     size_t *out_len);

/* Frees a buffer returned by itex_tectonic_compile. */
void itex_tectonic_free(unsigned char *ptr, size_t len);

#endif /* ITEX_TECTONIC_H */
