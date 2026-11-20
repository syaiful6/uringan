(* A task moves from [Pending] to [Running] when a worker takes it, or to
   [Cancelled] when the ring cancels it. The successful compare-and-set decides
   which transition wins. These constructors are immediate, so physical equality
   is sufficient. *)
type status =
  | Pending
  | Running
  | Cancelled

type ('a, 'r) task =
  { run : unit -> 'r
  ; data : 'a
  ; status : status Atomic.t
  }

type ('a, 'r) t =
  { mutex : Mutex.t
  ; work : Condition.t  (** Signalled for new work and shutdown. *)
  ; pending : ('a, 'r) task Queue.t
  ; finished : ('a * 'r) Queue.t
  ; waker : Waker.t  (** Readable when [finished] may contain results. *)
  ; max_threads : int
  ; mutable threads : Thread.t list
  ; mutable n_threads : int
  ; mutable idle : int  (** Number of workers blocked on [work]. *)
  ; mutable stopping : bool
  }
(* [mutex] protects every mutable field and both queues. *)

let create ~max_threads =
  if max_threads <= 0 then invalid_arg "Thread_pool.create: max_threads <= 0";
  { mutex = Mutex.create ()
  ; work = Condition.create ()
  ; pending = Queue.create ()
  ; finished = Queue.create ()
  ; waker = Waker.create ()
  ; max_threads
  ; threads = []
  ; n_threads = 0
  ; idle = 0
  ; stopping = false
  }

let fd t = Waker.fd t.waker

(* Return the next task, or [None] while stopping. *)
let next t =
  Mutex.protect t.mutex @@ fun () ->
  while Queue.is_empty t.pending && not t.stopping do
    t.idle <- t.idle + 1;
    Condition.wait t.work t.mutex;
    t.idle <- t.idle - 1
  done;
  if t.stopping then None else Some (Queue.take t.pending)

let rec worker t =
  match next t with
  | None -> ()
  | Some task ->
    if Atomic.compare_and_set task.status Pending Running
    then begin
      let r = task.run () in
      Mutex.protect t.mutex (fun () -> Queue.push (task.data, r) t.finished);
      (* Push before signalling so [drain] cannot consume the signal before the
         result is visible. *)
      Waker.signal t.waker
    end;
    worker t

let submit t run data =
  let task = { run; data; status = Atomic.make Pending } in
  Mutex.protect t.mutex (fun () ->
    Queue.push task t.pending;
    Condition.signal t.work;
    (* Start a thread only when the pending queue exceeds the idle workers. *)
    if Queue.length t.pending > t.idle && t.n_threads < t.max_threads
    then begin
      t.threads <- Thread.create worker t :: t.threads;
      t.n_threads <- t.n_threads + 1
    end);
  task

let cancel task = Atomic.compare_and_set task.status Pending Cancelled

let drain t f =
  (* Drain the signal first. A later result will produce another signal. *)
  ignore (Waker.drain t.waker : bool);
  let finished =
    Mutex.protect t.mutex (fun () ->
      let q = Queue.copy t.finished in
      Queue.clear t.finished;
      q)
  in
  Queue.iter (fun (data, r) -> f data r) finished

let shutdown t =
  let threads =
    Mutex.protect t.mutex (fun () ->
      t.stopping <- true;
      Condition.broadcast t.work;
      t.threads)
  in
  List.iter Thread.join threads;
  Waker.close t.waker
