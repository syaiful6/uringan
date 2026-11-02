(** A wake-up channel for the poller: a descriptor that becomes readable when
    {!signal} is called, so a blocked {!Epoll.wait} or {!Kqueue.wait} returns.
    Internal to {!Uringan}.

    Backed by an eventfd where there is one, and by a self-pipe otherwise. *)

type t

val create : unit -> t
(** [create ()] is a new non-blocking, close-on-exec wake-up channel. *)

val close : t -> unit

val fd : t -> Unix.file_descr
(** [fd t] is the descriptor to register with the poller for readability. It
    stays readable once signalled, until drained. *)

val signal : t -> unit
(** [signal t] makes [fd t] readable. Safe to call from any thread or domain. *)

val drain : t -> bool
(** [drain t] makes [fd t] unreadable again, collapsing any number of pending
    signals into one. Returns [false] if [t] had not been signalled. *)
