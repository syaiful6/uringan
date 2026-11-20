(** A system thread pool for blocking operations. Internal to {!Uringan}.

    File-system operations cannot use readiness notifications, so the pool
    runs them outside the ring's thread. Tasks start in submission order but
    run concurrently and may finish in any order. Once {!fd} becomes readable,
    the ring's thread collects completed results with {!drain}.

    The pool starts threads as needed, up to [max_threads], and keeps them
    until {!shutdown}. The ring's thread calls {!submit}, {!cancel}, {!drain},
    and {!shutdown}; worker threads handle queued tasks. *)

type ('a, 'r) t
(** A pool whose tasks carry data of type ['a] and produce results of type
    ['r]. *)

type ('a, 'r) task
(** A submitted task. *)

val create : max_threads:int -> ('a, 'r) t
(** [create ~max_threads] is a pool that runs at most [max_threads] tasks at
    once. No thread is started until the first {!submit}.

    @raise Invalid_argument if [max_threads <= 0]
    @raise Unix.Unix_error if the notification channel cannot be created *)

val fd : _ t -> Unix.file_descr
(** [fd t] becomes readable when results are waiting to be {!drain}ed. *)

val submit : ('a, 'r) t -> (unit -> 'r) -> 'a -> ('a, 'r) task
(** [submit t f data] queues [f] for a worker thread. [f] must not raise and
    must release the runtime lock while blocked; otherwise it blocks the
    ring's thread too. *)

val cancel : _ task -> bool
(** [cancel task] cancels [task] if no worker has picked it up. Returns [false]
    if it has started; the pool will deliver its result normally. *)

val drain : ('a, 'r) t -> ('a -> 'r -> unit) -> unit
(** [drain t f] calls [f data result] for each task completed since the last
    [drain], in completion order. It skips cancelled tasks. *)

val shutdown : _ t -> unit
(** [shutdown t] stops the workers, waits for running tasks, and closes {!fd}.
    It drops queued tasks that have not started. *)
