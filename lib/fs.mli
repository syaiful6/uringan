(** Non-raising file and directory syscalls. Internal to {!Uringan}.

    Results are a non-negative value or a negative errno. A directory
    descriptor of [None] means the current directory. All of these may block,
    and release the runtime lock while they do. *)

type dir := Unix.file_descr option

val openat : dir -> string -> Unix.open_flag list -> Unix.file_perm -> int
(** Close-on-exec follows [O_CLOEXEC]/[O_KEEPEXEC] and the {!Unix} default,
    as in [Unix.openfile]. *)

val close : Unix.file_descr -> int
val fsync : Unix.file_descr -> data_only:bool -> int
val ftruncate : Unix.file_descr -> int64 -> int
val unlinkat : dir -> string -> dir:bool -> int
val mkdirat : dir -> string -> Unix.file_perm -> int
val renameat : dir -> string -> dir -> string -> int
val linkat : dir -> string -> dir -> string -> follow:bool -> int
val symlinkat : string -> dir -> string -> int

(** A buffer holding a C [struct stat]. *)
module Stat : sig
  type t

  val create : unit -> t

  val kind : t -> int
  (** The index of the file kind in [Uringan.Stat.kind]. *)

  val perm : t -> int
  val size : t -> int64
  val ino : t -> int64
  val dev : t -> int64
  val rdev : t -> int64
  val nlink : t -> int64
  val uid : t -> int64
  val gid : t -> int64
  val blksize : t -> int64
  val blocks : t -> int64
  val atime_sec : t -> int64
  val atime_nsec : t -> int
  val mtime_sec : t -> int64
  val mtime_nsec : t -> int
  val ctime_sec : t -> int64
  val ctime_nsec : t -> int
end

val fstatat : dir -> string -> follow:bool -> Stat.t -> int
(** An empty path with a directory descriptor examines the descriptor
    itself. *)
