(** Completion-based I/O on top of epoll (Linux) and kqueue (macOS/BSD).

    The interface follows {{:https://github.com/ocaml-multicore/ocaml-uring}
    ocaml-uring}, but operations are performed in user space:

    - Operations are queued, then attempted eagerly (non-blocking) by {!submit}.
    - An operation that fails with [EAGAIN] is parked on its file descriptor
      until epoll/kqueue reports readiness, then retried.
    - Operations on regular files and metadata operations (open, stat, fsync,
      unlink, ...) run synchronously inside {!submit} and may block the caller,
      since readiness notification does not apply to them.
    - Timeouts are kept in a user-space timer heap; the earliest deadline bounds
      the time spent blocked in [epoll_wait]/[kevent].

    Socket and pipe descriptors passed to this module must have [O_NONBLOCK]
    set by the caller. Descriptors returned by {!socket} and {!accept} already
    do.

    A ring is not thread-safe: only {!wakeup} may be called from another thread
    or domain.

    @see <https://tigerbeetle.com/blog/2022-11-23-a-friendly-abstraction-over-iouring-and-kqueue/>
    A Friendly Abstraction Over io_uring and kqueue *)

type 'a t
(** A ring whose operations carry user data of type ['a]. *)

type 'a job
(** A handle for a queued operation, which can be passed to {!cancel}. *)

type offset := Optint.Int63.t
(** A file offset. Use [Optint.Int63.minus_one] for the current file position;
    this is required for non-seekable descriptors (sockets, pipes, FIFOs). *)

(** The result of an operation. *)
module Res : sig
  type t

  val int_result : t -> (int, Unix.error) result
  (** [int_result t] is the operation's non-negative return value, or its
      error. *)

  val int_exn : t -> string -> string -> int
  (** [int_exn t fn arg] is like {!int_result} but raises
      [Unix.Unix_error (e, fn, arg)] on error. *)

  val fd_result : t -> (Unix.file_descr, Unix.error) result
  (** [fd_result t] is like {!int_result}, but returns the value as a file
      descriptor. *)

  val fd_exn : t -> string -> string -> Unix.file_descr
  (** [fd_exn t fn arg] is like {!int_exn}, but returns the value as a file
      descriptor. *)

  val pp : Format.formatter -> t -> unit
end

(** {2 Lifecycle} *)

val create : queue_depth:int -> unit -> 'a t
(** [create ~queue_depth ()] creates a ring backed by epoll or kqueue.

    [queue_depth] caps the number of operations in flight (queued, parked, or
    completed but not yet collected); operations beyond it are refused, giving
    backpressure.

    @raise Invalid_argument if [queue_depth <= 0]
    @raise Unix.Unix_error if the backend cannot be created *)

val queue_depth : _ t -> int
(** [queue_depth t] is the [queue_depth] given to {!create}. *)

val exit : _ t -> unit
(** [exit t] releases the backend descriptors of [t]. The ring cannot be used
    afterwards.

    @raise Invalid_argument if any operations are in flight (see
    {!active_ops}) *)

val backend : _ t -> [ `Epoll | `Kqueue ]
(** [backend t] is the readiness mechanism used by [t]. *)

(** {2 Queueing operations}

    Each function below queues an operation carrying user data [d], which is
    returned with the result by {!wait} or {!get_cqe_nonblocking}. They return
    [None] if [t] already has {!queue_depth} operations in flight. Nothing
    executes until {!submit} or {!wait} is called. *)

val noop : 'a t -> 'a -> 'a job option
(** [noop t d] completes with result [0] on the next {!submit}. *)

(** {3 Timeouts} *)

val now : unit -> int64
(** [now ()] is the current monotonic time in nanoseconds. *)

val etime : Unix.error
(** [ETIME], the error a {!timeout} completes with. [Unix.error] has no
    constructor for it, so this is an [EUNKNOWNERR]. *)

val timeout : ?absolute:bool -> 'a t -> int64 -> 'a -> 'a job option
(** [timeout t ns d] completes with [Error etime] once [ns] nanoseconds have
    passed since it was submitted. Timeouts are kept in user space, and expire
    during {!wait} or {!get_cqe_nonblocking}, with millisecond resolution.

    @param absolute
      if [true], [ns] is a deadline on the {!now} clock rather than a duration
      (default [false]) *)

(** {3 Polling} *)

module Poll_mask : sig
  type t = private int

  val empty : t
  val pollin : t
  val pollout : t
  val pollerr : t
  val pollhup : t

  val of_int : int -> t
  (** [of_int n] reads a {!poll_add} result as a mask. *)

  val ( + ) : t -> t -> t

  val mem : t -> t -> bool
  (** [mem x t] is [true] if all flags in [x] are set in [t]. *)
end

val poll_add : 'a t -> Unix.file_descr -> Poll_mask.t -> 'a -> 'a job option
(** [poll_add t fd mask d] completes when [fd] is ready for an event in
    [mask]. The result is the set of events that occurred, as a
    {!Poll_mask.t}. *)

(** {3 Reading and writing}

    Reads and writes on sockets and pipes are retried on readiness; on regular
    files they run synchronously. A completed read returns the number of bytes
    read, [0] at end of file. *)

val read :
   'a t
  -> file_offset:offset
  -> Unix.file_descr
  -> Cstruct.t
  -> 'a
  -> 'a job option
(** [read t ~file_offset fd buf d] reads from [fd] into [buf], using [pread]
    unless [file_offset] is [minus_one]. *)

val write :
   'a t
  -> file_offset:offset
  -> Unix.file_descr
  -> Cstruct.t
  -> 'a
  -> 'a job option
(** [write t ~file_offset fd buf d] writes [buf] to [fd], using [pwrite] unless
    [file_offset] is [minus_one]. *)

val iov_max : int
(** The maximum number of buffers accepted by {!readv}, {!writev} and
    {!Msghdr.create}. *)

val readv :
   'a t
  -> file_offset:offset
  -> Unix.file_descr
  -> Cstruct.t list
  -> 'a
  -> 'a job option
(** [readv] is like {!read} but scatters into several buffers.

    Requires [List.length bufs <= iov_max].
    An empty list completes with [0] without a syscall. *)

val writev :
   'a t
  -> file_offset:offset
  -> Unix.file_descr
  -> Cstruct.t list
  -> 'a
  -> 'a job option
(** [writev] is like {!write} but gathers from several buffers.

    Requires [List.length bufs <= iov_max].
    An empty list completes with [0] without a syscall. *)

(** {3 Files and directories}

    These run synchronously in {!submit}. Where [?fd]/[?dir_fd] is omitted,
    relative paths are resolved against the current directory. *)

val openat :
   'a t
  -> ?dir_fd:Unix.file_descr
  -> Unix.open_flag list
  -> Unix.file_perm
  -> string
  -> 'a
  -> 'a job option
(** [openat t ?dir_fd flags perm path d] opens [path]. The result is the new
    descriptor (see {!Res.fd_result}). As with [Unix.openfile], the descriptor
    is close-on-exec if [flags] contains [O_CLOEXEC], or if it does not contain
    [O_KEEPEXEC] and [Unix]'s close-on-exec default is set. *)

val close : 'a t -> Unix.file_descr -> 'a -> 'a job option
(** [close t fd d] closes [fd]. Operations still parked on [fd] are completed
    with [Error ecanceled] first, in the order they were submitted. *)

val fsync : 'a t -> Unix.file_descr -> 'a -> 'a job option

val fdatasync : 'a t -> Unix.file_descr -> 'a -> 'a job option
(** [fdatasync] falls back to [fsync] where [fdatasync] is unavailable
    (macOS). *)

val ftruncate : 'a t -> Unix.file_descr -> len:int64 -> 'a -> 'a job option

val unlink :
   'a t
  -> dir:bool
  -> ?fd:Unix.file_descr
  -> string
  -> 'a
  -> 'a job option
(** [unlink t ~dir ?fd path d] removes [path]; a directory if [dir] is [true]. *)

val mkdirat :
   'a t
  -> mode:Unix.file_perm
  -> ?fd:Unix.file_descr
  -> string
  -> 'a
  -> 'a job option

val renameat :
   'a t
  -> ?old_dir_fd:Unix.file_descr
  -> string
  -> ?new_dir_fd:Unix.file_descr
  -> string
  -> 'a
  -> 'a job option
(** [renameat t ?old_dir_fd old_path ?new_dir_fd new_path d] renames
    [old_path] to [new_path]. *)

val linkat :
   'a t
  -> follow:bool
  -> ?old_dir_fd:Unix.file_descr
  -> old_path:string
  -> ?new_dir_fd:Unix.file_descr
  -> new_path:string
  -> 'a
  -> 'a job option
(** [linkat t ~follow ~old_path ~new_path d] creates a hard link [new_path] to
    [old_path], dereferencing [old_path] if it is a symlink and [follow] is
    [true]. *)

val symlinkat :
   'a t
  -> target:string
  -> ?dir_fd:Unix.file_descr
  -> link_path:string
  -> 'a
  -> 'a job option
(** [symlinkat t ~target ~link_path d] creates a symlink at [link_path]
    pointing to [target]. *)

(** Holder for the result of {!fstatat}. *)
module Stat : sig
  type t

  type kind =
    [ `Regular_file
    | `Directory
    | `Symbolic_link
    | `Character_special
    | `Block_device
    | `Fifo
    | `Socket
    | `Unknown
    ]

  val create : unit -> t
  val kind : t -> kind
  val perm : t -> int
  val size : t -> int64
  val ino : t -> int64
  val dev : t -> int64
  val rdev : t -> int64
  val nlink : t -> int64
  val uid : t -> int64
  val gid : t -> int64
  val blksize : t -> int64
  val blocks : t -> int64
  val atime_sec : t -> int64
  val atime_nsec : t -> int
  val mtime_sec : t -> int64
  val mtime_nsec : t -> int
  val ctime_sec : t -> int64
  val ctime_nsec : t -> int
end

val fstatat :
   'a t
  -> ?fd:Unix.file_descr
  -> follow:bool
  -> string
  -> Stat.t
  -> 'a
  -> 'a job option
(** [fstatat t ?fd ~follow path stat d] stores the status of [path] in [stat].
    If [path] is [""], [fd] itself is examined. *)

(** {3 Sockets}

    {!socket}, {!bind}, {!listen} and {!shutdown} run synchronously. Addresses
    passed to {!bind}, {!connect} and {!send_msg} are converted when the
    operation is queued, so an invalid one (such as a Unix domain path that is
    too long) raises [Unix.Unix_error] immediately rather than completing with
    an error. *)

val socket :
   ?cloexec:bool
  -> 'a t
  -> Unix.socket_domain
  -> Unix.socket_type
  -> int
  -> 'a
  -> 'a job option
(** [socket t domain ty protocol d] creates a non-blocking socket. The result is
    the new descriptor.

    @param cloexec set close-on-exec (default [true]) *)

val bind : 'a t -> Unix.file_descr -> Unix.sockaddr -> 'a -> 'a job option
val listen : 'a t -> Unix.file_descr -> int -> 'a -> 'a job option

val connect : 'a t -> Unix.file_descr -> Unix.sockaddr -> 'a -> 'a job option
(** [connect t fd addr d] connects [fd] to [addr]. [EINPROGRESS] is handled
    internally by waiting for writability and reading [SO_ERROR]. *)

(** Holder for the peer address filled in by {!accept} or {!recv_msg}. *)
module Sockaddr : sig
  type t

  val create : unit -> t

  val get : t -> Unix.sockaddr
  (** @raise Invalid_argument if no address has been stored yet *)
end

val accept : 'a t -> Unix.file_descr -> Sockaddr.t -> 'a -> 'a job option
(** [accept t fd addr d] accepts a connection on the listening socket [fd],
    storing the peer address in [addr]. The result is the new descriptor, which
    is non-blocking and close-on-exec. *)

val shutdown :
   'a t
  -> Unix.file_descr
  -> Unix.shutdown_command
  -> 'a
  -> 'a job option

(** Holder for {!recv_msg}'s buffers, peer address and received descriptors. *)
module Msghdr : sig
  type t

  val create : ?n_fds:int -> ?addr:Sockaddr.t -> Cstruct.t list -> t
  (** [create ?n_fds ?addr bufs] receives into [bufs] and up to [n_fds]
      descriptors (default [0]).

      Requires [List.length bufs <= iov_max]. *)

  val get_fds : t -> Unix.file_descr list
  (** [get_fds t] is the descriptors received, which are close-on-exec. *)
end

val send_msg :
   ?fds:Unix.file_descr list
  -> ?dst:Unix.sockaddr
  -> 'a t
  -> Unix.file_descr
  -> Cstruct.t list
  -> 'a
  -> 'a job option
(** [send_msg ?fds ?dst t fd bufs d] sends [bufs] and [fds] (via
    [SCM_RIGHTS]) on [fd], to [dst] if given. Sending on a socket whose peer
    has closed completes with [Error EPIPE] instead of raising [SIGPIPE].

    Requires [List.length bufs <= iov_max]. *)

val recv_msg : 'a t -> Unix.file_descr -> Msghdr.t -> 'a -> 'a job option

(** {3 Cancellation} *)

val ecanceled : Unix.error
(** [ECANCELED], the error a cancelled operation completes with. [Unix.error]
    has no constructor for it, so this is an [EUNKNOWNERR]. *)

val cancel : 'a t -> 'a job -> 'a -> 'a job option
(** [cancel t job d] cancels [job] on the next {!submit}. Both operations
    produce a completion: if [job] was still waiting (parked on a descriptor,
    or a pending {!timeout}) it completes with [Error ecanceled] and the cancel
    with [0]; if it had already completed, the cancel completes with
    [Error ENOENT].

    @raise Invalid_argument
      if [job]'s completion has already been collected *)

(** {2 Completions} *)

val submit : _ t -> int
(** [submit t] attempts all queued operations, completing those that do not
    block and parking the rest. Returns the number of operations taken off the
    queue. *)

type 'a completion_option =
  | None
  | Some of
      { result : Res.t
      ; data : 'a
      }

val wait : ?timeout:float -> 'a t -> 'a completion_option
(** [wait ?timeout t] calls {!submit}, then returns the next completion,
    blocking for up to [timeout] seconds (default: indefinitely) for parked
    operations to become ready or timers to expire. Returns [None] on timeout
    or after a {!wakeup}. *)

val get_cqe_nonblocking : 'a t -> 'a completion_option
(** [get_cqe_nonblocking t] is like {!wait} but never blocks. *)

val wakeup : _ t -> unit
(** [wakeup t] makes a {!wait} in progress (or the next one) return. It is the
    only function safe to call from another thread or domain. Implemented with
    an eventfd on Linux and a self-pipe elsewhere. *)

val active_ops : _ t -> int
(** [active_ops t] is the number of operations in flight: queued, parked, or
    completed but not yet collected. *)

val sqe_ready : _ t -> int
(** [sqe_ready t] is the number of operations queued but not yet submitted. *)

(**/**)

(** Internal modules, exposed for testing only. *)
module Private : sig
  [%%import "config.h"]
  [%%ifdef USE_EPOLL]

  module Poller = Epoll

  [%%else]

  module Poller = Kqueue

  [%%endif]

  module Waker = Waker
  module Timer_heap = Timer_heap
end
