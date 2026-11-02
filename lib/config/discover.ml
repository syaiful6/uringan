module C = Configurator.V1

let detect_system_header =
  {|
/* this file used by ppx_optcomp */
#if defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) ||     \
    defined(__APPLE__)
#define URINGAN_BACKEND "kqueue"
#elif __linux__
#define URINGAN_BACKEND "epoll"
#endif
|}

type backend =
  | Kqueue
  | Epoll

let get_backend t =
  let open C.C_define.Type in
  let header =
    let file = Filename.temp_file "discover" "backend.h" in
    let fd = open_out file in
    output_string fd detect_system_header;
    close_out fd;
    file
  in
  let backend =
    C.C_define.import t ~includes:[ header ] [ "URINGAN_BACKEND", String ]
  in
  match backend with
  | [ (_, C.C_define.Value.String "kqueue") ] -> Kqueue
  | [ (_, C.C_define.Value.String "epoll") ] -> Epoll
  | _ -> failwith "Unknown backend"

let () =
  C.main ~name:"uringan" (fun c ->
    let backend = get_backend c in
    C.C_define.gen_header_file
      c
      ~fname:"config.h"
      C.C_define.Value.
        [ ( "USE_KQUEUE"
          , match backend with Kqueue -> Int 1 | Epoll -> Switch false )
        ; ( "USE_EPOLL"
          , match backend with Epoll -> Int 1 | Kqueue -> Switch false )
        ])
