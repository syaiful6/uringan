#ifndef URINGAN_STUBS_H
#define URINGAN_STUBS_H

#include <sys/uio.h>

#include <caml/mlvalues.h>

/* Fill [iov] from a list of [n] Cstruct.t records {buffer; off; len}. */
void uringan_iov_of_cstructs(value v_bufs, struct iovec *iov, int n);

#endif
