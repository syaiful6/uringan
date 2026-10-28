external read_ba :
   Unix.file_descr
  -> Cstruct.buffer
  -> int
  -> int
  -> int
  -> int
  = "uringan_read"

external write_ba :
   Unix.file_descr
  -> Cstruct.buffer
  -> int
  -> int
  -> int
  -> int
  = "uringan_write"

external readv_ba :
   Unix.file_descr
  -> Cstruct.t list
  -> int
  -> int
  -> int
  = "uringan_readv"

external writev_ba :
   Unix.file_descr
  -> Cstruct.t list
  -> int
  -> int
  -> int
  = "uringan_writev"

external iov_max : unit -> int = "uringan_iov_max"
external poll : Unix.file_descr -> int -> int = "uringan_poll"
external pollin : unit -> int = "uringan_poll_flag_in"
external pollout : unit -> int = "uringan_poll_flag_out"
external pollerr : unit -> int = "uringan_poll_flag_err"
external pollhup : unit -> int = "uringan_poll_flag_hup"
external error_of_errno : int -> Unix.error = "uringan_error_of_errno"
external eagain : unit -> int = "uringan_errno_eagain"
external etime : unit -> int = "uringan_errno_etime"
external ecanceled : unit -> int = "uringan_errno_ecanceled"

let eagain = eagain ()
let etime = etime ()
let ecanceled = ecanceled ()
let iov_max = iov_max ()
let pollin = pollin ()
let pollout = pollout ()
let pollerr = pollerr ()
let pollhup = pollhup ()

let read fd ~file_offset { Cstruct.buffer; off; len } =
  read_ba fd buffer off len (Optint.Int63.to_int file_offset)

let write fd ~file_offset { Cstruct.buffer; off; len } =
  write_ba fd buffer off len (Optint.Int63.to_int file_offset)

let iov_length name bufs =
  let n = List.length bufs in
  if n > iov_max then invalid_arg (name ^ ": more than iov_max buffers");
  n

let readv fd ~file_offset bufs =
  readv_ba fd bufs (iov_length "readv" bufs) (Optint.Int63.to_int file_offset)

let writev fd ~file_offset bufs =
  writev_ba fd bufs (iov_length "writev" bufs) (Optint.Int63.to_int file_offset)
