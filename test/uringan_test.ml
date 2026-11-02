open Alcotest
module Poller = Uringan.Private.Poller
module Waker = Uringan.Private.Waker
module Timer_heap = Uringan.Private.Timer_heap

(* The handful of places where the two backends differ only by name. *)
[%%import "config.h"]
[%%ifdef USE_EPOLL]

let backend : [ `Epoll | `Kqueue ] = `Epoll
let poller_name = "Epoll"
let ctl_name = "epoll_ctl"

[%%else]

let backend : [ `Epoll | `Kqueue ] = `Kqueue
let poller_name = "Kqueue"
let ctl_name = "kevent"

[%%endif]

let test_poll_mask () =
  let open Uringan.Poll_mask in
  let m = pollin + pollout in
  check bool "pollin in mask" true (mem pollin m);
  check bool "pollerr not in mask" false (mem pollerr m);
  check bool "empty in any mask" true (mem empty m)

let test_now_monotonic () =
  let a = Uringan.now () in
  Unix.sleepf 0.01;
  let b = Uringan.now () in
  check bool "advances by at least 10ms" true (Int64.sub b a >= 10_000_000L)

let with_pipe f =
  let r, w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock r;
  Unix.set_nonblock w;
  let ep = Poller.create () in
  Fun.protect
    ~finally:(fun () -> List.iter Unix.close [ r; w; (ep :> Unix.file_descr) ])
    (fun () -> f ep r w)

let test_poller_readable () =
  with_pipe @@ fun ep r w ->
  let events = Poller.Events.create 8 in
  Poller.add ep r Poller.Flags.pollin;
  check int "nothing ready" 0 (Poller.wait ep events ~timeout_ms:0);
  ignore (Unix.write_substring w "x" 0 1);
  check int "one ready" 1 (Poller.wait ep events ~timeout_ms:1000);
  check bool "ready fd is read end" true (Poller.Events.fd events 0 = r);
  check
    bool
    "pollin set"
    true
    (Poller.Flags.mem Poller.Flags.pollin (Poller.Events.flags events 0))

let test_poller_oneshot () =
  with_pipe @@ fun ep r w ->
  let events = Poller.Events.create 8 in
  let flags = Poller.Flags.(pollin + oneshot) in
  Poller.add ep r flags;
  ignore (Unix.write_substring w "x" 0 1);
  check int "fires once" 1 (Poller.wait ep events ~timeout_ms:1000);
  check int "disarmed" 0 (Poller.wait ep events ~timeout_ms:0);
  Poller.modify ep r flags;
  check int "re-armed" 1 (Poller.wait ep events ~timeout_ms:0)

let test_poller_delete () =
  with_pipe @@ fun ep r w ->
  let events = Poller.Events.create 8 in
  Poller.add ep r Poller.Flags.pollin;
  Poller.delete ep r;
  ignore (Unix.write_substring w "x" 0 1);
  check int "not watched" 0 (Poller.wait ep events ~timeout_ms:0);
  check_raises
    "delete again"
    (Unix.Unix_error (Unix.ENOENT, ctl_name, ""))
    (fun () -> Poller.delete ep r)

let test_poller_hup () =
  let r, w = Unix.pipe ~cloexec:true () in
  let ep = Poller.create () in
  let events = Poller.Events.create 8 in
  Poller.add ep r Poller.Flags.pollin;
  Unix.close w;
  check int "one ready" 1 (Poller.wait ep events ~timeout_ms:1000);
  let flags = Poller.Events.flags events 0 in
  check
    bool
    "hang-up reported"
    true
    (Poller.Flags.mem Poller.Flags.pollhup flags
    || Poller.Flags.mem Poller.Flags.pollrdhup flags);
  check int "read reports eof" 0 (Unix.read r (Bytes.create 1) 0 1);
  Unix.close r;
  Poller.close ep

let test_poller_timeout () =
  let ep = Poller.create () in
  let events = Poller.Events.create 1 in
  let start = Uringan.now () in
  check int "times out" 0 (Poller.wait ep events ~timeout_ms:20);
  Poller.close ep;
  check
    bool
    "waited ~20ms"
    true
    (Int64.sub (Uringan.now ()) start >= 19_000_000L)

let test_events_bounds () =
  let events = Poller.Events.create 2 in
  check int "length" 2 (Poller.Events.length events);
  check_raises
    "out of bounds"
    (Invalid_argument (poller_name ^ ".Events.fd"))
    (fun () -> ignore (Poller.Events.fd events 2));
  check_raises
    "non-positive size"
    (Invalid_argument (poller_name ^ ".Events.create"))
    (fun () -> ignore (Poller.Events.create 0))

let test_ring_lifecycle () =
  let t = Uringan.create ~queue_depth:16 () in
  check int "queue_depth" 16 (Uringan.queue_depth t);
  check bool "backend" true (Uringan.backend t = backend);
  Uringan.exit t;
  Uringan.exit t;
  check_raises
    "non-positive queue_depth"
    (Invalid_argument "Uringan.create: queue_depth <= 0")
    (fun () -> ignore (Uringan.create ~queue_depth:0 ()))

let with_waker f =
  let w = Waker.create () in
  Fun.protect ~finally:(fun () -> Waker.close w) (fun () -> f w)

let test_waker_drain () =
  with_waker @@ fun efd ->
  check bool "not signalled" false (Waker.drain efd);
  Waker.signal efd;
  Waker.signal efd;
  check bool "signalled" true (Waker.drain efd);
  check bool "signals collapsed" false (Waker.drain efd)

let test_waker_wakes_poller () =
  with_waker @@ fun efd ->
  let ep = Poller.create () in
  let events = Poller.Events.create 1 in
  Poller.add ep (Waker.fd efd) Poller.Flags.pollin;
  check int "idle" 0 (Poller.wait ep events ~timeout_ms:0);
  Waker.signal efd;
  check int "woken" 1 (Poller.wait ep events ~timeout_ms:0);
  check int "stays readable" 1 (Poller.wait ep events ~timeout_ms:0);
  ignore (Waker.drain efd);
  check int "idle after drain" 0 (Poller.wait ep events ~timeout_ms:0);
  Poller.close ep

let test_waker_cross_domain () =
  with_waker @@ fun efd ->
  let ep = Poller.create () in
  Poller.add ep (Waker.fd efd) Poller.Flags.pollin;
  let waiter =
    Domain.spawn (fun () ->
      Poller.wait ep (Poller.Events.create 1) ~timeout_ms:5000)
  in
  Unix.sleepf 0.02;
  let start = Uringan.now () in
  Waker.signal efd;
  check int "woken from other domain" 1 (Domain.join waiter);
  check
    bool
    "woke promptly"
    true
    (Int64.sub (Uringan.now ()) start < 1_000_000_000L);
  Poller.close ep

let unix_error = testable (Fmt.of_to_string Unix.error_message) ( = )

let with_ring ?(queue_depth = 16) f =
  let t = Uringan.create ~queue_depth () in
  Fun.protect ~finally:(fun () -> Uringan.exit t) (fun () -> f t)

let queue = function
  | Option.Some (_ : _ Uringan.job) -> ()
  | Option.None -> fail "ring full"

(* Wait for one completion, failing the test after [timeout] seconds. *)
let next ?(timeout = 1.0) t =
  match Uringan.wait ~timeout t with
  | Uringan.None -> fail "no completion"
  | Uringan.Some { result; data } -> data, Uringan.Res.int_result result

let expect_none ?(timeout = 0.05) t =
  match Uringan.wait ~timeout t with
  | Uringan.None -> ()
  | Uringan.Some _ -> fail "unexpected completion"

let pipe () =
  let r, w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock r;
  Unix.set_nonblock w;
  r, w

let with_pipe' f =
  let r, w = pipe () in
  Fun.protect
    ~finally:(fun () -> List.iter Unix.close [ r; w ])
    (fun () -> f r w)

let check_result msg data expected (data', res) =
  check int (msg ^ ": data") data data';
  check (result int unix_error) (msg ^ ": result") expected res

let current = Optint.Int63.minus_one
let at n = Optint.Int63.of_int n

let test_noop () =
  with_ring @@ fun t ->
  queue (Uringan.noop t 1);
  check int "queued" 1 (Uringan.sqe_ready t);
  check int "active" 1 (Uringan.active_ops t);
  check_result "noop" 1 (Ok 0) (next t);
  check int "sq empty" 0 (Uringan.sqe_ready t);
  check int "idle" 0 (Uringan.active_ops t)

let test_file_rw () =
  with_ring @@ fun t ->
  let path = Filename.temp_file "uringan" ".txt" in
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () ->
    Unix.close fd;
    Sys.remove path)
  @@ fun () ->
  queue (Uringan.write t ~file_offset:(at 0) fd (Cstruct.of_string "hello") 1);
  check_result "pwrite" 1 (Ok 5) (next t);
  let buf = Cstruct.create 3 in
  queue (Uringan.read t ~file_offset:(at 2) fd buf 2);
  check_result "pread" 2 (Ok 3) (next t);
  check string "pread data" "llo" (Cstruct.to_string buf);
  (* pwrite/pread leave the position at 0. *)
  queue (Uringan.read t ~file_offset:current fd buf 3);
  check_result "read" 3 (Ok 3) (next t);
  check string "read data" "hel" (Cstruct.to_string buf);
  queue (Uringan.read t ~file_offset:current fd buf 4);
  check_result "read advances" 4 (Ok 2) (next t);
  check string "read data" "lo" (Cstruct.to_string (Cstruct.sub buf 0 2))

let test_pipe_read_parks () =
  with_ring @@ fun t ->
  with_pipe' @@ fun r w ->
  let buf = Cstruct.create 8 in
  queue (Uringan.read t ~file_offset:current r buf 1);
  expect_none t;
  check int "still active" 1 (Uringan.active_ops t);
  ignore (Unix.write_substring w "hi" 0 2);
  check_result "read" 1 (Ok 2) (next t);
  check string "data" "hi" (Cstruct.to_string (Cstruct.sub buf 0 2))

let test_parked_reads_in_order () =
  with_ring @@ fun t ->
  with_pipe' @@ fun r w ->
  let a = Cstruct.create 1
  and b = Cstruct.create 1 in
  queue (Uringan.read t ~file_offset:current r a 1);
  queue (Uringan.read t ~file_offset:current r b 2);
  expect_none t;
  ignore (Unix.write_substring w "ab" 0 2);
  check_result "first" 1 (Ok 1) (next t);
  check_result "second" 2 (Ok 1) (next t);
  check string "first byte" "a" (Cstruct.to_string a);
  check string "second byte" "b" (Cstruct.to_string b)

let rec fill fd buf =
  match Unix.write fd buf 0 (Bytes.length buf) with
  | _ -> fill fd buf
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()

let test_pipe_write_parks () =
  with_ring @@ fun t ->
  with_pipe' @@ fun r w ->
  let chunk = Bytes.create 4096 in
  fill w chunk;
  queue (Uringan.write t ~file_offset:current w (Cstruct.of_string "x") 1);
  expect_none t;
  ignore (Unix.read r chunk 0 (Bytes.length chunk));
  check_result "write" 1 (Ok 1) (next t)

let test_read_and_write_same_fd () =
  with_ring @@ fun t ->
  let a, b = Unix.socketpair ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.set_nonblock a;
  Unix.set_nonblock b;
  Fun.protect ~finally:(fun () -> List.iter Unix.close [ a; b ]) @@ fun () ->
  let buf = Cstruct.create 4 in
  queue (Uringan.read t ~file_offset:current a buf 1);
  expect_none t;
  queue (Uringan.write t ~file_offset:current a (Cstruct.of_string "out") 2);
  check_result "write while read parked" 2 (Ok 3) (next t);
  ignore (Unix.write_substring b "in" 0 2);
  check_result "parked read" 1 (Ok 2) (next t)

let test_eof () =
  with_ring @@ fun t ->
  let r, w = pipe () in
  Fun.protect ~finally:(fun () -> Unix.close r) @@ fun () ->
  let buf = Cstruct.create 8 in
  queue (Uringan.read t ~file_offset:current r buf 1);
  expect_none t;
  Unix.close w;
  check_result "parked read sees eof" 1 (Ok 0) (next t);
  queue (Uringan.read t ~file_offset:current r buf 2);
  check_result "read after eof" 2 (Ok 0) (next t)

let test_error_result () =
  with_ring @@ fun t ->
  with_pipe' @@ fun _r w ->
  queue (Uringan.read t ~file_offset:current w (Cstruct.create 1) 1);
  check_result "read from write end" 1 (Error Unix.EBADF) (next t);
  check_raises
    "int_exn"
    (Unix.Unix_error (Unix.EBADF, "read", ""))
    (fun () ->
       queue (Uringan.read t ~file_offset:current w (Cstruct.create 1) 2);
       match Uringan.wait t with
       | Uringan.None -> fail "no completion"
       | Uringan.Some { result; _ } ->
         ignore (Uringan.Res.int_exn result "read" ""))

let test_queue_full () =
  with_ring ~queue_depth:2 @@ fun t ->
  queue (Uringan.noop t 1);
  queue (Uringan.noop t 2);
  check bool "full" true (Option.is_none (Uringan.noop t 3));
  ignore (next t);
  queue (Uringan.noop t 3);
  ignore (next t);
  ignore (next t)

let test_exit_in_flight () =
  let t = Uringan.create ~queue_depth:4 () in
  queue (Uringan.noop t 1);
  check_raises
    "in flight"
    (Invalid_argument "Uringan.exit: 1 operation(s) in flight")
    (fun () -> Uringan.exit t);
  ignore (next t);
  Uringan.exit t;
  check_raises
    "used after exit"
    (Invalid_argument "Uringan: ring used after exit")
    (fun () -> ignore (Uringan.noop t 2))

let test_wakeup () =
  with_ring @@ fun t ->
  let waker =
    Domain.spawn (fun () ->
      Unix.sleepf 0.02;
      Uringan.wakeup t)
  in
  (match Uringan.wait t with
  | Uringan.None -> ()
  | Uringan.Some _ -> fail "unexpected completion");
  Domain.join waker

let test_wait_timeout () =
  with_ring @@ fun t ->
  let start = Uringan.now () in
  expect_none ~timeout:0.03 t;
  check
    bool
    "waited ~30ms"
    true
    (Int64.sub (Uringan.now ()) start >= 29_000_000L);
  check bool "nonblocking" true (Uringan.get_cqe_nonblocking t = Uringan.None)

let with_temp_file f =
  let path = Filename.temp_file "uringan" ".txt" in
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close fd;
      Sys.remove path)
    (fun () -> f fd)

let test_file_rwv () =
  with_ring @@ fun t ->
  with_temp_file @@ fun fd ->
  let bufs = List.map Cstruct.of_string [ "hel"; "lo"; " world" ] in
  queue (Uringan.writev t ~file_offset:(at 0) fd bufs 1);
  check_result "pwritev" 1 (Ok 11) (next t);
  let a = Cstruct.create 2
  and b = Cstruct.create 4 in
  queue (Uringan.readv t ~file_offset:(at 3) fd [ a; b ] 2);
  check_result "preadv" 2 (Ok 6) (next t);
  check string "first buffer" "lo" (Cstruct.to_string a);
  check string "second buffer" " wor" (Cstruct.to_string b);
  queue (Uringan.readv t ~file_offset:current fd [ a; b ] 3);
  check_result "readv from position" 3 (Ok 6) (next t);
  check string "first buffer" "he" (Cstruct.to_string a);
  check string "second buffer" "llo " (Cstruct.to_string b);
  queue (Uringan.readv t ~file_offset:current fd [] 4);
  check_result "no buffers" 4 (Ok 0) (next t)

let test_pipe_rwv_parks () =
  with_ring @@ fun t ->
  with_pipe' @@ fun r w ->
  let a = Cstruct.create 1
  and b = Cstruct.create 2 in
  queue (Uringan.readv t ~file_offset:current r [ a; b ] 1);
  expect_none t;
  queue
    (Uringan.writev
       t
       ~file_offset:current
       w
       [ Cstruct.of_string "x"; Cstruct.of_string "yz" ]
       2);
  let completions = List.sort compare [ next t; next t ] in
  check_result "readv" 1 (Ok 3) (List.nth completions 0);
  check_result "writev" 2 (Ok 3) (List.nth completions 1);
  check string "scattered" "xyz" (Cstruct.to_string (Cstruct.append a b));
  fill w (Bytes.create 4096);
  queue (Uringan.writev t ~file_offset:current w [ Cstruct.of_string "!" ] 3);
  expect_none t;
  ignore (Unix.read r (Bytes.create 4096) 0 4096);
  check_result "parked writev" 3 (Ok 1) (next t)

let test_iov_max () =
  with_ring @@ fun t ->
  check bool "iov_max >= POSIX minimum" true (Uringan.iov_max >= 16);
  let bufs = List.init (Uringan.iov_max + 1) (fun _ -> Cstruct.create 1) in
  check_raises
    "too many buffers"
    (Invalid_argument "Uringan.readv: more than iov_max buffers")
    (fun () -> ignore (Uringan.readv t ~file_offset:current Unix.stdin bufs 1));
  check int "nothing queued" 0 (Uringan.active_ops t)

let poll_result (data, res) = data, Result.map Uringan.Poll_mask.of_int res

let check_events msg data expected completion =
  let data', res = poll_result completion in
  check int (msg ^ ": data") data data';
  match res with
  | Error e -> failf "%s: %s" msg (Unix.error_message e)
  | Ok mask ->
    check bool (msg ^ ": events") true (Uringan.Poll_mask.mem expected mask)

let test_poll_readable () =
  with_ring @@ fun t ->
  with_pipe' @@ fun r w ->
  queue (Uringan.poll_add t r Uringan.Poll_mask.pollin 1);
  expect_none t;
  ignore (Unix.write_substring w "x" 0 1);
  check_events "readable" 1 Uringan.Poll_mask.pollin (next t);
  (* Polling consumes nothing. *)
  queue (Uringan.poll_add t r Uringan.Poll_mask.pollin 2);
  check_events "still readable" 2 Uringan.Poll_mask.pollin (next t)

let test_poll_immediate () =
  with_ring @@ fun t ->
  with_pipe' @@ fun _r w ->
  queue (Uringan.poll_add t w Uringan.Poll_mask.pollout 1);
  check_events "pipe writable" 1 Uringan.Poll_mask.pollout (next t);
  with_temp_file @@ fun fd ->
  (* epoll refuses regular files; poll(2) reports them always ready. *)
  queue (Uringan.poll_add t fd Uringan.Poll_mask.(pollin + pollout) 2);
  check_events "regular file" 2 Uringan.Poll_mask.(pollin + pollout) (next t)

let test_poll_hup () =
  with_ring @@ fun t ->
  let r, w = pipe () in
  Fun.protect ~finally:(fun () -> Unix.close r) @@ fun () ->
  queue (Uringan.poll_add t r Uringan.Poll_mask.pollin 1);
  expect_none t;
  Unix.close w;
  check_events "hang-up" 1 Uringan.Poll_mask.pollhup (next t)

let test_poll_bad_fd () =
  with_ring @@ fun t ->
  let r, w = pipe () in
  Unix.close r;
  Unix.close w;
  queue (Uringan.poll_add t r Uringan.Poll_mask.pollin 1);
  check_result "closed fd" 1 (Error Unix.EBADF) (next t)

let test_poll_with_reader () =
  with_ring @@ fun t ->
  let a, b = Unix.socketpair ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.set_nonblock a;
  Unix.set_nonblock b;
  Fun.protect ~finally:(fun () -> List.iter Unix.close [ a; b ]) @@ fun () ->
  let buf = Cstruct.create 1 in
  queue (Uringan.read t ~file_offset:current a buf 1);
  queue (Uringan.poll_add t a Uringan.Poll_mask.pollin 2);
  expect_none t;
  queue (Uringan.poll_add t a Uringan.Poll_mask.pollout 3);
  check_events "writable while read parked" 3 Uringan.Poll_mask.pollout (next t);
  ignore (Unix.write_substring b "x" 0 1);
  check_events "poller sees data first" 2 Uringan.Poll_mask.pollin (next t);
  check_result "then reader consumes it" 1 (Ok 1) (next t)

let drain_heap h =
  let rec loop acc =
    match Timer_heap.pop_expired h Int64.max_int with
    | Option.None -> List.rev acc
    | Option.Some v -> loop (v :: acc)
  in
  loop []

let test_heap_order () =
  let h = Timer_heap.create () in
  let deadlines = List.init 200 (fun i -> i * 7919 mod 211) in
  List.iter (fun d -> ignore (Timer_heap.add h (Int64.of_int d) d)) deadlines;
  check int "length" 200 (Timer_heap.length h);
  check (option int64) "min" (Option.Some 0L) (Timer_heap.min_deadline h);
  check (list int) "sorted" (List.sort compare deadlines) (drain_heap h);
  check (option int64) "empty" Option.None (Timer_heap.min_deadline h)

let test_heap_expiry () =
  let h = Timer_heap.create () in
  ignore (Timer_heap.add h 10L "a");
  ignore (Timer_heap.add h 20L "b");
  check (option string) "not yet" Option.None (Timer_heap.pop_expired h 9L);
  check
    (option string)
    "at deadline"
    (Option.Some "a")
    (Timer_heap.pop_expired h 10L);
  check
    (option string)
    "next not yet"
    Option.None
    (Timer_heap.pop_expired h 19L)

let test_heap_remove () =
  let h = Timer_heap.create () in
  let entries =
    List.init 50 (fun i -> i, Timer_heap.add h (Int64.of_int (i * 37 mod 53)) i)
  in
  let removed, kept = List.partition (fun (i, _) -> i mod 3 = 0) entries in
  List.iter (fun (_, e) -> Timer_heap.remove h e) removed;
  List.iter (fun (_, e) -> Timer_heap.remove h e) removed;
  check int "length" (List.length kept) (Timer_heap.length h);
  let deadline i = i * 37 mod 53 in
  let expected =
    List.map fst kept
    |> List.sort (fun a b -> compare (deadline a) (deadline b))
  in
  check (list int) "remaining in order" expected (drain_heap h)

let ms n = Int64.mul (Int64.of_int n) 1_000_000L

let test_timeout () =
  with_ring @@ fun t ->
  let start = Uringan.now () in
  queue (Uringan.timeout t (ms 20) 1);
  check_result "expires" 1 (Error Uringan.etime) (next t);
  check bool "after 20ms" true (Int64.sub (Uringan.now ()) start >= ms 20)

let test_timeout_order () =
  with_ring @@ fun t ->
  queue (Uringan.timeout t (ms 30) 1);
  queue (Uringan.timeout t (ms 10) 2);
  queue (Uringan.timeout t (ms 20) 3);
  let order = List.init 3 (fun _ -> fst (next t)) in
  check (list int) "by deadline" [ 2; 3; 1 ] order

let test_timeout_absolute () =
  with_ring @@ fun t ->
  queue (Uringan.timeout ~absolute:true t (Int64.sub (Uringan.now ()) 1L) 1);
  match Uringan.get_cqe_nonblocking t with
  | Uringan.None -> fail "past deadline should expire at once"
  | Uringan.Some { data; result } ->
    check_result
      "past deadline"
      1
      (Error Uringan.etime)
      (data, Uringan.Res.int_result result)

let test_wait_shorter_than_timer () =
  with_ring @@ fun t ->
  let timer = Option.get (Uringan.timeout t (ms 10_000) 1) in
  let start = Uringan.now () in
  expect_none ~timeout:0.02 t;
  check bool "returned early" true (Int64.sub (Uringan.now ()) start < ms 500);
  queue (Uringan.cancel t timer 2);
  check_result "timer" 1 (Error Uringan.ecanceled) (next t);
  check_result "cancel" 2 (Ok 0) (next t)

let test_cancel_timeout () =
  with_ring @@ fun t ->
  let job = Option.get (Uringan.timeout t (ms 10_000) 1) in
  ignore (Uringan.submit t : int);
  queue (Uringan.cancel t job 2);
  check_result "target" 1 (Error Uringan.ecanceled) (next t);
  check_result "cancel" 2 (Ok 0) (next t);
  check int "idle" 0 (Uringan.active_ops t)

let test_cancel_parked_read () =
  with_ring @@ fun t ->
  with_pipe' @@ fun r w ->
  let buf = Cstruct.create 1 in
  let job = Option.get (Uringan.read t ~file_offset:current r buf 1) in
  expect_none t;
  queue (Uringan.cancel t job 2);
  check_result "target" 1 (Error Uringan.ecanceled) (next t);
  check_result "cancel" 2 (Ok 0) (next t);
  ignore (Unix.write_substring w "x" 0 1);
  expect_none t;
  queue (Uringan.read t ~file_offset:current r buf 3);
  check_result "later read gets the data" 3 (Ok 1) (next t)

let test_cancel_head_reader () =
  with_ring @@ fun t ->
  with_pipe' @@ fun r w ->
  let a = Cstruct.create 1
  and b = Cstruct.create 1 in
  let first = Option.get (Uringan.read t ~file_offset:current r a 1) in
  queue (Uringan.read t ~file_offset:current r b 2);
  expect_none t;
  queue (Uringan.cancel t first 3);
  check_result "first" 1 (Error Uringan.ecanceled) (next t);
  check_result "cancel" 3 (Ok 0) (next t);
  ignore (Unix.write_substring w "x" 0 1);
  check_result "second read moves up" 2 (Ok 1) (next t);
  check string "data" "x" (Cstruct.to_string b)

let test_cancel_completed () =
  with_ring @@ fun t ->
  let job = Option.get (Uringan.noop t 1) in
  ignore (Uringan.submit t : int);
  queue (Uringan.cancel t job 2);
  check_result "target" 1 (Ok 0) (next t);
  check_result "too late" 2 (Error Unix.ENOENT) (next t);
  check_raises
    "collected"
    (Invalid_argument "Uringan.cancel: job already collected")
    (fun () -> ignore (Uringan.cancel t job 3))

let test_exit_with_timer () =
  let t = Uringan.create ~queue_depth:4 () in
  let job = Option.get (Uringan.timeout t (ms 10_000) 1) in
  ignore (Uringan.submit t : int);
  check_raises
    "timer in flight"
    (Invalid_argument "Uringan.exit: 1 operation(s) in flight")
    (fun () -> Uringan.exit t);
  queue (Uringan.cancel t job 2);
  ignore (next t);
  ignore (next t);
  Uringan.exit t

(* Run one operation and return its result. *)
let run t op =
  queue (op t 0);
  match Uringan.wait ~timeout:1.0 t with
  | Uringan.None -> fail "no completion"
  | Uringan.Some { result; data = _ } -> result

let ok msg t op =
  check (result int unix_error) msg (Ok 0) (Uringan.Res.int_result (run t op))

let new_socket t domain ty =
  Uringan.Res.fd_exn (run t (fun t -> Uringan.socket t domain ty 0)) "socket" ""

let loopback = Unix.ADDR_INET (Unix.inet_addr_loopback, 0)

(* Collect [n] completions, sorted by user data. *)
let collect t n =
  List.sort
    (fun (a, _) (b, _) -> compare a b)
    (List.init n (fun _ ->
       match Uringan.wait ~timeout:1.0 t with
       | Uringan.None -> fail "no completion"
       | Uringan.Some { result; data } -> data, result))

let closing fds f = Fun.protect ~finally:(fun () -> List.iter Unix.close fds) f

(* A listening TCP socket on an ephemeral loopback port, and its address. *)
let with_listener t f =
  let l = new_socket t Unix.PF_INET Unix.SOCK_STREAM in
  closing [ l ] @@ fun () ->
  ok "bind" t (fun t -> Uringan.bind t l loopback);
  ok "listen" t (fun t -> Uringan.listen t l 8);
  f l (Unix.getsockname l)

let test_socket_nonblocking () =
  with_ring @@ fun t ->
  with_listener t @@ fun l _ ->
  (* A blocking socket would hang here. *)
  check_raises
    "accept"
    (Unix.Unix_error (Unix.EAGAIN, "accept", ""))
    (fun () -> ignore (Unix.accept l))

let test_tcp () =
  with_ring @@ fun t ->
  with_listener t @@ fun l addr ->
  let c = new_socket t Unix.PF_INET Unix.SOCK_STREAM in
  closing [ c ] @@ fun () ->
  let peer = Uringan.Sockaddr.create () in
  queue (Uringan.accept t l peer 1);
  queue (Uringan.connect t c addr 2);
  match collect t 2 with
  | [ (1, accepted); (2, connected) ] ->
    check
      (result int unix_error)
      "connect"
      (Ok 0)
      (Uringan.Res.int_result connected);
    let s = Uringan.Res.fd_exn accepted "accept" "" in
    closing [ s ] @@ fun () ->
    check
      bool
      "peer is client"
      true
      (Uringan.Sockaddr.get peer = Unix.getsockname c);
    (* Receive first, so it parks until the send arrives. *)
    let buf = Cstruct.create 16 in
    queue (Uringan.recv_msg t s (Uringan.Msghdr.create [ buf ]) 3);
    expect_none t;
    queue
      (Uringan.send_msg
         t
         c
         [ Cstruct.of_string "hello "; Cstruct.of_string "world" ]
         4);
    (match collect t 2 with
    | [ (3, received); (4, sent) ] ->
      check (result int unix_error) "sent" (Ok 11) (Uringan.Res.int_result sent);
      check
        (result int unix_error)
        "received"
        (Ok 11)
        (Uringan.Res.int_result received);
      check
        string
        "data"
        "hello world"
        (Cstruct.to_string (Cstruct.sub buf 0 11))
    | _ -> fail "unexpected completions");
    ok "shutdown" t (fun t -> Uringan.shutdown t c Unix.SHUTDOWN_SEND);
    queue (Uringan.read t ~file_offset:current s buf 5);
    check_result "eof after shutdown" 5 (Ok 0) (next t)
  | _ -> fail "unexpected completions"

(* A port that was ours and is now free, so connecting to it is refused. A
   socket that is bound but not listening is not enough: Linux answers its SYN
   with an RST, macOS drops it and the connect stays in progress. *)
let closed_port () =
  let l = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind l loopback;
  let addr = Unix.getsockname l in
  Unix.close l;
  addr

let test_connect_refused () =
  with_ring @@ fun t ->
  let addr = closed_port () in
  let c = new_socket t Unix.PF_INET Unix.SOCK_STREAM in
  closing [ c ] @@ fun () ->
  queue (Uringan.connect t c addr 1);
  check_result "refused" 1 (Error Unix.ECONNREFUSED) (next t)

let test_connect_unix_missing () =
  with_ring @@ fun t ->
  let c = new_socket t Unix.PF_UNIX Unix.SOCK_STREAM in
  closing [ c ] @@ fun () ->
  let path =
    Filename.concat (Filename.get_temp_dir_name ()) "uringan-missing"
  in
  queue (Uringan.connect t c (Unix.ADDR_UNIX path) 1);
  check_result "fails immediately" 1 (Error Unix.ENOENT) (next t)

let test_bad_address () =
  with_ring @@ fun t ->
  let fd = new_socket t Unix.PF_UNIX Unix.SOCK_STREAM in
  closing [ fd ] @@ fun () ->
  match Uringan.bind t fd (Unix.ADDR_UNIX (String.make 200 'x')) 1 with
  | exception Unix.Unix_error _ ->
    check int "nothing queued" 0 (Uringan.sqe_ready t)
  | _ -> fail "expected Unix_error"

let socketpair () =
  let a, b = Unix.socketpair ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.set_nonblock a;
  Unix.set_nonblock b;
  a, b

let test_pass_fd () =
  with_ring @@ fun t ->
  let a, b = socketpair () in
  let r, w = pipe () in
  closing [ a; b; r; w ] @@ fun () ->
  let buf = Cstruct.create 4 in
  let msg = Uringan.Msghdr.create ~n_fds:2 [ buf ] in
  queue (Uringan.recv_msg t b msg 1);
  queue (Uringan.send_msg ~fds:[ w ] t a [ Cstruct.of_string "fd" ] 2);
  (match collect t 2 with
  | [ (1, received); (2, sent) ] ->
    check (result int unix_error) "sent" (Ok 2) (Uringan.Res.int_result sent);
    check
      (result int unix_error)
      "received"
      (Ok 2)
      (Uringan.Res.int_result received)
  | _ -> fail "unexpected completions");
  match Uringan.Msghdr.get_fds msg with
  | [ w' ] ->
    closing [ w' ] @@ fun () ->
    check bool "a new descriptor" true (w' <> w);
    ignore (Unix.write_substring w' "via" 0 3);
    let b = Bytes.create 3 in
    ignore (Unix.read r b 0 3);
    check string "written through it" "via" (Bytes.to_string b)
  | fds -> failf "expected one descriptor, got %d" (List.length fds)

let test_udp () =
  with_ring @@ fun t ->
  let s = new_socket t Unix.PF_INET Unix.SOCK_DGRAM in
  let c = new_socket t Unix.PF_INET Unix.SOCK_DGRAM in
  closing [ s; c ] @@ fun () ->
  ok "bind" t (fun t -> Uringan.bind t s loopback);
  let buf = Cstruct.create 8 in
  let from = Uringan.Sockaddr.create () in
  check_raises
    "no address yet"
    (Invalid_argument "Uringan.Sockaddr.get: no address stored")
    (fun () -> ignore (Uringan.Sockaddr.get from));
  queue (Uringan.recv_msg t s (Uringan.Msghdr.create ~addr:from [ buf ]) 1);
  expect_none t;
  queue
    (Uringan.send_msg
       ~dst:(Unix.getsockname s)
       t
       c
       [ Cstruct.of_string "ping" ]
       2);
  (match collect t 2 with
  | [ (1, received); (2, sent) ] ->
    check (result int unix_error) "sent" (Ok 4) (Uringan.Res.int_result sent);
    check
      (result int unix_error)
      "received"
      (Ok 4)
      (Uringan.Res.int_result received)
  | _ -> fail "unexpected completions");
  check string "data" "ping" (Cstruct.to_string (Cstruct.sub buf 0 4));
  (* [c] is unbound, so its own name has a wildcard host. *)
  match Uringan.Sockaddr.get from, Unix.getsockname c with
  | Unix.ADDR_INET (host, port), Unix.ADDR_INET (_, port') ->
    check bool "sender host" true (host = Unix.inet_addr_loopback);
    check int "sender port" port' port
  | (Unix.ADDR_INET _ | Unix.ADDR_UNIX _), (Unix.ADDR_INET _ | Unix.ADDR_UNIX _)
    ->
    fail "expected inet addresses"

let test_accept_in_order () =
  with_ring @@ fun t ->
  with_listener t @@ fun l addr ->
  let peers = List.init 3 (fun _ -> Uringan.Sockaddr.create ()) in
  List.iteri (fun i p -> queue (Uringan.accept t l p i)) peers;
  expect_none t;
  let clients =
    List.init 3 (fun _ ->
      Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0)
  in
  closing clients @@ fun () ->
  (* Connect one at a time, so each accept gets a known client. *)
  List.iteri
    (fun i c ->
       Unix.connect c addr;
       match Uringan.wait ~timeout:1.0 t with
       | Uringan.None -> fail "no completion"
       | Uringan.Some { result; data } ->
         Unix.close (Uringan.Res.fd_exn result "accept" "");
         check int "accepts complete in order" i data;
         check
           bool
           "peer"
           true
           (Uringan.Sockaddr.get (List.nth peers i) = Unix.getsockname c))
    clients

let int_of (r : Uringan.Res.t) = Uringan.Res.int_result r

let ok_int msg expected r =
  check (result int unix_error) msg (Ok expected) (int_of r)

let rec rm_rf path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun f -> rm_rf (Filename.concat path f)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK ->
    Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_temp_dir f =
  let dir = Filename.temp_dir "uringan" "" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let kind =
  testable
    (Fmt.of_to_string (function
       | `Regular_file -> "regular file"
       | `Directory -> "directory"
       | `Symbolic_link -> "symlink"
       | `Character_special -> "character device"
       | `Block_device -> "block device"
       | `Fifo -> "fifo"
       | `Socket -> "socket"
       | `Unknown -> "unknown"))
    ( = )

let test_file_lifecycle () =
  with_ring @@ fun t ->
  with_temp_dir @@ fun dir ->
  let path = Filename.concat dir "f" in
  let fd =
    Uringan.Res.fd_exn
      (run t (fun t ->
         Uringan.openat t [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_EXCL ] 0o640 path))
      "openat"
      path
  in
  queue (Uringan.write t ~file_offset:(at 0) fd (Cstruct.of_string "hello") 1);
  check_result "write" 1 (Ok 5) (next t);
  ok_int "fsync" 0 (run t (fun t -> Uringan.fsync t fd));
  ok_int "fdatasync" 0 (run t (fun t -> Uringan.fdatasync t fd));
  let st = Uringan.Stat.create () in
  ok_int "fstatat" 0 (run t (fun t -> Uringan.fstatat t ~follow:true path st));
  check kind "kind" `Regular_file (Uringan.Stat.kind st);
  check int "perm" 0o640 (Uringan.Stat.perm st);
  check int64 "size" 5L (Uringan.Stat.size st);
  check int64 "nlink" 1L (Uringan.Stat.nlink st);
  let u = Unix.LargeFile.stat path in
  check int64 "ino" (Int64.of_int u.Unix.LargeFile.st_ino) (Uringan.Stat.ino st);
  check
    int64
    "mtime"
    (Int64.of_float u.Unix.LargeFile.st_mtime)
    (Uringan.Stat.mtime_sec st);
  check
    bool
    "mtime nsec in range"
    true
    (let n = Uringan.Stat.mtime_nsec st in
     n >= 0 && n < 1_000_000_000);
  ok_int "ftruncate" 0 (run t (fun t -> Uringan.ftruncate t fd ~len:2L));
  ok_int
    "fstat on fd"
    0
    (run t (fun t -> Uringan.fstatat t ~fd ~follow:true "" st));
  check int64 "truncated" 2L (Uringan.Stat.size st);
  ok_int "close" 0 (run t (fun t -> Uringan.close t fd));
  check_result
    "closed"
    0
    (Error Unix.EBADF)
    (0, int_of (run t (fun t -> Uringan.close t fd)));
  check_result
    "exclusive"
    0
    (Error Unix.EEXIST)
    ( 0
    , int_of
        (run t (fun t ->
           Uringan.openat
             t
             [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_EXCL ]
             0o640
             path)) )

let test_open_missing () =
  with_ring @@ fun t ->
  with_temp_dir @@ fun dir ->
  check
    (result int unix_error)
    "missing"
    (Error Unix.ENOENT)
    (int_of
       (run t (fun t ->
          Uringan.openat t [ Unix.O_RDONLY ] 0 (Filename.concat dir "nope"))))

let test_dir_ops () =
  with_ring @@ fun t ->
  with_temp_dir @@ fun dir ->
  let d = Unix.openfile dir [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  closing [ d ] @@ fun () ->
  let st = Uringan.Stat.create () in
  let stat ~follow path =
    ok_int
      ("stat " ^ path)
      0
      (run t (fun t -> Uringan.fstatat t ~fd:d ~follow path st));
    Uringan.Stat.kind st
  in
  ok_int
    "mkdirat"
    0
    (run t (fun t -> Uringan.mkdirat t ~mode:0o700 ~fd:d "sub"));
  check kind "sub" `Directory (stat ~follow:true "sub");
  check int "mode" 0o700 (Uringan.Stat.perm st);
  ok_int
    "symlinkat"
    0
    (run t (fun t ->
       Uringan.symlinkat t ~target:"sub" ~dir_fd:d ~link_path:"link"));
  check kind "link itself" `Symbolic_link (stat ~follow:false "link");
  check kind "link target" `Directory (stat ~follow:true "link");
  Unix.close
    (Unix.openfile
       (Filename.concat dir "sub/a")
       [ Unix.O_CREAT; Unix.O_WRONLY ]
       0o600);
  ok_int
    "linkat"
    0
    (run t (fun t ->
       Uringan.linkat
         t
         ~follow:false
         ~old_dir_fd:d
         ~old_path:"sub/a"
         ~new_dir_fd:d
         ~new_path:"b"));
  check
    int64
    "two links"
    2L
    (ignore (stat ~follow:true "b");
     Uringan.Stat.nlink st);
  ok_int
    "renameat"
    0
    (run t (fun t -> Uringan.renameat t ~old_dir_fd:d "b" ~new_dir_fd:d "c"));
  check
    (result int unix_error)
    "old name gone"
    (Error Unix.ENOENT)
    (int_of (run t (fun t -> Uringan.fstatat t ~fd:d ~follow:true "b" st)));
  check
    (result int unix_error)
    "not empty"
    (Error Unix.ENOTEMPTY)
    (int_of (run t (fun t -> Uringan.unlink t ~dir:true ~fd:d "sub")));
  ok_int
    "unlink file"
    0
    (run t (fun t -> Uringan.unlink t ~dir:false ~fd:d "sub/a"));
  ok_int
    "unlink dir"
    0
    (run t (fun t -> Uringan.unlink t ~dir:true ~fd:d "sub"));
  check
    (result int unix_error)
    "dir gone"
    (Error Unix.ENOENT)
    (int_of (run t (fun t -> Uringan.fstatat t ~fd:d ~follow:true "sub" st)))

let test_close_cancels_parked () =
  with_ring @@ fun t ->
  let r, w = pipe () in
  closing [ w ] @@ fun () ->
  queue (Uringan.read t ~file_offset:current r (Cstruct.create 4) 1);
  queue (Uringan.poll_add t r Uringan.Poll_mask.pollin 2);
  expect_none t;
  queue (Uringan.close t r 3);
  check_result "read" 1 (Error Uringan.ecanceled) (next t);
  check_result "poll" 2 (Error Uringan.ecanceled) (next t);
  check_result "close" 3 (Ok 0) (next t);
  check int "idle" 0 (Uringan.active_ops t);
  (* A new descriptor that reuses the number gets no stale events. *)
  let r', w' = pipe () in
  closing [ r'; w' ] @@ fun () ->
  ignore (Unix.write_substring w' "x" 0 1);
  queue (Uringan.read t ~file_offset:current r' (Cstruct.create 4) 4);
  check_result "fresh read" 4 (Ok 1) (next t)

let suite =
  [ "poll mask", `Quick, test_poll_mask
  ; "now is monotonic", `Quick, test_now_monotonic
  ; "ring lifecycle", `Quick, test_ring_lifecycle
  ]

let poller_suite =
  [ "readable", `Quick, test_poller_readable
  ; "oneshot", `Quick, test_poller_oneshot
  ; "delete", `Quick, test_poller_delete
  ; "hup", `Quick, test_poller_hup
  ; "timeout", `Quick, test_poller_timeout
  ; "events bounds", `Quick, test_events_bounds
  ]

let waker_suite =
  [ "drain", `Quick, test_waker_drain
  ; "wakes poller", `Quick, test_waker_wakes_poller
  ; "cross domain", `Quick, test_waker_cross_domain
  ]

let ring_suite =
  [ "noop", `Quick, test_noop
  ; "file pread/pwrite", `Quick, test_file_rw
  ; "pipe read parks", `Quick, test_pipe_read_parks
  ; "parked reads in order", `Quick, test_parked_reads_in_order
  ; "pipe write parks", `Quick, test_pipe_write_parks
  ; "read and write same fd", `Quick, test_read_and_write_same_fd
  ; "eof", `Quick, test_eof
  ; "error result", `Quick, test_error_result
  ; "queue full", `Quick, test_queue_full
  ; "exit in flight", `Quick, test_exit_in_flight
  ; "wakeup", `Quick, test_wakeup
  ; "wait timeout", `Quick, test_wait_timeout
  ; "file preadv/pwritev", `Quick, test_file_rwv
  ; "pipe readv/writev park", `Quick, test_pipe_rwv_parks
  ; "iov_max", `Quick, test_iov_max
  ; "poll readable", `Quick, test_poll_readable
  ; "poll immediate", `Quick, test_poll_immediate
  ; "poll hup", `Quick, test_poll_hup
  ; "poll bad fd", `Quick, test_poll_bad_fd
  ; "poll with reader", `Quick, test_poll_with_reader
  ; "timeout", `Quick, test_timeout
  ; "timeout order", `Quick, test_timeout_order
  ; "timeout absolute", `Quick, test_timeout_absolute
  ; "wait shorter than timer", `Quick, test_wait_shorter_than_timer
  ; "cancel timeout", `Quick, test_cancel_timeout
  ; "cancel parked read", `Quick, test_cancel_parked_read
  ; "cancel head reader", `Quick, test_cancel_head_reader
  ; "cancel completed", `Quick, test_cancel_completed
  ; "exit with timer", `Quick, test_exit_with_timer
  ]

let file_suite =
  [ "lifecycle", `Quick, test_file_lifecycle
  ; "open missing", `Quick, test_open_missing
  ; "directory ops", `Quick, test_dir_ops
  ; "close cancels parked", `Quick, test_close_cancels_parked
  ]

let socket_suite =
  [ "non-blocking", `Quick, test_socket_nonblocking
  ; "tcp", `Quick, test_tcp
  ; "connect refused", `Quick, test_connect_refused
  ; "connect unix missing", `Quick, test_connect_unix_missing
  ; "bad address", `Quick, test_bad_address
  ; "pass fd", `Quick, test_pass_fd
  ; "udp", `Quick, test_udp
  ; "accept in order", `Quick, test_accept_in_order
  ]

let heap_suite =
  [ "order", `Quick, test_heap_order
  ; "expiry", `Quick, test_heap_expiry
  ; "remove", `Quick, test_heap_remove
  ]

let () =
  Alcotest.run
    "uringan"
    [ "Uringan", suite
    ; "Ring", ring_suite
    ; "Socket", socket_suite
    ; "File", file_suite
    ; "Poller", poller_suite
    ; "Waker", waker_suite
    ; "Timer_heap", heap_suite
    ]
