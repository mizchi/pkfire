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

/*
 * Write a UTF-8 byte string to stdout verbatim and flush.
 *
 * Used by the log tee, which forwards a child's output chunk by chunk
 * as it arrives. `println` cannot do this: a chunk boundary can fall
 * inside a multi-byte character or mid-line, and decoding each chunk
 * separately would corrupt the first and add a newline to the second.
 * The flush is what keeps the forwarding live — stdout is block
 * buffered whenever it is not a terminal, and a build whose output
 * appears only at exit is not being streamed.
 */
MOONBIT_FFI_EXPORT void mizchi_pkf_print(moonbit_bytes_t s) {
  int32_t len = (int32_t)Moonbit_array_length(s);
  fwrite((const char *)s, 1, (size_t)len, stdout);
  fflush(stdout);
}
