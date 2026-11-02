[%%import "config.h"]
[%%ifdef USE_EPOLL]

type t = Unix.file_descr

module Flags = struct
  type t = int

  external pollin : unit -> int = "uringan_epoll_flag_in"
  external pollout : unit -> int = "uringan_epoll_flag_out"
  external pollerr : unit -> int = "uringan_epoll_flag_err"
  external pollhup : unit -> int = "uringan_epoll_flag_hup"
  external pollrdhup : unit -> int = "uringan_epoll_flag_rdhup"
  external oneshot : unit -> int = "uringan_epoll_flag_oneshot"

  let empty = 0
  let pollin = pollin ()
  let pollout = pollout ()
  let pollerr = pollerr ()
  let pollhup = pollhup ()
  let pollrdhup = pollrdhup ()
  let oneshot = oneshot ()
  let ( + ) = ( lor )
  let mem x t = x land t = x
end

module Events = struct
  type t

  external create : int -> t = "uringan_epoll_events_create"
  external length : t -> int = "uringan_epoll_events_length" [@@noalloc]

  external unsafe_fd : t -> int -> Unix.file_descr = "uringan_epoll_events_fd"
  [@@noalloc]

  external unsafe_flags : t -> int -> Flags.t = "uringan_epoll_events_flags"
  [@@noalloc]

  let check t i name =
    if i < 0 || i >= length t then invalid_arg ("Epoll.Events." ^ name)

  let fd t i =
    check t i "fd";
    unsafe_fd t i

  let flags t i =
    check t i "flags";
    unsafe_flags t i
end

external create : unit -> t = "uringan_epoll_create"

external ctl :
   t
  -> int
  -> Unix.file_descr
  -> Flags.t
  -> unit
  = "uringan_epoll_ctl"

external wait : t -> Events.t -> int -> int = "uringan_epoll_wait"

let close = Unix.close
let add t fd flags = ctl t 0 fd flags
let modify t fd flags = ctl t 1 fd flags
let delete t fd = ctl t 2 fd Flags.empty
let wait t events ~timeout_ms = wait t events timeout_ms

[%%endif]
