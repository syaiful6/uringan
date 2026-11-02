(** Thin bindings to BSD kqueue, shaped like {!Epoll}. Internal to {!Uringan}.

    Interest is one filter per direction rather than a flag word, so
    {!Flags} are bits of this library's own, translated in [kqueue_stubs.c].
    Empty unless the kqueue backend was selected; see
    {!Uringan.Private.Poller} for the one that is in use. *)

[%%import "config.h"]
[%%ifdef USE_KQUEUE]

type t = private Unix.file_descr

module Flags : sig
  type t = private int

  val empty : t
  val pollin : t
  val pollout : t
  val pollerr : t

  val pollhup : t
  (** Set when [EV_EOF] is reported for the write direction. *)

  val pollrdhup : t
  (** Set when [EV_EOF] is reported for the read direction. kqueue cannot tell
      a half-closed stream from a fully closed one, so this stands in for
      epoll's [EPOLLHUP] on a pipe as well. *)

  val oneshot : t
  val ( + ) : t -> t -> t

  val mem : t -> t -> bool
  (** [mem x t] is [true] if all flags in [x] are set in [t]. *)
end

(** A reusable buffer that {!wait} fills with ready events. *)
module Events : sig
  type t

  val create : int -> t
  (** [create n] can hold up to [n] events per {!wait}.

      @raise Invalid_argument if [n <= 0] *)

  val length : t -> int

  val fd : t -> int -> Unix.file_descr
  (** [fd t i] is the descriptor of the [i]th ready event. Unlike epoll, kqueue
      reports each direction of a descriptor separately, so the same descriptor
      can appear twice in one {!wait}.

      @raise Invalid_argument if [i] is out of bounds *)

  val flags : t -> int -> Flags.t
  (** [flags t i] is the set of events that occurred for the [i]th ready event.

      @raise Invalid_argument if [i] is out of bounds *)
end

val create : unit -> t
(** [create ()] is a new close-on-exec kqueue instance. *)

val close : t -> unit

val add : t -> Unix.file_descr -> Flags.t -> unit
(** [add t fd flags] starts watching [fd] for [flags]. *)

val modify : t -> Unix.file_descr -> Flags.t -> unit
(** [modify t fd flags] replaces the flags watched on [fd]. Needed to re-arm a
    {!Flags.oneshot} registration. Unlike {!Epoll.modify} this also registers a
    descriptor that is not watched yet, rather than failing with [ENOENT]. *)

val delete : t -> Unix.file_descr -> unit
(** [delete t fd] stops watching [fd].

    @raise Unix.Unix_error [ENOENT] if [fd] was not watched in either
      direction. *)

val wait : t -> Events.t -> timeout_ms:int -> int
(** [wait t events ~timeout_ms] blocks, with the runtime lock released, until
    at least one event is ready or [timeout_ms] elapses ([-1] waits forever,
    [0] polls). Returns the number of events stored in [events], [0] on timeout
    or if interrupted by a signal. *)

[%%endif]
