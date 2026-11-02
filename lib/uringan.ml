(* Which poller backs the ring. Both modules present the same interface; the one
   that was not selected is compiled away to nothing. See lib/config/discover.ml
   for the detection and config.h for the result. *)
[%%import "config.h"]
[%%ifdef USE_EPOLL]

module Poller = Epoll

[%%else]

module Poller = Kqueue

[%%endif]

(* A syscall that can be retried until it no longer returns [EAGAIN]. *)
type io =
  | Noop
  | Sync of (unit -> int) (* Never blocks or parks. *)
  | Read of
      { fd : Unix.file_descr
      ; file_offset : Optint.Int63.t
      ; buf : Cstruct.t
      }
  | Write of
      { fd : Unix.file_descr
      ; file_offset : Optint.Int63.t
      ; buf : Cstruct.t
      }
  | Readv of
      { fd : Unix.file_descr
      ; file_offset : Optint.Int63.t
      ; bufs : Cstruct.t list
      }
  | Writev of
      { fd : Unix.file_descr
      ; file_offset : Optint.Int63.t
      ; bufs : Cstruct.t list
      }
  | Poll of
      { fd : Unix.file_descr
      ; mask : int
      }
  | Connect of
      { fd : Unix.file_descr
      ; addr : Sock.addr
      }
  | Connect_finish of Unix.file_descr (* A [Connect] in progress. *)
  | Accept of
      { fd : Unix.file_descr
      ; peer : Sock.peer
      }
  | Send_msg of
      { fd : Unix.file_descr
      ; bufs : Cstruct.t list
      ; fds : Unix.file_descr array
      ; dst : Sock.addr
      }
  | Recv_msg of
      { fd : Unix.file_descr
      ; msg : Sock.msghdr
      }

(* Which of a descriptor's queues an operation waits in. *)
type dir =
  [ `Read
  | `Write
  | `Poll
  ]

type 'a job =
  { op : 'a op
  ; data : 'a
  ; mutable state : 'a state
  }

and 'a op =
  | Io of io
  | Timeout of
      { ns : int64
      ; absolute : bool
      }
  | Cancel of 'a job
  | Close of Unix.file_descr

and 'a state =
  | Queued
  | Parked of Unix.file_descr * dir
  | Sleeping of 'a job Timer_heap.entry
  | Completed (* In [cq], not yet collected. *)
  | Collected

type 'a parked =
  { job : 'a job
  ; io : io
  }

(* Operations parked on one descriptor, in submission order. Only the head of
   [readers] and [writers] is retried, so a stream is read or written in order.
   [pollers] consume nothing, so all of them are rechecked on every event. *)
type 'a waiters =
  { readers : 'a parked Queue.t
  ; writers : 'a parked Queue.t
  ; pollers : 'a parked Queue.t
  ; mutable armed : Poller.Flags.t
    (* The one-shot interest registered with the poller that has not fired
       yet. *)
  }

module Res = struct
  type t = (int, Unix.error) result

  external fd_of_int : int -> Unix.file_descr = "%identity"

  let of_syscall n = if n >= 0 then Ok n else Error (Io.error_of_errno (-n))
  let int_result t = t

  let int_exn t fn arg =
    match t with Ok n -> n | Error e -> raise (Unix.Unix_error (e, fn, arg))

  let fd_result t = Result.map fd_of_int t
  let fd_exn t fn arg = fd_of_int (int_exn t fn arg)

  let pp ppf = function
    | Ok n -> Format.pp_print_int ppf n
    | Error e -> Format.pp_print_string ppf (Unix.error_message e)
end

type 'a t =
  { poller : Poller.t
  ; events : Poller.Events.t
  ; wakeup : Waker.t
  ; queue_depth : int
  ; sq : 'a job Queue.t  (** Queued, not yet attempted. *)
  ; cq : ('a job * Res.t) Queue.t  (** Completed, not yet collected. *)
  ; parked : (Unix.file_descr, 'a waiters) Hashtbl.t
  ; timers : 'a job Timer_heap.t
  ; mutable in_flight : int
  ; mutable closed : bool
  }

let create ~queue_depth () =
  if queue_depth <= 0 then invalid_arg "Uringan.create: queue_depth <= 0";
  let poller = Poller.create () in
  match Waker.create () with
  | exception e ->
    Poller.close poller;
    raise e
  | wakeup ->
    (try Poller.add poller (Waker.fd wakeup) Poller.Flags.pollin with
    | e ->
      Waker.close wakeup;
      Poller.close poller;
      raise e);
    { poller
    ; (* At most one event per parked descriptor, plus the waker. kqueue reports
         a descriptor's two directions separately, so a wait can occasionally
         fill this and leave the remainder queued for the next one. *)
      events = Poller.Events.create (queue_depth + 1)
    ; wakeup
    ; queue_depth
    ; sq = Queue.create ()
    ; cq = Queue.create ()
    ; parked = Hashtbl.create 16
    ; timers = Timer_heap.create ()
    ; in_flight = 0
    ; closed = false
    }

let check t = if t.closed then invalid_arg "Uringan: ring used after exit"
let queue_depth t = t.queue_depth

let exit t =
  if not t.closed
  then begin
    if t.in_flight > 0
    then
      invalid_arg
        (Printf.sprintf "Uringan.exit: %d operation(s) in flight" t.in_flight);
    t.closed <- true;
    Waker.close t.wakeup;
    Poller.close t.poller
  end

[%%ifdef USE_EPOLL]

let backend _ = `Epoll

[%%else]

let backend _ = `Kqueue

[%%endif]

let enqueue t op data =
  check t;
  if t.in_flight >= t.queue_depth
  then None
  else begin
    let job = { op; data; state = Queued } in
    Queue.push job t.sq;
    t.in_flight <- t.in_flight + 1;
    Some job
  end

let noop t data = enqueue t (Io Noop) data

external now :
   unit
  -> (int64[@unboxed])
  = "uringan_clock_now" "uringan_clock_now_unboxed"
[@@noalloc]

let etime = Io.error_of_errno Io.etime
let ecanceled = Io.error_of_errno Io.ecanceled

let timeout ?(absolute = false) t ns data =
  enqueue t (Timeout { ns; absolute }) data

module Poll_mask = struct
  type t = int

  let empty = 0
  let pollin = Io.pollin
  let pollout = Io.pollout
  let pollerr = Io.pollerr
  let pollhup = Io.pollhup
  let of_int t = t
  let ( + ) = ( lor )
  let mem x t = x land t = x
end

let poll_add t fd mask data = enqueue t (Io (Poll { fd; mask })) data

let read t ~file_offset fd buf data =
  enqueue t (Io (Read { fd; file_offset; buf })) data

let write t ~file_offset fd buf data =
  enqueue t (Io (Write { fd; file_offset; buf })) data

let iov_max = Io.iov_max

let check_iov name bufs =
  if List.compare_length_with bufs iov_max > 0
  then invalid_arg (Printf.sprintf "Uringan.%s: more than iov_max buffers" name)

let readv t ~file_offset fd bufs data =
  check_iov "readv" bufs;
  enqueue t (Io (Readv { fd; file_offset; bufs })) data

let writev t ~file_offset fd bufs data =
  check_iov "writev" bufs;
  enqueue t (Io (Writev { fd; file_offset; bufs })) data

let sync t f data = enqueue t (Io (Sync f)) data

let openat t ?dir_fd flags perm path data =
  sync t (fun () -> Fs.openat dir_fd path flags perm) data

let close t fd data = enqueue t (Close fd) data
let fsync t fd data = sync t (fun () -> Fs.fsync fd ~data_only:false) data
let fdatasync t fd data = sync t (fun () -> Fs.fsync fd ~data_only:true) data
let ftruncate t fd ~len data = sync t (fun () -> Fs.ftruncate fd len) data

let unlink t ~dir ?fd path data =
  sync t (fun () -> Fs.unlinkat fd path ~dir) data

let mkdirat t ~mode ?fd path data =
  sync t (fun () -> Fs.mkdirat fd path mode) data

let renameat t ?old_dir_fd old_path ?new_dir_fd new_path data =
  sync t (fun () -> Fs.renameat old_dir_fd old_path new_dir_fd new_path) data

let linkat t ~follow ?old_dir_fd ~old_path ?new_dir_fd ~new_path data =
  sync
    t
    (fun () -> Fs.linkat old_dir_fd old_path new_dir_fd new_path ~follow)
    data

let symlinkat t ~target ?dir_fd ~link_path data =
  sync t (fun () -> Fs.symlinkat target dir_fd link_path) data

module Stat = struct
  include Fs.Stat

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

  let kinds =
    [| `Regular_file
     ; `Directory
     ; `Symbolic_link
     ; `Character_special
     ; `Block_device
     ; `Fifo
     ; `Socket
     ; `Unknown
    |]

  let kind t : kind = kinds.(kind t)
end

let fstatat t ?fd ~follow path stat data =
  sync t (fun () -> Fs.fstatat fd path ~follow stat) data

let socket ?(cloexec = true) t domain ty protocol data =
  sync t (fun () -> Sock.socket ~cloexec domain ty protocol) data

let bind t fd addr data =
  let addr = Sock.encode addr in
  sync t (fun () -> Sock.bind fd addr) data

let listen t fd backlog data = sync t (fun () -> Sock.listen fd backlog) data
let shutdown t fd cmd data = sync t (fun () -> Sock.shutdown fd cmd) data

let connect t fd addr data =
  enqueue t (Io (Connect { fd; addr = Sock.encode addr })) data

module Sockaddr = struct
  type t = Sock.peer

  let create = Sock.peer

  let get t =
    match Sock.decode t with
    | Option.Some a -> a
    | Option.None -> invalid_arg "Uringan.Sockaddr.get: no address stored"
end

let accept t fd peer data = enqueue t (Io (Accept { fd; peer })) data

module Msghdr = struct
  type t = Sock.msghdr

  let create ?(n_fds = 0) ?addr bufs =
    check_iov "Msghdr.create" bufs;
    Sock.msghdr ~n_fds addr bufs

  let get_fds = Sock.received_fds
end

let send_msg ?(fds = []) ?dst t fd bufs data =
  check_iov "send_msg" bufs;
  let dst =
    match dst with
    | Option.None -> Sock.no_addr
    | Option.Some a -> Sock.encode a
  in
  enqueue t (Io (Send_msg { fd; bufs; fds = Array.of_list fds; dst })) data

let recv_msg t fd msg data = enqueue t (Io (Recv_msg { fd; msg })) data

let cancel t job data =
  (match job.state with
  | Collected -> invalid_arg "Uringan.cancel: job already collected"
  | Queued | Parked _ | Sleeping _ | Completed -> ());
  enqueue t (Cancel job) data

(* [perform io] runs the syscall for [io]: a non-negative result or a negative
   errno. *)
let perform = function
  | Noop -> 0
  | Read { fd; file_offset; buf } -> Io.read fd ~file_offset buf
  | Write { fd; file_offset; buf } -> Io.write fd ~file_offset buf
  | Readv { fd; file_offset; bufs } -> Io.readv fd ~file_offset bufs
  | Writev { fd; file_offset; bufs } -> Io.writev fd ~file_offset bufs
  | Poll { fd; mask } -> Io.poll fd mask
  | Sync f -> f ()
  | Connect { fd; addr } -> Sock.connect fd addr
  | Connect_finish fd -> Sock.connect_finish fd
  | Accept { fd; peer } -> Sock.accept fd peer
  | Send_msg { fd; bufs; fds; dst } -> Sock.send_msg fd bufs fds dst
  | Recv_msg { fd; msg } -> Sock.recv_msg fd msg

(* The descriptor an operation blocks on, and which queue it waits in. [Connect]
   has none: it starts the connection and parks as [Connect_finish]. *)
let wait_target = function
  | Noop | Sync _ | Connect _ -> None
  | Read { fd; _ } | Readv { fd; _ } | Accept { fd; _ } | Recv_msg { fd; _ } ->
    Some (fd, `Read)
  | Write { fd; _ } | Writev { fd; _ } | Connect_finish fd | Send_msg { fd; _ }
    ->
    Some (fd, `Write)
  | Poll { fd; _ } -> Some (fd, `Poll)

(* Where to park [io] after it returned [n], if it would block. *)
let blocked io n =
  if n = -Io.eagain
  then Option.map (fun (fd, dir) -> fd, dir, io) (wait_target io)
  else
    match io with
    | Connect { fd; _ } when n = -Sock.einprogress ->
      Some (fd, `Write, Connect_finish fd)
    | Noop | Sync _ | Read _ | Write _ | Readv _ | Writev _ | Poll _ | Connect _
    | Connect_finish _ | Accept _ | Send_msg _ | Recv_msg _ ->
      None

let complete t job res =
  job.state <- Completed;
  Queue.push (job, res) t.cq

let queue_of w = function
  | `Read -> w.readers
  | `Write -> w.writers
  | `Poll -> w.pollers

let is_idle w =
  Queue.is_empty w.readers
  && Queue.is_empty w.writers
  && Queue.is_empty w.pollers

(* Both backends always report errors and hang-ups; [pollerr] is included only
   so that an [interest] is empty exactly when [w] is idle. *)
let interest w =
  let open Poller.Flags in
  let poller p acc =
    match p.io with
    | Poll { mask; _ } ->
      acc
      + (if Poll_mask.mem Poll_mask.pollin mask then pollin else empty)
      + if Poll_mask.mem Poll_mask.pollout mask then pollout else empty
    | Noop | Sync _ | Read _ | Write _ | Readv _ | Writev _ | Connect _
    | Connect_finish _ | Accept _ | Send_msg _ | Recv_msg _ ->
      acc
  in
  if is_idle w
  then empty
  else
    Queue.fold (Fun.flip poller) pollerr w.pollers
    + (if Queue.is_empty w.readers then empty else pollin)
    + if Queue.is_empty w.writers then empty else pollout

(* Re-arm the poller for whatever [w] is still waiting for. The registration
   outlives empty [waiters], so try [modify] before [add]. *)
let arm t fd w =
  let flags = interest w in
  if flags <> w.armed
  then begin
    let flags' = Poller.Flags.(flags + oneshot) in
    (try Poller.modify t.poller fd flags' with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Poller.add t.poller fd flags');
    w.armed <- flags
  end

let fail_all t fd w err =
  let fail p = complete t p.job (Error err) in
  Queue.iter fail w.readers;
  Queue.iter fail w.writers;
  Queue.iter fail w.pollers;
  Hashtbl.remove t.parked fd

let rearm t fd w =
  if is_idle w
  then Hashtbl.remove t.parked fd
  else
    match arm t fd w with
    | () -> ()
    | exception Unix.Unix_error (err, _, _) -> fail_all t fd w err

let park t fd dir job io =
  let w =
    match Hashtbl.find_opt t.parked fd with
    | Some w -> w
    | None ->
      let w =
        { readers = Queue.create ()
        ; writers = Queue.create ()
        ; pollers = Queue.create ()
        ; armed = Poller.Flags.empty
        }
      in
      Hashtbl.replace t.parked fd w;
      w
  in
  job.state <- Parked (fd, dir);
  Queue.push { job; io } (queue_of w dir);
  rearm t fd w

let has_waiters t fd dir =
  match Hashtbl.find_opt t.parked fd with
  | None -> false
  | Some w -> not (Queue.is_empty (queue_of w dir))

let attempt_io t job io =
  match wait_target io with
  | Some (fd, ((`Read | `Write) as dir)) when has_waiters t fd dir ->
    (* Don't overtake operations already waiting in this direction. *)
    park t fd dir job io
  | _ ->
    let n = perform io in
    (match blocked io n with
    | Some (fd, dir, io) -> park t fd dir job io
    | None -> complete t job (Res.of_syscall n))

let remove_parked q job =
  for _ = 1 to Queue.length q do
    let p = Queue.take q in
    if p.job != job then Queue.push p q
  done

let unpark t job fd dir =
  Option.iter
    (fun w ->
       remove_parked (queue_of w dir) job;
       rearm t fd w)
    (Hashtbl.find_opt t.parked fd)

let cancel_job t job target =
  let cancelled () =
    complete t target (Error ecanceled);
    complete t job (Ok 0)
  in
  match target.state with
  | Parked (fd, dir) ->
    unpark t target fd dir;
    cancelled ()
  | Sleeping e ->
    Timer_heap.remove t.timers e;
    cancelled ()
  | Completed | Collected -> complete t job (Error Unix.ENOENT)
  | Queued ->
    (* [target] was queued before [job], so [submit] has already attempted
       it. *)
    assert false

(* Cancel what is parked on [fd] and drop its poller registration before closing
   it. Otherwise the registration, which may outlive this descriptor if it was
   duplicated, could report events for a reused descriptor number. It is deleted
   even when nothing is parked, since registrations outlive [parked] entries. *)
let close_fd t fd =
  Option.iter
    (fun w -> fail_all t fd w ecanceled)
    (Hashtbl.find_opt t.parked fd);
  (try Poller.delete t.poller fd with Unix.Unix_error _ -> ());
  Fs.close fd

let attempt t job =
  match job.op with
  | Io io -> attempt_io t job io
  | Timeout { ns; absolute } ->
    let deadline = if absolute then ns else Int64.add (now ()) ns in
    job.state <- Sleeping (Timer_heap.add t.timers deadline job)
  | Cancel target -> cancel_job t job target
  | Close fd -> complete t job (Res.of_syscall (close_fd t fd))

let fire_timers t =
  if Timer_heap.length t.timers > 0
  then begin
    let now = now () in
    let rec loop () =
      match Timer_heap.pop_expired t.timers now with
      | None -> ()
      | Some job ->
        complete t job (Error etime);
        loop ()
    in
    loop ()
  end

(* Retry the head of [q] until one would block again. *)
let rec retry t q =
  match Queue.peek_opt q with
  | None -> ()
  | Some p ->
    let n = perform p.io in
    if n <> -Io.eagain
    then begin
      ignore (Queue.take q : _ parked);
      complete t p.job (Res.of_syscall n);
      retry t q
    end

(* Recheck every job in [q], keeping those that would still block in order. *)
let retry_all t q =
  for _ = 1 to Queue.length q do
    let p = Queue.take q in
    let n = perform p.io in
    if n = -Io.eagain
    then Queue.push p q
    else complete t p.job (Res.of_syscall n)
  done

let on_ready t fd flags =
  match Hashtbl.find_opt t.parked fd with
  | None -> ()
  | Some w ->
    w.armed <- Poller.Flags.empty;
    let open Poller.Flags in
    (* On error or hang-up, retrying reports the error or end of file. *)
    let failed = mem pollerr flags || mem pollhup flags in
    (* Pollers first, so they observe the readiness before readers or writers
       consume it. *)
    retry_all t w.pollers;
    if failed || mem pollin flags then retry t w.readers;
    if failed || mem pollout flags then retry t w.writers;
    rearm t fd w

(* Wait up to [timeout_ms] for readiness and retry what became ready. Returns
   [true] if {!wakeup} was called. *)
let poll t ~timeout_ms =
  let n = Poller.wait t.poller t.events ~timeout_ms in
  let woken = ref false in
  for i = 0 to n - 1 do
    let fd = Poller.Events.fd t.events i in
    if fd = Waker.fd t.wakeup
    then begin
      ignore (Waker.drain t.wakeup : bool);
      woken := true
    end
    else on_ready t fd (Poller.Events.flags t.events i)
  done;
  !woken

let submit t =
  check t;
  let n = Queue.length t.sq in
  for _ = 1 to n do
    attempt t (Queue.take t.sq)
  done;
  n

(* Both backends take their timeout as a C int; longer waits are split up by the
   [wait] loop. *)
let max_timeout_ms = 1_000_000_000

let ms_until deadline =
  let ns = Int64.sub deadline (now ()) in
  if ns <= 0L
  then 0
  else
    Int64.to_int
      (Int64.min
         (Int64.div (Int64.add ns 999_999L) 1_000_000L)
         (Int64.of_int max_timeout_ms))

(* How long to block: until [deadline] or the earliest timer, if any. *)
let poll_timeout_ms t deadline =
  match deadline, Timer_heap.min_deadline t.timers with
  | None, None -> -1
  | Some d, None | None, Some d -> ms_until d
  | Some a, Some b -> ms_until (Int64.min a b)

let expired = function None -> false | Some d -> now () >= d

type 'a completion_option =
  | None
  | Some of
      { result : Res.t
      ; data : 'a
      }

let take_completion t : _ completion_option =
  match Queue.take_opt t.cq with
  | Option.None -> None
  | Option.Some (job, result) ->
    job.state <- Collected;
    t.in_flight <- t.in_flight - 1;
    Some { result; data = job.data }

let wait ?timeout t : _ completion_option =
  ignore (submit t : int);
  let deadline =
    Option.map (fun s -> Int64.add (now ()) (Int64.of_float (s *. 1e9))) timeout
  in
  let rec loop () =
    fire_timers t;
    if not (Queue.is_empty t.cq)
    then take_completion t
    else begin
      let woken = poll t ~timeout_ms:(poll_timeout_ms t deadline) in
      fire_timers t;
      if not (Queue.is_empty t.cq)
      then take_completion t
      else if woken || expired deadline
      then None
      else loop ()
    end
  in
  loop ()

let get_cqe_nonblocking t =
  ignore (submit t : int);
  fire_timers t;
  if Queue.is_empty t.cq
  then begin
    ignore (poll t ~timeout_ms:0 : bool);
    fire_timers t
  end;
  take_completion t

let wakeup t = Waker.signal t.wakeup
let active_ops t = t.in_flight
let sqe_ready t = Queue.length t.sq

module Private = struct
  module Poller = Poller
  module Waker = Waker
  module Timer_heap = Timer_heap
end
