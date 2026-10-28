let todo name = failwith ("Uringan." ^ name ^ ": not implemented")

type op =
  | Noop
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

type 'a job =
  { op : op
  ; data : 'a
  }

(* Operations parked on one descriptor, in submission order. Only the head of
   [readers] and [writers] is retried, so a stream is read or written in order.
   [pollers] consume nothing, so all of them are rechecked on every event. *)
type 'a waiters =
  { readers : 'a job Queue.t
  ; writers : 'a job Queue.t
  ; pollers : 'a job Queue.t
  ; mutable armed : Epoll.Flags.t
    (* The one-shot interest registered with epoll that has not fired yet. *)
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
  { epoll : Epoll.t
  ; events : Epoll.Events.t
  ; wakeup : Eventfd.t
  ; queue_depth : int
  ; sq : 'a job Queue.t  (** Queued, not yet attempted. *)
  ; cq : (Res.t * 'a) Queue.t  (** Completed, not yet collected. *)
  ; parked : (Unix.file_descr, 'a waiters) Hashtbl.t
  ; mutable in_flight : int
  ; mutable closed : bool
  }

let create ~queue_depth () =
  if queue_depth <= 0 then invalid_arg "Uringan.create: queue_depth <= 0";
  let epoll = Epoll.create () in
  match Eventfd.create () with
  | exception e ->
    Epoll.close epoll;
    raise e
  | wakeup ->
    (try Epoll.add epoll (wakeup :> Unix.file_descr) Epoll.Flags.pollin with
    | e ->
      Eventfd.close wakeup;
      Epoll.close epoll;
      raise e);
    { epoll
    ; (* At most one event per parked descriptor, plus the eventfd. *)
      events = Epoll.Events.create (queue_depth + 1)
    ; wakeup
    ; queue_depth
    ; sq = Queue.create ()
    ; cq = Queue.create ()
    ; parked = Hashtbl.create 16
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
    Eventfd.close t.wakeup;
    Epoll.close t.epoll
  end

let backend _ = `Epoll

let enqueue t op data =
  check t;
  if t.in_flight >= t.queue_depth
  then None
  else begin
    let job = { op; data } in
    Queue.push job t.sq;
    t.in_flight <- t.in_flight + 1;
    Some job
  end

let noop t data = enqueue t Noop data

external now :
   unit
  -> (int64[@unboxed])
  = "uringan_clock_now" "uringan_clock_now_unboxed"
[@@noalloc]

let timeout ?absolute:_ _ _ _ = todo "timeout"

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

let poll_add t fd mask data = enqueue t (Poll { fd; mask }) data

let read t ~file_offset fd buf data =
  enqueue t (Read { fd; file_offset; buf }) data

let write t ~file_offset fd buf data =
  enqueue t (Write { fd; file_offset; buf }) data

let iov_max = Io.iov_max

let check_iov name bufs =
  if List.compare_length_with bufs iov_max > 0
  then invalid_arg (Printf.sprintf "Uringan.%s: more than iov_max buffers" name)

let readv t ~file_offset fd bufs data =
  check_iov "readv" bufs;
  enqueue t (Readv { fd; file_offset; bufs }) data

let writev t ~file_offset fd bufs data =
  check_iov "writev" bufs;
  enqueue t (Writev { fd; file_offset; bufs }) data

let openat _ ?dir_fd:_ _ _ _ _ = todo "openat"
let close _ _ _ = todo "close"
let fsync _ _ _ = todo "fsync"
let fdatasync _ _ _ = todo "fdatasync"
let ftruncate _ _ ~len:_ _ = todo "ftruncate"
let unlink _ ~dir:_ ?fd:_ _ _ = todo "unlink"
let mkdirat _ ~mode:_ ?fd:_ _ _ = todo "mkdirat"
let renameat _ ?old_dir_fd:_ _ ?new_dir_fd:_ _ _ = todo "renameat"

let linkat _ ~follow:_ ?old_dir_fd:_ ~old_path:_ ?new_dir_fd:_ ~new_path:_ _ =
  todo "linkat"

let symlinkat _ ~target:_ ?dir_fd:_ ~link_path:_ _ = todo "symlinkat"

module Stat = struct
  type t = unit

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

  let create () = todo "Stat.create"
  let kind _ = todo "Stat.kind"
  let perm _ = todo "Stat.perm"
  let size _ = todo "Stat.size"
  let ino _ = todo "Stat.ino"
  let dev _ = todo "Stat.dev"
  let rdev _ = todo "Stat.rdev"
  let nlink _ = todo "Stat.nlink"
  let uid _ = todo "Stat.uid"
  let gid _ = todo "Stat.gid"
  let blksize _ = todo "Stat.blksize"
  let blocks _ = todo "Stat.blocks"
  let atime_sec _ = todo "Stat.atime_sec"
  let atime_nsec _ = todo "Stat.atime_nsec"
  let mtime_sec _ = todo "Stat.mtime_sec"
  let mtime_nsec _ = todo "Stat.mtime_nsec"
  let ctime_sec _ = todo "Stat.ctime_sec"
  let ctime_nsec _ = todo "Stat.ctime_nsec"
end

let fstatat _ ?fd:_ ~follow:_ _ _ _ = todo "fstatat"
let socket ?cloexec:_ _ _ _ _ _ = todo "socket"
let bind _ _ _ _ = todo "bind"
let listen _ _ _ _ = todo "listen"
let connect _ _ _ _ = todo "connect"

module Sockaddr = struct
  type t = unit

  let create () = todo "Sockaddr.create"
  let get _ = todo "Sockaddr.get"
end

let accept _ _ _ _ = todo "accept"
let shutdown _ _ _ _ = todo "shutdown"

module Msghdr = struct
  type t = unit

  let create ?n_fds:_ ?addr:_ _ = todo "Msghdr.create"
  let get_fds _ = todo "Msghdr.get_fds"
end

let send_msg ?fds:_ ?dst:_ _ _ _ _ = todo "send_msg"
let recv_msg _ _ _ _ = todo "recv_msg"
let cancel _ _ _ = todo "cancel"

(* [perform op] runs the syscall for [op]: a non-negative result or a negative
   errno. *)
let perform = function
  | Noop -> 0
  | Read { fd; file_offset; buf } -> Io.read fd ~file_offset buf
  | Write { fd; file_offset; buf } -> Io.write fd ~file_offset buf
  | Readv { fd; file_offset; bufs } -> Io.readv fd ~file_offset bufs
  | Writev { fd; file_offset; bufs } -> Io.writev fd ~file_offset bufs
  | Poll { fd; mask } -> Io.poll fd mask

(* The descriptor an operation blocks on, and which queue it waits in. *)
let wait_target = function
  | Noop -> None
  | Read { fd; _ } | Readv { fd; _ } -> Some (fd, `Read)
  | Write { fd; _ } | Writev { fd; _ } -> Some (fd, `Write)
  | Poll { fd; _ } -> Some (fd, `Poll)

let complete t job res = Queue.push (res, job.data) t.cq

let queue_of w = function
  | `Read -> w.readers
  | `Write -> w.writers
  | `Poll -> w.pollers

let is_idle w =
  Queue.is_empty w.readers
  && Queue.is_empty w.writers
  && Queue.is_empty w.pollers

(* epoll always reports errors and hang-ups; [pollerr] is included only so that
   an [interest] is empty exactly when [w] is idle. *)
let interest w =
  let open Epoll.Flags in
  let poller job acc =
    match job.op with
    | Poll { mask; _ } ->
      acc
      + (if Poll_mask.mem Poll_mask.pollin mask then pollin else empty)
      + if Poll_mask.mem Poll_mask.pollout mask then pollout else empty
    | Noop | Read _ | Write _ | Readv _ | Writev _ -> acc
  in
  if is_idle w
  then empty
  else
    Queue.fold (Fun.flip poller) pollerr w.pollers
    + (if Queue.is_empty w.readers then empty else pollin)
    + if Queue.is_empty w.writers then empty else pollout

(* Re-arm epoll for whatever [w] is still waiting for. The registration outlives
   empty [waiters], so try [modify] before [add]. *)
let arm t fd w =
  let flags = interest w in
  if flags <> w.armed
  then begin
    let flags' = Epoll.Flags.(flags + oneshot) in
    (try Epoll.modify t.epoll fd flags' with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Epoll.add t.epoll fd flags');
    w.armed <- flags
  end

let fail_all t fd w err =
  let fail job = complete t job (Error err) in
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

let park t fd dir job =
  let w =
    match Hashtbl.find_opt t.parked fd with
    | Some w -> w
    | None ->
      let w =
        { readers = Queue.create ()
        ; writers = Queue.create ()
        ; pollers = Queue.create ()
        ; armed = Epoll.Flags.empty
        }
      in
      Hashtbl.replace t.parked fd w;
      w
  in
  Queue.push job (queue_of w dir);
  rearm t fd w

let has_waiters t fd dir =
  match Hashtbl.find_opt t.parked fd with
  | None -> false
  | Some w -> not (Queue.is_empty (queue_of w dir))

let attempt t job =
  match wait_target job.op with
  | Some (fd, ((`Read | `Write) as dir)) when has_waiters t fd dir ->
    (* Don't overtake operations already waiting in this direction. *)
    park t fd dir job
  | target ->
    let n = perform job.op in
    (match target with
    | Some (fd, dir) when n = -Io.eagain -> park t fd dir job
    | _ -> complete t job (Res.of_syscall n))

(* Retry the head of [q] until one would block again. *)
let rec retry t q =
  match Queue.peek_opt q with
  | None -> ()
  | Some job ->
    let n = perform job.op in
    if n <> -Io.eagain
    then begin
      ignore (Queue.take q : _ job);
      complete t job (Res.of_syscall n);
      retry t q
    end

(* Recheck every job in [q], keeping those that would still block in order. *)
let retry_all t q =
  for _ = 1 to Queue.length q do
    let job = Queue.take q in
    let n = perform job.op in
    if n = -Io.eagain
    then Queue.push job q
    else complete t job (Res.of_syscall n)
  done

let on_ready t fd flags =
  match Hashtbl.find_opt t.parked fd with
  | None -> ()
  | Some w ->
    w.armed <- Epoll.Flags.empty;
    let open Epoll.Flags in
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
  let n = Epoll.wait t.epoll t.events ~timeout_ms in
  let woken = ref false in
  for i = 0 to n - 1 do
    let fd = Epoll.Events.fd t.events i in
    if fd = (t.wakeup :> Unix.file_descr)
    then begin
      ignore (Eventfd.drain t.wakeup : bool);
      woken := true
    end
    else on_ready t fd (Epoll.Events.flags t.events i)
  done;
  !woken

let submit t =
  check t;
  let n = Queue.length t.sq in
  for _ = 1 to n do
    attempt t (Queue.take t.sq)
  done;
  n

type 'a completion_option =
  | None
  | Some of
      { result : Res.t
      ; data : 'a
      }

let take_completion t : _ completion_option =
  match Queue.take_opt t.cq with
  | Option.None -> None
  | Option.Some (result, data) ->
    t.in_flight <- t.in_flight - 1;
    Some { result; data }

let ms_until deadline =
  let ns = Int64.sub deadline (now ()) in
  if ns <= 0L
  then 0
  else Int64.to_int (Int64.div (Int64.add ns 999_999L) 1_000_000L)

let wait ?timeout t : _ completion_option =
  ignore (submit t : int);
  let deadline =
    Option.map (fun s -> Int64.add (now ()) (Int64.of_float (s *. 1e9))) timeout
  in
  let rec loop () =
    if not (Queue.is_empty t.cq)
    then take_completion t
    else begin
      let timeout_ms =
        match deadline with Option.None -> -1 | Option.Some d -> ms_until d
      in
      let woken = poll t ~timeout_ms in
      if not (Queue.is_empty t.cq)
      then take_completion t
      else if woken || timeout_ms = 0
      then None
      else loop ()
    end
  in
  loop ()

let get_cqe_nonblocking t =
  ignore (submit t : int);
  if Queue.is_empty t.cq then ignore (poll t ~timeout_ms:0 : bool);
  take_completion t

let wakeup t = Eventfd.signal t.wakeup
let active_ops t = t.in_flight
let sqe_ready t = Queue.length t.sq

module Private = struct
  module Epoll = Epoll
  module Eventfd = Eventfd
end
