#include "config.h"

#ifdef USE_KQUEUE

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/event.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

/* kqueue has no flag word of its own: interest is one filter per direction,
   and what happened is a filter plus EV_EOF or EV_ERROR. These bits give it
   the same shape as epoll's, so the ring can treat the two backends alike.
   They are mirrored in kqueue.ml through the accessors at the bottom. */
#define URINGAN_KQ_IN 1
#define URINGAN_KQ_OUT 2
#define URINGAN_KQ_ERR 4
#define URINGAN_KQ_HUP 8
#define URINGAN_KQ_RDHUP 16
#define URINGAN_KQ_ONESHOT 32

/* Event buffer: a malloc'd array of kevent in a custom block, so the kernel
   can write into it while the runtime lock is released. */

struct events {
  int len;
  struct kevent *buf;
};

#define Events_val(v) ((struct events *)Data_custom_val(v))

static void events_finalize(value v) {
  free(Events_val(v)->buf);
  Events_val(v)->buf = NULL;
}

static struct custom_operations events_ops = {
    "uringan.kqueue.events", events_finalize,
    custom_compare_default,  custom_hash_default,
    custom_serialize_default, custom_deserialize_default,
    custom_compare_ext_default, custom_fixed_length_default};

value uringan_kqueue_events_create(value v_len) {
  int len = Int_val(v_len);
  if (len <= 0) caml_invalid_argument("Kqueue.Events.create");
  struct kevent *buf = calloc(len, sizeof(struct kevent));
  if (buf == NULL) caml_raise_out_of_memory();
  value v = caml_alloc_custom_mem(&events_ops, sizeof(struct events),
                                  len * sizeof(struct kevent));
  Events_val(v)->len = len;
  Events_val(v)->buf = buf;
  return v;
}

value uringan_kqueue_events_length(value v_events) {
  return Val_int(Events_val(v_events)->len);
}

/* Bounds are checked on the OCaml side. */
value uringan_kqueue_events_fd(value v_events, value v_i) {
  return Val_int((int)Events_val(v_events)->buf[Int_val(v_i)].ident);
}

value uringan_kqueue_events_flags(value v_events, value v_i) {
  const struct kevent *ev = &Events_val(v_events)->buf[Int_val(v_i)];
  int flags = 0;
  if (ev->flags & EV_ERROR) flags |= URINGAN_KQ_ERR;
  if (ev->filter == EVFILT_READ) {
    flags |= URINGAN_KQ_IN;
    /* Nothing more will arrive, so a retried read reports end of file. This is
       RDHUP rather than HUP because the write direction of a socket may still
       be open; the ring retries readers on IN anyway. */
    if (ev->flags & EV_EOF) flags |= URINGAN_KQ_RDHUP;
  } else if (ev->filter == EVFILT_WRITE) {
    flags |= URINGAN_KQ_OUT;
    if (ev->flags & EV_EOF) flags |= URINGAN_KQ_HUP;
  }
  return Val_int(flags);
}

value uringan_kqueue_create(value v_unit) {
  (void)v_unit;
  int fd = kqueue();
  if (fd == -1) caml_uerror("kqueue", Nothing);
  /* kqueue(2) has no CLOEXEC variant. */
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) == -1) {
    int saved = errno;
    close(fd);
    errno = saved;
    caml_uerror("kqueue", Nothing);
  }
  return Val_int(fd);
}

/* One change per call: kevent(2) reports which change failed through an event
   list flagged EV_ERROR, or through errno when no list is given, and EV_RECEIPT
   is not available on every BSD. Arming therefore costs two syscalls instead of
   epoll_ctl's one. Returns 0 or an errno. */
static int apply(int kq, int fd, short filter, unsigned short eflags) {
  struct kevent change;
  EV_SET(&change, (uintptr_t)fd, filter, eflags, 0, 0, NULL);
  if (kevent(kq, &change, 1, NULL, 0, NULL) == -1) return errno;
  return 0;
}

static int change_filter(int kq, int fd, short filter, int want,
                         unsigned short oneshot) {
  if (want) return apply(kq, fd, filter, EV_ADD | EV_ENABLE | oneshot);
  return apply(kq, fd, filter, EV_DELETE);
}

/* [v_op] is 0 to add, 1 to modify, 2 to delete, as in [Kqueue.ctl]. Adding and
   modifying are the same kevent change, so a modify of a descriptor that is not
   registered succeeds here where epoll_ctl would fail with ENOENT. */
value uringan_kqueue_ctl(value v_kq, value v_op, value v_fd, value v_flags) {
  int kq = Int_val(v_kq);
  int op = Int_val(v_op);
  int fd = Int_val(v_fd);
  int flags = Int_val(v_flags);
  int deleting = op == 2;
  int want_in = !deleting && (flags & URINGAN_KQ_IN);
  int want_out = !deleting && (flags & URINGAN_KQ_OUT);
  unsigned short oneshot =
      (flags & URINGAN_KQ_ONESHOT) ? (unsigned short)EV_ONESHOT : 0;
  int err_in = change_filter(kq, fd, EVFILT_READ, want_in, oneshot);
  int err_out = change_filter(kq, fd, EVFILT_WRITE, want_out, oneshot);
  int err;

  if (deleting) {
    /* Mirror epoll_ctl(EPOLL_CTL_DEL): ENOENT only when neither direction was
       watched, since a descriptor is rarely registered for both. */
    if (err_in == ENOENT && err_out == ENOENT)
      err = ENOENT;
    else if (err_in != 0 && err_in != ENOENT)
      err = err_in;
    else if (err_out != 0 && err_out != ENOENT)
      err = err_out;
    else
      err = 0;
  } else {
    /* Failing to remove a filter that is not wanted is not a problem: it was
       never registered, or this descriptor cannot carry it at all, as with
       EVFILT_WRITE on the read end of a pipe. Either way it will not fire. */
    err = want_in && err_in != 0 ? err_in : (want_out ? err_out : 0);
  }
  if (err != 0) {
    errno = err;
    caml_uerror("kevent", Nothing);
  }
  return Val_unit;
}

/* Returns the number of ready events, or 0 if interrupted by a signal. */
value uringan_kqueue_wait(value v_kq, value v_events, value v_timeout) {
  CAMLparam1(v_events);
  struct events *events = Events_val(v_events);
  int kq = Int_val(v_kq);
  int timeout = Int_val(v_timeout);
  struct timespec ts;
  struct timespec *tsp = NULL;
  int n;

  if (timeout >= 0) {
    ts.tv_sec = timeout / 1000;
    ts.tv_nsec = (long)(timeout % 1000) * 1000000L;
    tsp = &ts;
  }

  caml_enter_blocking_section();
  n = kevent(kq, NULL, 0, events->buf, events->len, tsp);
  caml_leave_blocking_section();

  if (n == -1) {
    if (errno == EINTR) CAMLreturn(Val_int(0));
    caml_uerror("kevent", Nothing);
  }
  CAMLreturn(Val_int(n));
}

value uringan_kqueue_flag_in(value v_unit) { (void)v_unit; return Val_int(URINGAN_KQ_IN); }
value uringan_kqueue_flag_out(value v_unit) { (void)v_unit; return Val_int(URINGAN_KQ_OUT); }
value uringan_kqueue_flag_err(value v_unit) { (void)v_unit; return Val_int(URINGAN_KQ_ERR); }
value uringan_kqueue_flag_hup(value v_unit) { (void)v_unit; return Val_int(URINGAN_KQ_HUP); }
value uringan_kqueue_flag_rdhup(value v_unit) { (void)v_unit; return Val_int(URINGAN_KQ_RDHUP); }
value uringan_kqueue_flag_oneshot(value v_unit) { (void)v_unit; return Val_int(URINGAN_KQ_ONESHOT); }

#endif /* USE_KQUEUE */
