(** Non-raising socket syscalls. Internal to {!Uringan}.

    Like {!Io}, results are a non-negative value or a negative errno. Sockets
    are assumed to be non-blocking, so none of these block. *)

type addr
(** An address encoded as a C [struct sockaddr]. *)

val encode : Unix.sockaddr -> addr
(** @raise Unix.Unix_error if the address cannot be encoded (for example, a
    Unix domain path that is too long). *)

val no_addr : addr
(** Stands for "no destination" in {!send_msg}. *)

type peer
(** A peer address filled in by {!accept} or {!recv_msg}. *)

val peer : unit -> peer

val decode : peer -> Unix.sockaddr option
(** [decode p] is the stored address, or [None] if none has been stored. *)

type msghdr
(** Buffers, optional peer address and descriptor slots for {!recv_msg}. *)

val msghdr : n_fds:int -> peer option -> Cstruct.t list -> msghdr
val received_fds : msghdr -> Unix.file_descr list

val socket :
   cloexec:bool
  -> Unix.socket_domain
  -> Unix.socket_type
  -> int
  -> int
(** [socket ~cloexec domain ty proto] creates a non-blocking socket. *)

val bind : Unix.file_descr -> addr -> int
val listen : Unix.file_descr -> int -> int
val shutdown : Unix.file_descr -> Unix.shutdown_command -> int

val connect : Unix.file_descr -> addr -> int
(** [connect fd addr] is [0], [-einprogress] if the connection is being
    established in the background, or another error. *)

val connect_finish : Unix.file_descr -> int
(** [connect_finish fd] is the outcome of a connection in progress on [fd]:
    [-eagain] while it is still pending, then [0] or its error. *)

val accept : Unix.file_descr -> peer -> int
(** [accept fd peer] returns a non-blocking, close-on-exec descriptor. *)

val send_msg :
   Unix.file_descr
  -> Cstruct.t list
  -> Unix.file_descr array
  -> addr
  -> int
(** [send_msg fd bufs fds dst] is [sendmsg] with [MSG_NOSIGNAL], so a closed
    peer gives [EPIPE] rather than [SIGPIPE].

    @raise Invalid_argument if [bufs] has more than {!Io.iov_max} elements *)

val recv_msg : Unix.file_descr -> msghdr -> int
val einprogress : int
