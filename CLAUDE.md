# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

uringan is an OCaml library providing an io_uring-style I/O completion interface implemented on top of epoll (Linux) and kqueue (macOS/BSD). Reads and writes are performed in user space once readiness is reported, so callers see completion semantics rather than readiness semantics. Design reference: https://tigerbeetle.com/blog/2022-11-23-a-friendly-abstraction-over-iouring-and-kqueue/. The API should mirror the existing [ocaml-uring](https://github.com/ocaml-multicore/ocaml-uring) bindings where practical; the long-term goal is to back an Eio scheduler.

`lib/uringan.mli` holds the designed interface; `lib/uringan.ml` is a stub where almost everything raises `Failure "... not implemented"`. Execution model (documented at the top of the `.mli`): operations are queued, attempted eagerly and non-blocking on `submit`; `EAGAIN` parks them on the fd until epoll/kqueue readiness; regular-file and metadata ops run synchronously; timeouts live in a user-space timer heap. Deliberate design decisions:

- Callers must set `O_NONBLOCK` on sockets/pipes themselves; `socket`/`accept` return non-blocking fds.
- `file_offset = Optint.Int63.minus_one` means current position and is required for non-seekable fds (unlike ocaml-uring, which uses zero for sockets).
- `Res.t` is abstract (errno values differ across platforms), but keeps ocaml-uring's accessors.
- io_uring-only features (fixed buffers/`Region`, setup/rw flags, `openat2`, `statx`, `splice`, `fallocate`, probing, `register_eventfd`) are intentionally omitted; `wakeup` replaces `register_eventfd`.
- Target runtime is OCaml >= 5.4.1. Linux and macOS/BSD only (no Windows).

README usage/install sections and CONTRIBUTING's mention of `bin/` are template leftovers (there is no `bin/` directory, so `make start` will fail).

## Commands

All Makefile targets wrap `opam exec -- dune ... --root .`; a local opam switch lives in `_opam/`.

- `make switch` / `make deps` — install dependencies (local switch / global)
- `make build` — build everything; `make` alone builds only `@install` targets
- `make test` — run tests (`dune runtest`)
- `make fmt` — format with ocamlformat and auto-promote changes
- `make doc` — build odoc docs
- `make utop` — REPL with the library loaded
- `make watch` — rebuild on change

Run a single alcotest case: `opam exec -- dune exec test/uringan_test.exe -- test <suite-name> <case-index>` (e.g. `test Uringan 0`). Dependencies: `cstruct`, `optint`, `alcotest` (tests).

## Conventions

- Public API is defined in `lib/uringan.mli` with odoc comments; keep `.ml` and `.mli` in sync.
- Dev profile (root `dune`) enables all warnings (`+A` minus 42/44/48) and treats them as errors except deprecation (3), so unused values/variables break the build.
- ocamlformat is pinned to 0.18.0 (`.ocamlformat`, conventional profile); CI checks formatting with `make fmt` on Ubuntu.
- `.github/workflows/ci.yml` still targets OCaml 4.12 and Windows and needs updating to match `dune-project`. Tests have a 1-minute timeout in CI.
- `uringan.opam` is generated from `dune-project` (`generate_opam_files true`) — edit `dune-project`, not the opam file.
