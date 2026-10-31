type addr = bytes

(* The layouts of [peer] and [msghdr] are read and written by socket_stubs.c,
   which the unused-field warning cannot see. *)
type peer =
  { storage : bytes
  ; mutable len : int (* [0] until an address is stored. *)
  }
[@@warning "-69"]

type msghdr =
  { bufs : Cstruct.t list
  ; n_bufs : int
  ; addr : peer option
  ; fds : Unix.file_descr array
  ; mutable n_fds : int
  }
[@@warning "-69"]

external sockaddr_size : unit -> int = "uringan_sockaddr_size"
external encode : Unix.sockaddr -> addr = "uringan_sockaddr_encode"
external decode_ : bytes -> int -> Unix.sockaddr = "uringan_sockaddr_decode"

external socket :
   Unix.socket_domain
  -> Unix.socket_type
  -> int
  -> bool
  -> int
  = "uringan_socket"

external bind : Unix.file_descr -> addr -> int = "uringan_bind"
external listen : Unix.file_descr -> int -> int = "uringan_listen"

external shutdown :
   Unix.file_descr
  -> Unix.shutdown_command
  -> int
  = "uringan_shutdown"

external connect : Unix.file_descr -> addr -> int = "uringan_connect"
external connect_finish : Unix.file_descr -> int = "uringan_connect_finish"
external accept : Unix.file_descr -> peer -> int = "uringan_accept"

external send_msg_ :
   Unix.file_descr
  -> Cstruct.t list
  -> int
  -> Unix.file_descr array
  -> addr
  -> int
  = "uringan_sendmsg"

external recv_msg : Unix.file_descr -> msghdr -> int = "uringan_recvmsg"
external einprogress : unit -> int = "uringan_errno_einprogress"

let einprogress = einprogress ()
let sockaddr_size = sockaddr_size ()
let no_addr = Bytes.empty
let socket ~cloexec domain ty proto = socket domain ty proto cloexec
let peer () = { storage = Bytes.create sockaddr_size; len = 0 }
let decode p = if p.len = 0 then None else Some (decode_ p.storage p.len)

let iov_length name bufs =
  let n = List.length bufs in
  if n > Io.iov_max then invalid_arg (name ^ ": more than iov_max buffers");
  n

let send_msg fd bufs fds dst =
  send_msg_ fd bufs (iov_length "send_msg" bufs) fds dst

let msghdr ~n_fds addr bufs =
  { bufs
  ; n_bufs = iov_length "recv_msg" bufs
  ; addr
  ; fds = Array.make n_fds Unix.stdin
  ; n_fds = 0
  }

let received_fds m = List.init m.n_fds (Array.get m.fds)
