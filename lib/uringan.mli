(** I/O completion interface for epoll and kqueue *)

val greet : string -> string
(** Returns a greeting message.

    {4 Examples}

    {[ print_endline @@ greet "Jane" ]} *)
