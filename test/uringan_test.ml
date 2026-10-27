open Alcotest

let test_poll_mask () =
  let open Uringan.Poll_mask in
  let m = pollin + pollout in
  check bool "pollin in mask" true (mem pollin m);
  check bool "pollerr not in mask" false (mem pollerr m);
  check bool "empty in any mask" true (mem empty m)

let suite = [ "poll mask", `Quick, test_poll_mask ]
let () = Alcotest.run "uringan" [ "Uringan", suite ]
