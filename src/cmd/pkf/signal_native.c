#include <moonbit.h>
#include <signal.h>
#include <stdint.h>
#ifndef _WIN32
#include <pthread.h>
#endif

/*
 * Custom SIGINT / SIGTERM handler used by `pkf up`.
 *
 * Why this exists: moonbitlang/async's set_global_cancellation_signals
 * masks SIGINT into a sigwait thread that terminates the whole event
 * loop on receipt, so a user-level teardown branch never runs.
 * `pkf up` doesn't call that API — instead we install a tiny
 * sig_atomic_t-flag handler before any service starts, then poll the
 * flag from the supervisor loop and run the graceful teardown when
 * it flips.
 */

static volatile sig_atomic_t pkf_stop_flag = 0;

#ifndef _WIN32

static void pkf_signal_handler(int sig) {
  (void)sig;
  pkf_stop_flag = 1;
}

MOONBIT_FFI_EXPORT int32_t mizchi_pkf_signal_install(void) {
  struct sigaction sa;
  sa.sa_handler = pkf_signal_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  if (sigaction(SIGINT, &sa, NULL) != 0) return -1;
  if (sigaction(SIGTERM, &sa, NULL) != 0) return -1;
  // moonbitlang/async's runtime starts with SIGINT/SIGTERM blocked on
  // every thread (so its sigwait-based cancellation logic can receive
  // them). With sigaction alone the signals are still pending and our
  // handler never fires; explicitly unblocking them on the calling
  // thread (main) wakes the kernel up.
  sigset_t mask;
  sigemptyset(&mask);
  sigaddset(&mask, SIGINT);
  sigaddset(&mask, SIGTERM);
  if (pthread_sigmask(SIG_UNBLOCK, &mask, NULL) != 0) return -1;
  return 0;
}

#else

/*
 * Windows: SIGINT only fires for Ctrl-C in console processes; SIGTERM
 * isn't really a thing. Using the older signal() API is fine here
 * since we just need a flag-set on Ctrl-C.
 */
static void pkf_signal_handler(int sig) {
  (void)sig;
  pkf_stop_flag = 1;
}

MOONBIT_FFI_EXPORT int32_t mizchi_pkf_signal_install(void) {
  if (signal(SIGINT, pkf_signal_handler) == SIG_ERR) return -1;
  return 0;
}

#endif

MOONBIT_FFI_EXPORT int32_t mizchi_pkf_signal_check(void) {
  return (int32_t)pkf_stop_flag;
}
