[%%import "config.h"]
[%%ifdef USE_EPOLL]

(* An eventfd: one descriptor, and the kernel collapses signals into a counter.
   See eventfd_stubs.c. *)

type t = Unix.file_descr

external create : unit -> t = "uringan_eventfd_create"
external signal : t -> unit = "uringan_eventfd_signal"
external drain : t -> bool = "uringan_eventfd_drain"

let fd t = t
let close = Unix.close

[%%else]

(* No eventfd outside Linux, so a self-pipe: the read end is what the poller
   watches, and one unread byte is enough to keep it readable, which is what
   collapses signals. *)

type t =
  { read : Unix.file_descr
  ; write : Unix.file_descr
  ; buf : Bytes.t
    (* Scratch for [drain], which only the ring's own thread calls. *)
  }

let create () =
  let read, write = Unix.pipe ~cloexec:true () in
  (try
     Unix.set_nonblock read;
     Unix.set_nonblock write
   with
  | e ->
    Unix.close read;
    Unix.close write;
    raise e);
  { read; write; buf = Bytes.create 64 }

let fd t = t.read

let close t =
  Unix.close t.read;
  Unix.close t.write

(* EAGAIN means the pipe is full, so it is already readable and the signal is
   not lost. *)
let rec signal t =
  match Unix.single_write_substring t.write "\000" 0 1 with
  | _ -> ()
  | exception Unix.Unix_error (Unix.EAGAIN, _, _) -> ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> signal t

let drain t =
  let len = Bytes.length t.buf in
  let rec loop signalled =
    match Unix.read t.read t.buf 0 len with
    | 0 -> signalled
    | n -> if n < len then true else loop true
    | exception Unix.Unix_error (Unix.EAGAIN, _, _) -> signalled
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop signalled
  in
  loop false

[%%endif]
