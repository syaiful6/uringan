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

let () =
  Alcotest.run
    "uringan"
    [ "Uringan", suite; "Epoll", epoll_suite; "Eventfd", eventfd_suite ]
