type dir = Unix.file_descr option

external openat :
   dir
  -> string
  -> Unix.open_flag list
  -> Unix.file_perm
  -> int
  = "uringan_openat"

external close : Unix.file_descr -> int = "uringan_close"
external fsync : Unix.file_descr -> bool -> int = "uringan_fsync"
external ftruncate : Unix.file_descr -> int64 -> int = "uringan_ftruncate"
external unlinkat : dir -> string -> bool -> int = "uringan_unlinkat"
external mkdirat : dir -> string -> Unix.file_perm -> int = "uringan_mkdirat"
external renameat : dir -> string -> dir -> string -> int = "uringan_renameat"

external linkat :
   dir
  -> string
  -> dir
  -> string
  -> bool
  -> int
  = "uringan_linkat"

external symlinkat : string -> dir -> string -> int = "uringan_symlinkat"

let fsync fd ~data_only = fsync fd data_only
let unlinkat d path ~dir = unlinkat d path dir
let linkat od o nd n ~follow = linkat od o nd n follow

module Stat = struct
  type t = bytes

  external size_ : unit -> int = "uringan_stat_size"

  external field :
     t
    -> (int[@untagged])
    -> (int64[@unboxed])
    = "uringan_stat_field" "uringan_stat_field_unboxed"
  [@@noalloc]

  let size_ = size_ ()
  let create () = Bytes.make size_ '\000'

  (* Field numbers are those of uringan_stat_field_unboxed. *)
  let int t i = Int64.to_int (field t i)
  let kind t = int t 0
  let perm t = int t 1
  let size t = field t 2
  let ino t = field t 3
  let dev t = field t 4
  let rdev t = field t 5
  let nlink t = field t 6
  let uid t = field t 7
  let gid t = field t 8
  let blksize t = field t 9
  let blocks t = field t 10
  let atime_sec t = field t 11
  let atime_nsec t = int t 12
  let mtime_sec t = field t 13
  let mtime_nsec t = int t 14
  let ctime_sec t = field t 15
  let ctime_nsec t = int t 16
end

external fstatat : dir -> string -> bool -> Stat.t -> int = "uringan_fstatat"

let fstatat d path ~follow buf = fstatat d path follow buf
