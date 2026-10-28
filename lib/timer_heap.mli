(** A binary min-heap of values keyed by deadline, supporting removal of
    arbitrary entries. Internal to {!Uringan}. *)

type 'a t
type 'a entry

val create : unit -> 'a t
val length : _ t -> int

val add : 'a t -> int64 -> 'a -> 'a entry
(** [add t deadline v] inserts [v] and returns its entry, for {!remove}. *)

val min_deadline : _ t -> int64 option
(** [min_deadline t] is the earliest deadline in [t], if any. *)

val pop_expired : 'a t -> int64 -> 'a option
(** [pop_expired t now] removes and returns a value whose deadline is at or
    before [now], earliest first, or [None] if there is none. *)

val remove : 'a t -> 'a entry -> unit
(** [remove t e] removes [e] from [t]. Does nothing if [e] is no longer in
    [t]. *)
