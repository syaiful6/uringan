(** Thin bindings to Linux eventfd, used to wake a blocked [epoll_wait].
    Internal to {!Uringan}. *)

type t = private Unix.file_descr
(** A non-blocking, close-on-exec eventfd. It becomes readable once signalled
    and stays readable until drained. *)

val create : unit -> t
val close : t -> unit

val signal : t -> unit
(** [signal t] makes [t] readable. Safe to call from any thread or domain. *)

val drain : t -> bool
(** [drain t] makes [t] unreadable again, collapsing any number of pending
    signals into one. Returns [false] if [t] had not been signalled. *)
