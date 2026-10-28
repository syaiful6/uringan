open Alcotest
module Epoll = Uringan.Private.Epoll
module Eventfd = Uringan.Private.Eventfd

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
  let ep = Epoll.create () in
  Fun.protect
    ~finally:(fun () -> List.iter Unix.close [ r; w; (ep :> Unix.file_descr) ])
    (fun () -> f ep r w)

let test_epoll_readable () =
  with_pipe @@ fun ep r w ->
  let events = Epoll.Events.create 8 in
  Epoll.add ep r Epoll.Flags.pollin;
  check int "nothing ready" 0 (Epoll.wait ep events ~timeout_ms:0);
  ignore (Unix.write_substring w "x" 0 1);
  check int "one ready" 1 (Epoll.wait ep events ~timeout_ms:1000);
  check bool "ready fd is read end" true (Epoll.Events.fd events 0 = r);
  check
    bool
    "pollin set"
    true
    (Epoll.Flags.mem Epoll.Flags.pollin (Epoll.Events.flags events 0))

let test_epoll_oneshot () =
  with_pipe @@ fun ep r w ->
  let events = Epoll.Events.create 8 in
  let flags = Epoll.Flags.(pollin + oneshot) in
  Epoll.add ep r flags;
  ignore (Unix.write_substring w "x" 0 1);
  check int "fires once" 1 (Epoll.wait ep events ~timeout_ms:1000);
  check int "disarmed" 0 (Epoll.wait ep events ~timeout_ms:0);
  Epoll.modify ep r flags;
  check int "re-armed" 1 (Epoll.wait ep events ~timeout_ms:0)

let test_epoll_delete () =
  with_pipe @@ fun ep r w ->
  let events = Epoll.Events.create 8 in
  Epoll.add ep r Epoll.Flags.pollin;
  Epoll.delete ep r;
  ignore (Unix.write_substring w "x" 0 1);
  check int "not watched" 0 (Epoll.wait ep events ~timeout_ms:0);
  check_raises
    "delete again"
    (Unix.Unix_error (Unix.ENOENT, "epoll_ctl", ""))
    (fun () -> Epoll.delete ep r)

let test_epoll_hup () =
  let r, w = Unix.pipe ~cloexec:true () in
  let ep = Epoll.create () in
  let events = Epoll.Events.create 8 in
  Epoll.add ep r Epoll.Flags.pollin;
  Unix.close w;
  check int "one ready" 1 (Epoll.wait ep events ~timeout_ms:1000);
  check
    bool
    "pollhup set"
    true
    (Epoll.Flags.mem Epoll.Flags.pollhup (Epoll.Events.flags events 0));
  Unix.close r;
  Epoll.close ep

let test_epoll_timeout () =
  let ep = Epoll.create () in
  let events = Epoll.Events.create 1 in
  let start = Uringan.now () in
  check int "times out" 0 (Epoll.wait ep events ~timeout_ms:20);
  Epoll.close ep;
  check
    bool
    "waited ~20ms"
    true
    (Int64.sub (Uringan.now ()) start >= 19_000_000L)

let test_events_bounds () =
  let events = Epoll.Events.create 2 in
  check int "length" 2 (Epoll.Events.length events);
  check_raises "out of bounds" (Invalid_argument "Epoll.Events.fd") (fun () ->
    ignore (Epoll.Events.fd events 2));
  check_raises
    "non-positive size"
    (Invalid_argument "Epoll.Events.create")
    (fun () -> ignore (Epoll.Events.create 0))

let test_ring_lifecycle () =
  let t = Uringan.create ~queue_depth:16 () in
  check int "queue_depth" 16 (Uringan.queue_depth t);
  check bool "backend" true (Uringan.backend t = `Epoll);
  Uringan.exit t;
  Uringan.exit t;
  check_raises
    "non-positive queue_depth"
    (Invalid_argument "Uringan.create: queue_depth <= 0")
    (fun () -> ignore (Uringan.create ~queue_depth:0 ()))

let with_eventfd f =
  let efd = Eventfd.create () in
  Fun.protect ~finally:(fun () -> Eventfd.close efd) (fun () -> f efd)

let test_eventfd_drain () =
  with_eventfd @@ fun efd ->
  check bool "not signalled" false (Eventfd.drain efd);
  Eventfd.signal efd;
  Eventfd.signal efd;
  check bool "signalled" true (Eventfd.drain efd);
  check bool "signals collapsed" false (Eventfd.drain efd)

let test_eventfd_wakes_epoll () =
  with_eventfd @@ fun efd ->
  let ep = Epoll.create () in
  let events = Epoll.Events.create 1 in
  Epoll.add ep (efd :> Unix.file_descr) Epoll.Flags.pollin;
  check int "idle" 0 (Epoll.wait ep events ~timeout_ms:0);
  Eventfd.signal efd;
  check int "woken" 1 (Epoll.wait ep events ~timeout_ms:0);
  check int "stays readable" 1 (Epoll.wait ep events ~timeout_ms:0);
  ignore (Eventfd.drain efd);
  check int "idle after drain" 0 (Epoll.wait ep events ~timeout_ms:0);
  Epoll.close ep

let test_eventfd_cross_domain () =
  with_eventfd @@ fun efd ->
  let ep = Epoll.create () in
  Epoll.add ep (efd :> Unix.file_descr) Epoll.Flags.pollin;
  let waiter =
    Domain.spawn (fun () ->
      Epoll.wait ep (Epoll.Events.create 1) ~timeout_ms:5000)
  in
  Unix.sleepf 0.02;
  let start = Uringan.now () in
  Eventfd.signal efd;
  check int "woken from other domain" 1 (Domain.join waiter);
  check
    bool
    "woke promptly"
    true
    (Int64.sub (Uringan.now ()) start < 1_000_000_000L);
  Epoll.close ep

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

let suite =
  [ "poll mask", `Quick, test_poll_mask
  ; "now is monotonic", `Quick, test_now_monotonic
  ; "ring lifecycle", `Quick, test_ring_lifecycle
  ]

let epoll_suite =
  [ "readable", `Quick, test_epoll_readable
  ; "oneshot", `Quick, test_epoll_oneshot
  ; "delete", `Quick, test_epoll_delete
  ; "hup", `Quick, test_epoll_hup
  ; "timeout", `Quick, test_epoll_timeout
  ; "events bounds", `Quick, test_events_bounds
  ]

let eventfd_suite =
  [ "drain", `Quick, test_eventfd_drain
  ; "wakes epoll", `Quick, test_eventfd_wakes_epoll
  ; "cross domain", `Quick, test_eventfd_cross_domain
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
  ]

let () =
  Alcotest.run
    "uringan"
    [ "Uringan", suite
    ; "Ring", ring_suite
    ; "Epoll", epoll_suite
    ; "Eventfd", eventfd_suite
    ]
