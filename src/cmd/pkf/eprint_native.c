#include <moonbit.h>
#include <stdio.h>

/* Write a UTF-8 byte string to stderr verbatim. */
MOONBIT_FFI_EXPORT void mizchi_pkf_eprint(moonbit_bytes_t s) {
  int32_t len = (int32_t)Moonbit_array_length(s);
  fwrite((const char *)s, 1, (size_t)len, stderr);
}
