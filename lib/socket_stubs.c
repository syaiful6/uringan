#define _GNU_SOURCE /* accept4 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/config.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/socketaddr.h>
#include <caml/unixsupport.h>

#include "uringan_stubs.h"

/* Socket stubs. Like io_stubs.c, operations return the result or -errno.
   They are only used on non-blocking sockets, so the runtime lock is kept and
   addresses can live in OCaml [bytes].

   Encoded addresses are [bytes] holding a struct sockaddr, whose length is the
   address length. A peer address (Sockaddr.t) is a record
   [{ storage : bytes; mutable len : int }] filled in by accept/recvmsg. */

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

/* In the order of the Unix.socket_domain, socket_type and shutdown_command
   constructors. */
static const int socket_domains[] = {AF_UNIX, AF_INET, AF_INET6};
static const int socket_types[] = {SOCK_STREAM, SOCK_DGRAM, SOCK_RAW,
                                   SOCK_SEQPACKET};
static const int shutdown_commands[] = {SHUT_RD, SHUT_WR, SHUT_RDWR};

value uringan_sockaddr_size(value v_unit) {
  (void)v_unit;
  return Val_int(sizeof(struct sockaddr_storage));
}

value uringan_sockaddr_encode(value v_addr) {
  CAMLparam1(v_addr);
  CAMLlocal1(v_buf);
  union sock_addr_union addr;
  socklen_param_type len;

  caml_unix_get_sockaddr(v_addr, &addr, &len);
  v_buf = caml_alloc_string(len);
  memcpy(Bytes_val(v_buf), &addr, len);
  CAMLreturn(v_buf);
}

value uringan_sockaddr_decode(value v_storage, value v_len) {
  struct sockaddr_storage addr;
  memcpy(&addr, Bytes_val(v_storage), Int_val(v_len));
  return caml_unix_alloc_sockaddr((union sock_addr_union *)&addr,
                                  Int_val(v_len), -1);
}

#ifndef SOCK_NONBLOCK
/* Make [fd] non-blocking and optionally close-on-exec, where the flags could
   not be given to socket(2)/accept4(2). */
static int set_flags(int fd, int cloexec) {
  int fl = fcntl(fd, F_GETFL);
  if (fl == -1 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) == -1) return -1;
  if (cloexec && fcntl(fd, F_SETFD, FD_CLOEXEC) == -1) return -1;
  return 0;
}
#endif

static value fd_or_errno(int fd, int cloexec) {
#ifdef SOCK_NONBLOCK
  (void)cloexec;
#else
  if (fd != -1 && set_flags(fd, cloexec) == -1) {
    int err = errno;
    close(fd);
    return Val_int(-err);
  }
#endif
  return Val_int(fd == -1 ? -errno : fd);
}

value uringan_socket(value v_domain, value v_type, value v_protocol,
                     value v_cloexec) {
  int type = socket_types[Int_val(v_type)];
  int cloexec = Bool_val(v_cloexec);
#ifdef SOCK_NONBLOCK
  type |= SOCK_NONBLOCK | (cloexec ? SOCK_CLOEXEC : 0);
#endif
  int fd = socket(socket_domains[Int_val(v_domain)], type, Int_val(v_protocol));
  return fd_or_errno(fd, cloexec);
}

value uringan_bind(value v_fd, value v_addr) {
  int r = bind(Int_val(v_fd), (struct sockaddr *)Bytes_val(v_addr),
               caml_string_length(v_addr));
  return Val_int(r == -1 ? -errno : 0);
}

value uringan_listen(value v_fd, value v_backlog) {
  int r = listen(Int_val(v_fd), Int_val(v_backlog));
  return Val_int(r == -1 ? -errno : 0);
}

value uringan_shutdown(value v_fd, value v_cmd) {
  int r = shutdown(Int_val(v_fd), shutdown_commands[Int_val(v_cmd)]);
  return Val_int(r == -1 ? -errno : 0);
}

/* An interrupted connect carries on asynchronously, like EINPROGRESS. */
value uringan_connect(value v_fd, value v_addr) {
  int r = connect(Int_val(v_fd), (struct sockaddr *)Bytes_val(v_addr),
                  caml_string_length(v_addr));
  if (r == 0) return Val_int(0);
  return Val_int(errno == EINTR ? -EINPROGRESS : -errno);
}

/* The outcome of an in-progress connect: -EAGAIN while it is still pending,
   then 0 or the error from SO_ERROR. */
value uringan_connect_finish(value v_fd) {
  int fd = Int_val(v_fd);
  struct pollfd p = {.fd = fd, .events = POLLOUT};
  int err;
  socklen_t len = sizeof(err);

  if (poll(&p, 1, 0) == 0) return Val_int(-EAGAIN);
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == -1) err = errno;
  return Val_int(-err);
}

value uringan_accept(value v_fd, value v_peer) {
  struct sockaddr_storage addr;
  socklen_t len = sizeof(addr);
  int fd;

  do {
#ifdef SOCK_NONBLOCK
    fd = accept4(Int_val(v_fd), (struct sockaddr *)&addr, &len,
                 SOCK_NONBLOCK | SOCK_CLOEXEC);
#else
    fd = accept(Int_val(v_fd), (struct sockaddr *)&addr, &len);
#endif
  } while (fd == -1 && errno == EINTR);
  if (fd != -1) {
    memcpy(Bytes_val(Field(v_peer, 0)), &addr, len);
    Field(v_peer, 1) = Val_int(len);
  }
  return fd_or_errno(fd, 1);
}

/* Number of struct cmsghdr needed to hold [n_fds] descriptors, so that the
   control buffer is suitably aligned. */
#define CMSG_UNITS(n_fds)                                                      \
  ((CMSG_SPACE((n_fds) * sizeof(int)) + sizeof(struct cmsghdr) - 1) /         \
   sizeof(struct cmsghdr))

/* [v_dst] is an encoded address, or empty for none. */
value uringan_sendmsg(value v_fd, value v_bufs, value v_n, value v_fds,
                      value v_dst) {
  int n = Int_val(v_n);
  int n_fds = Wosize_val(v_fds);
  struct iovec iov[n > 0 ? n : 1];
  struct cmsghdr control[n_fds > 0 ? CMSG_UNITS(n_fds) : 1];
  struct msghdr msg = {0};
  ssize_t r;

  uringan_iov_of_cstructs(v_bufs, iov, n);
  msg.msg_iov = iov;
  msg.msg_iovlen = n;
  if (caml_string_length(v_dst) > 0) {
    msg.msg_name = Bytes_val(v_dst);
    msg.msg_namelen = caml_string_length(v_dst);
  }
  if (n_fds > 0) {
    memset(control, 0, sizeof(control));
    msg.msg_control = control;
    msg.msg_controllen = CMSG_SPACE(n_fds * sizeof(int));
    struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type = SCM_RIGHTS;
    cm->cmsg_len = CMSG_LEN(n_fds * sizeof(int));
    int *fds = (int *)CMSG_DATA(cm);
    for (int i = 0; i < n_fds; i++) fds[i] = Int_val(Field(v_fds, i));
  }

  do
    r = sendmsg(Int_val(v_fd), &msg, MSG_NOSIGNAL);
  while (r == -1 && errno == EINTR);
  return Val_long(r == -1 ? -errno : r);
}

/* [v_msg] is a record
   [{ bufs; n_bufs; addr : Sockaddr.t option; fds : int array;
      mutable n_fds : int }]. Received descriptors are stored in [fds] and
   counted in [n_fds]. */
value uringan_recvmsg(value v_fd, value v_msg) {
  value v_bufs = Field(v_msg, 0);
  int n = Int_val(Field(v_msg, 1));
  value v_addr = Field(v_msg, 2);
  value v_fds = Field(v_msg, 3);
  int max_fds = Wosize_val(v_fds);
  struct iovec iov[n > 0 ? n : 1];
  struct cmsghdr control[max_fds > 0 ? CMSG_UNITS(max_fds) : 1];
  struct sockaddr_storage addr;
  struct msghdr msg = {0};
  int flags = 0;
  ssize_t r;

  uringan_iov_of_cstructs(v_bufs, iov, n);
  msg.msg_iov = iov;
  msg.msg_iovlen = n;
  if (Is_block(v_addr)) {
    msg.msg_name = &addr;
    msg.msg_namelen = sizeof(addr);
  }
  if (max_fds > 0) {
    msg.msg_control = control;
    msg.msg_controllen = CMSG_SPACE(max_fds * sizeof(int));
  }
#ifdef MSG_CMSG_CLOEXEC
  flags |= MSG_CMSG_CLOEXEC;
#endif

  do
    r = recvmsg(Int_val(v_fd), &msg, flags);
  while (r == -1 && errno == EINTR);
  if (r == -1) return Val_long(-errno);

  if (Is_block(v_addr)) {
    value v_peer = Field(v_addr, 0);
    memcpy(Bytes_val(Field(v_peer, 0)), &addr, msg.msg_namelen);
    Field(v_peer, 1) = Val_int(msg.msg_namelen);
  }
  int got = 0;
  for (struct cmsghdr *cm = max_fds > 0 ? CMSG_FIRSTHDR(&msg) : NULL;
       cm != NULL; cm = CMSG_NXTHDR(&msg, cm)) {
    if (cm->cmsg_level != SOL_SOCKET || cm->cmsg_type != SCM_RIGHTS) continue;
    int *fds = (int *)CMSG_DATA(cm);
    int k = (cm->cmsg_len - CMSG_LEN(0)) / sizeof(int);
    for (int i = 0; i < k; i++) {
      if (got < max_fds) {
#ifndef MSG_CMSG_CLOEXEC
        fcntl(fds[i], F_SETFD, FD_CLOEXEC);
#endif
        Field(v_fds, got++) = Val_int(fds[i]);
      } else
        close(fds[i]);
    }
  }
  Field(v_msg, 4) = Val_int(got);
  return Val_long(r);
}

value uringan_errno_einprogress(value v_unit) {
  (void)v_unit;
  return Val_int(EINPROGRESS);
}
