let todo name = failwith ("Uringan." ^ name ^ ": not implemented")

type 'a t = unit
type 'a job = unit

module Res = struct
  type t = (int, Unix.error) result

  let int_result t = t

  let int_exn t fn arg =
    match t with Ok n -> n | Error e -> raise (Unix.Unix_error (e, fn, arg))

  let fd_result _ = todo "Res.fd_result"
  let fd_exn _ _ _ = todo "Res.fd_exn"

  let pp ppf = function
    | Ok n -> Format.pp_print_int ppf n
    | Error e -> Format.pp_print_string ppf (Unix.error_message e)
end

let create ~queue_depth:_ () = todo "create"
let queue_depth _ = todo "queue_depth"
let exit _ = todo "exit"
let backend _ = todo "backend"
let noop _ _ = todo "noop"

external now :
   unit
  -> (int64[@unboxed])
  = "uringan_clock_now" "uringan_clock_now_unboxed"
[@@noalloc]

let timeout ?absolute:_ _ _ _ = todo "timeout"

module Poll_mask = struct
  type t = int

  let empty = 0
  let pollin = 1
  let pollout = 4
  let pollerr = 8
  let pollhup = 16
  let ( + ) = ( lor )
  let mem x t = x land t = x
end

let poll_add _ _ _ _ = todo "poll_add"
let read _ ~file_offset:_ _ _ _ = todo "read"
let write _ ~file_offset:_ _ _ _ = todo "write"
let iov_max = 1024
let readv _ ~file_offset:_ _ _ _ = todo "readv"
let writev _ ~file_offset:_ _ _ _ = todo "writev"
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
let submit _ = todo "submit"

type 'a completion_option =
  | None
  | Some of
      { result : Res.t
      ; data : 'a
      }

let wait ?timeout:_ _ = todo "wait"
let get_cqe_nonblocking _ = todo "get_cqe_nonblocking"
let wakeup _ = todo "wakeup"
let active_ops _ = todo "active_ops"
let sqe_ready _ = todo "sqe_ready"

module Private = struct
  module Epoll = Epoll
end
