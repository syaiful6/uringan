type t = Unix.file_descr

external create : unit -> t = "uringan_eventfd_create"
external signal : t -> unit = "uringan_eventfd_signal"
external drain : t -> bool = "uringan_eventfd_drain"

let close = Unix.close
