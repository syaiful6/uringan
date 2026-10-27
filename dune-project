(lang dune 2.0)

(name uringan)





(license ISC)

(authors
  "Syaiful Bahri")

(maintainers
  "Syaiful Bahri")

(generate_opam_files true)

(package
 (name uringan)
 (synopsis "I/O completion interface for epoll and kqueue")
 (description "I/O completion interface for epoll and kqueue")
 (depends
  (ocaml (>= 4.08.0))
  dune
  (alcotest :with-test)
  (odoc :with-doc)))
