(lang dune 3.0)

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
  (ocaml (>= 5.4.1))
  dune
  (cstruct (>= 6.0.0))
  (optint (>= 0.3.0))
  (alcotest :with-test)
  (fmt :with-test)
  (ocamlformat :with-dev-setup)
  (ocaml-lsp-server :with-dev-setup)
  (odoc :with-doc)))
