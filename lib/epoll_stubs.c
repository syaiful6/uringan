#include "config.h"

#ifdef USE_EPOLL

#include <errno.h>
#include <stdlib.h>
#include <sys/epoll.h>

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

/* Event buffer: a malloc'd array of epoll_event in a custom block, so the
   kernel can write into it while the runtime lock is released. */

struct events {
  int len;
  struct epoll_event *buf;
};

#define Events_val(v) ((struct events *)Data_custom_val(v))

static void events_finalize(value v) {
  free(Events_val(v)->buf);
  Events_val(v)->buf = NULL;
}

static struct custom_operations events_ops = {
    "uringan.epoll.events", events_finalize,
    custom_compare_default, custom_hash_default,
    custom_serialize_default, custom_deserialize_default,
    custom_compare_ext_default, custom_fixed_length_default};

value uringan_epoll_events_create(value v_len) {
  int len = Int_val(v_len);
  if (len <= 0) caml_invalid_argument("Epoll.Events.create");
  struct epoll_event *buf = calloc(len, sizeof(struct epoll_event));
  if (buf == NULL) caml_raise_out_of_memory();
  value v = caml_alloc_custom_mem(&events_ops, sizeof(struct events),
                                  len * sizeof(struct epoll_event));
  Events_val(v)->len = len;
  Events_val(v)->buf = buf;
  return v;
}

value uringan_epoll_events_length(value v_events) {
  return Val_int(Events_val(v_events)->len);
}

/* Bounds are checked on the OCaml side. */
value uringan_epoll_events_fd(value v_events, value v_i) {
  return Val_int(Events_val(v_events)->buf[Int_val(v_i)].data.fd);
}

value uringan_epoll_events_flags(value v_events, value v_i) {
  return Val_int(Events_val(v_events)->buf[Int_val(v_i)].events);
}

value uringan_epoll_create(value v_unit) {
  (void)v_unit;
  int fd = epoll_create1(EPOLL_CLOEXEC);
  if (fd == -1) caml_uerror("epoll_create1", Nothing);
  return Val_int(fd);
}

value uringan_epoll_ctl(value v_epfd, value v_op, value v_fd, value v_flags) {
  static const int ops[] = {EPOLL_CTL_ADD, EPOLL_CTL_MOD, EPOLL_CTL_DEL};
  struct epoll_event ev = {0};
  ev.events = Int_val(v_flags);
  ev.data.fd = Int_val(v_fd);
  if (epoll_ctl(Int_val(v_epfd), ops[Int_val(v_op)], Int_val(v_fd), &ev) == -1)
    caml_uerror("epoll_ctl", Nothing);
  return Val_unit;
}

/* Returns the number of ready events, or 0 if interrupted by a signal. */
value uringan_epoll_wait(value v_epfd, value v_events, value v_timeout) {
  CAMLparam1(v_events);
  struct events *events = Events_val(v_events);
  int epfd = Int_val(v_epfd);
  int timeout = Int_val(v_timeout);
  int n;

  caml_enter_blocking_section();
  n = epoll_wait(epfd, events->buf, events->len, timeout);
  caml_leave_blocking_section();

  if (n == -1) {
    if (errno == EINTR) CAMLreturn(Val_int(0));
    caml_uerror("epoll_wait", Nothing);
  }
  CAMLreturn(Val_int(n));
}

value uringan_epoll_flag_in(value v_unit) { (void)v_unit; return Val_int(EPOLLIN); }
value uringan_epoll_flag_out(value v_unit) { (void)v_unit; return Val_int(EPOLLOUT); }
value uringan_epoll_flag_err(value v_unit) { (void)v_unit; return Val_int(EPOLLERR); }
value uringan_epoll_flag_hup(value v_unit) { (void)v_unit; return Val_int(EPOLLHUP); }
value uringan_epoll_flag_rdhup(value v_unit) { (void)v_unit; return Val_int(EPOLLRDHUP); }
value uringan_epoll_flag_oneshot(value v_unit) { (void)v_unit; return Val_int(EPOLLONESHOT); }

#endif /* USE_EPOLL */
