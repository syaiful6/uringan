(** Thin bindings to Linux epoll. Internal to {!Uringan}. *)

type t = private Unix.file_descr

module Flags : sig
  type t = private int

  val empty : t
  val pollin : t
  val pollout : t
  val pollerr : t
  val pollhup : t
  val pollrdhup : t
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
  (** [fd t i] is the descriptor of the [i]th ready event.

      @raise Invalid_argument if [i] is out of bounds *)

  val flags : t -> int -> Flags.t
  (** [flags t i] is the set of events that occurred for the [i]th ready event.

      @raise Invalid_argument if [i] is out of bounds *)
end

val create : unit -> t
(** [create ()] is a new close-on-exec epoll instance. *)

val close : t -> unit

val add : t -> Unix.file_descr -> Flags.t -> unit
(** [add t fd flags] starts watching [fd] for [flags]. *)

val modify : t -> Unix.file_descr -> Flags.t -> unit
(** [modify t fd flags] replaces the flags watched on [fd]. Needed to re-arm a
    {!Flags.oneshot} registration. *)

val delete : t -> Unix.file_descr -> unit

val wait : t -> Events.t -> timeout_ms:int -> int
(** [wait t events ~timeout_ms] blocks, with the runtime lock released, until
    at least one event is ready or [timeout_ms] elapses ([-1] waits forever,
    [0] polls). Returns the number of events stored in [events], [0] on timeout
    or if interrupted by a signal. *)
