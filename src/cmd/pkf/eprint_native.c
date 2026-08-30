#include <moonbit.h>
#include <stdio.h>

/* Write a UTF-8 byte string to stderr verbatim. */
MOONBIT_FFI_EXPORT void mizchi_pkf_eprint(moonbit_bytes_t s) {
  int32_t len = (int32_t)Moonbit_array_length(s);
  fwrite((const char *)s, 1, (size_t)len, stderr);
}

/*
 * Flush buffered stdout.
 *
 * When stdout is a pipe, C buffers it in full-block mode and nothing
 * appears until the buffer fills or the process exits. That is fine for
 * a sequential run, where the commands write to the inherited fd
 * themselves, but under `-j` the runner captures their output and
 * prints it — so without a flush a ten-minute parallel build shows
 * nothing until it is over. Called once per completed action, which is
 * rare enough that the cost is irrelevant.
 */
MOONBIT_FFI_EXPORT void mizchi_pkf_flush_stdout(void) { fflush(stdout); }
