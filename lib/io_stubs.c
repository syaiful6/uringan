#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <sys/uio.h>
#include <sys/types.h>
#include <unistd.h>

#define CAML_NAME_SPACE
#include <caml/bigarray.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

#include "uringan_stubs.h"

/* Read/write stubs return the byte count, or -errno on failure, so the caller
   can tell EAGAIN apart without an exception. A [file_offset] of -1 means the
   current position (read/write); otherwise pread/pwrite is used.

   The runtime lock is released because regular-file I/O can block. The data
   lives in a bigarray outside the OCaml heap, and [v_buf] is a local root, so
   it cannot move or be freed meanwhile. EINTR is retried. */

value uringan_read(value v_fd, value v_buf, value v_off, value v_len,
                   value v_file_offset) {
  CAMLparam1(v_buf);
  int fd = Int_val(v_fd);
  char *buf = (char *)Caml_ba_data_val(v_buf) + Long_val(v_off);
  size_t len = Long_val(v_len);
  off_t file_offset = Long_val(v_file_offset);
  ssize_t n;
  int err;

  caml_enter_blocking_section();
  do
    n = file_offset < 0 ? read(fd, buf, len) : pread(fd, buf, len, file_offset);
  while (n == -1 && errno == EINTR);
  err = errno;
  caml_leave_blocking_section();

  CAMLreturn(Val_long(n == -1 ? -err : n));
}

value uringan_write(value v_fd, value v_buf, value v_off, value v_len,
                    value v_file_offset) {
  CAMLparam1(v_buf);
  int fd = Int_val(v_fd);
  const char *buf = (const char *)Caml_ba_data_val(v_buf) + Long_val(v_off);
  size_t len = Long_val(v_len);
  off_t file_offset = Long_val(v_file_offset);
  ssize_t n;
  int err;

  caml_enter_blocking_section();
  do
    n = file_offset < 0 ? write(fd, buf, len)
                        : pwrite(fd, buf, len, file_offset);
  while (n == -1 && errno == EINTR);
  err = errno;
  caml_leave_blocking_section();

  CAMLreturn(Val_long(n == -1 ? -err : n));
}

value uringan_error_of_errno(value v_errno) {
  return caml_unix_error_of_code(Int_val(v_errno));
}

value uringan_errno_eagain(value v_unit) {
  (void)v_unit;
  return Val_int(EAGAIN);
}

/* Fill [iov] from a list of [n] Cstruct.t records {buffer; off; len}. */
void uringan_iov_of_cstructs(value v_bufs, struct iovec *iov, int n) {
  for (int i = 0; i < n; i++, v_bufs = Field(v_bufs, 1)) {
    value v_cs = Field(v_bufs, 0);
    iov[i].iov_base =
        (char *)Caml_ba_data_val(Field(v_cs, 0)) + Long_val(Field(v_cs, 1));
    iov[i].iov_len = Long_val(Field(v_cs, 2));
  }
}

/* [v_n] is the list length, checked against [iov_max] by the caller. */
value uringan_readv(value v_fd, value v_bufs, value v_n, value v_file_offset) {
  CAMLparam1(v_bufs);
  int fd = Int_val(v_fd);
  int n = Int_val(v_n);
  off_t file_offset = Long_val(v_file_offset);
  struct iovec iov[n > 0 ? n : 1];
  ssize_t r;
  int err;

  /* An empty list is a no-op: Linux's readv/writev return 0 for it, the BSDs
     fail with EINVAL. Short-circuiting keeps the result the same everywhere
     and saves a syscall. */
  if (n == 0) CAMLreturn(Val_long(0));

  uringan_iov_of_cstructs(v_bufs, iov, n);
  caml_enter_blocking_section();
  do
    r = file_offset < 0 ? readv(fd, iov, n) : preadv(fd, iov, n, file_offset);
  while (r == -1 && errno == EINTR);
  err = errno;
  caml_leave_blocking_section();

  CAMLreturn(Val_long(r == -1 ? -err : r));
}

value uringan_writev(value v_fd, value v_bufs, value v_n,
                     value v_file_offset) {
  CAMLparam1(v_bufs);
  int fd = Int_val(v_fd);
  int n = Int_val(v_n);
  off_t file_offset = Long_val(v_file_offset);
  struct iovec iov[n > 0 ? n : 1];
  ssize_t r;
  int err;

  /* An empty list is a no-op: Linux's readv/writev return 0 for it, the BSDs
     fail with EINVAL. Short-circuiting keeps the result the same everywhere
     and saves a syscall. */
  if (n == 0) CAMLreturn(Val_long(0));

  uringan_iov_of_cstructs(v_bufs, iov, n);
  caml_enter_blocking_section();
  do
    r = file_offset < 0 ? writev(fd, iov, n)
                        : pwritev(fd, iov, n, file_offset);
  while (r == -1 && errno == EINTR);
  err = errno;
  caml_leave_blocking_section();

  CAMLreturn(Val_long(r == -1 ? -err : r));
}

value uringan_iov_max(value v_unit) {
  (void)v_unit;
  long n = sysconf(_SC_IOV_MAX);
  return Val_long(n > 0 ? n : 16); /* POSIX minimum, _XOPEN_IOV_MAX */
}

/* Non-blocking readiness check: the ready events, -EAGAIN if none, or -EBADF
   if [fd] is not open. Never blocks, so the runtime lock is kept. */
value uringan_poll(value v_fd, value v_events) {
  struct pollfd p = {.fd = Int_val(v_fd), .events = Int_val(v_events)};
  int n;
  do
    n = poll(&p, 1, 0);
  while (n == -1 && errno == EINTR);
  if (n == -1) return Val_int(-errno);
  if (n == 0) return Val_int(-EAGAIN);
  if (p.revents & POLLNVAL) return Val_int(-EBADF);
  return Val_int(p.revents);
}

value uringan_poll_flag_in(value v_unit) { (void)v_unit; return Val_int(POLLIN); }
value uringan_poll_flag_out(value v_unit) { (void)v_unit; return Val_int(POLLOUT); }
value uringan_poll_flag_err(value v_unit) { (void)v_unit; return Val_int(POLLERR); }
value uringan_poll_flag_hup(value v_unit) { (void)v_unit; return Val_int(POLLHUP); }

value uringan_errno_etime(value v_unit) {
  (void)v_unit;
  return Val_int(ETIME);
}

value uringan_errno_ecanceled(value v_unit) {
  (void)v_unit;
  return Val_int(ECANCELED);
}
