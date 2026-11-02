#include "config.h"

#ifdef USE_EPOLL

#include <errno.h>
#include <stdint.h>
#include <sys/eventfd.h>
#include <unistd.h>

#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>

value uringan_eventfd_create(value v_unit) {
  (void)v_unit;
  int fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  if (fd == -1)
    caml_uerror("eventfd", Nothing);
  return Val_int(fd);
}

/* Adds 1 to the counter. EAGAIN means the counter is about to overflow, so
   the eventfd is already readable and the signal is not lost. */
value uringan_eventfd_signal(value v_fd) {
  uint64_t one = 1;
  ssize_t n;
  do
    n = write(Int_val(v_fd), &one, sizeof one);
  while (n == -1 && errno == EINTR);
  if (n == -1 && errno != EAGAIN)
    caml_uerror("eventfd_signal", Nothing);
  return Val_unit;
}

/* Resets the counter to 0. Returns false if it was already 0. */
value uringan_eventfd_drain(value v_fd) {
  uint64_t count;
  ssize_t n;
  do
    n = read(Int_val(v_fd), &count, sizeof count);
  while (n == -1 && errno == EINTR);
  if (n == -1) {
    if (errno == EAGAIN)
      return Val_false;
    caml_uerror("eventfd_drain", Nothing);
  }
  return Val_true;
}

#endif /* USE_EPOLL */
