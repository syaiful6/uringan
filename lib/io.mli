(** Non-raising read/write syscalls on Cstruct buffers. Internal to
    {!Uringan}.

    Results are the byte count, or a negative errno on failure. *)

val read : Unix.file_descr -> file_offset:Optint.Int63.t -> Cstruct.t -> int
(** [read fd ~file_offset buf] is [pread], or [read] if [file_offset] is
    [minus_one]. *)

val write : Unix.file_descr -> file_offset:Optint.Int63.t -> Cstruct.t -> int
(** [write fd ~file_offset buf] is [pwrite], or [write] if [file_offset] is
    [minus_one]. *)

val iov_max : int
(** The system's [IOV_MAX]. *)

val readv :
   Unix.file_descr
  -> file_offset:Optint.Int63.t
  -> Cstruct.t list
  -> int
(** [readv fd ~file_offset bufs] is [preadv], or [readv] if [file_offset] is
    [minus_one].

    @raise Invalid_argument if [bufs] has more than {!iov_max} elements *)

val writev :
   Unix.file_descr
  -> file_offset:Optint.Int63.t
  -> Cstruct.t list
  -> int
(** [writev fd ~file_offset bufs] is [pwritev], or [writev] if [file_offset]
    is [minus_one].

    @raise Invalid_argument if [bufs] has more than {!iov_max} elements *)

val poll : Unix.file_descr -> int -> int
(** [poll fd events] checks [fd] without blocking. Returns the ready events
    (a subset of [events], plus [pollerr]/[pollhup]), [-eagain] if none are
    ready, or [-EBADF] if [fd] is not open. *)

val pollin : int
val pollout : int
val pollerr : int
val pollhup : int

val eagain : int
(** [EAGAIN] (equal to [EWOULDBLOCK] on supported platforms). *)

val etime : int
val ecanceled : int

val error_of_errno : int -> Unix.error
(** [error_of_errno e] converts the positive errno [e]. *)
