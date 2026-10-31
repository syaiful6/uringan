# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

uringan is an OCaml library providing an io_uring-style I/O completion interface implemented on top of epoll (Linux) and kqueue (macOS/BSD). Reads and writes are performed in user space once readiness is reported, so callers see completion semantics rather than readiness semantics. Design reference: https://tigerbeetle.com/blog/2022-11-23-a-friendly-abstraction-over-iouring-and-kqueue/. The API should mirror the existing [ocaml-uring](https://github.com/ocaml-multicore/ocaml-uring) bindings where practical; the long-term goal is to back an Eio scheduler.

`lib/uringan.mli` holds the designed interface; `lib/uringan.ml` implements it; the remaining file/metadata ops (`openat`, `close`, `fsync`, `Stat`/`fstatat`, ...) still raise `Failure "... not implemented"`. Execution model (documented at the top of the `.mli`): operations are queued, attempted eagerly and non-blocking on `submit`; `EAGAIN` parks them on the fd until epoll/kqueue readiness; regular-file and metadata ops run synchronously; timeouts live in a user-space timer heap. Deliberate design decisions:

- Callers must set `O_NONBLOCK` on sockets/pipes themselves; `socket`/`accept` return non-blocking fds.
- `file_offset = Optint.Int63.minus_one` means current position and is required for non-seekable fds (unlike ocaml-uring, which uses zero for sockets).
- `Res.t` is abstract (errno values differ across platforms), but keeps ocaml-uring's accessors.
- io_uring-only features (fixed buffers/`Region`, setup/rw flags, `openat2`, `statx`, `splice`, `fallocate`, probing, `register_eventfd`) are intentionally omitted; `wakeup` replaces `register_eventfd`.
- Target runtime is OCaml >= 5.4.1. Linux and macOS/BSD only (no Windows).

C stubs live in `lib/*_stubs.c` (compiled with `-Wall -Wextra -Werror`) behind thin internal OCaml modules (e.g. `lib/epoll.ml`), which `Uringan.Private` re-exports so tests can reach them. `epoll_stubs.c` is Linux-only and not yet guarded, so the library does not build on macOS until the kqueue backend and platform selection exist. Blocking stubs release the runtime lock, so buffers they write to must live outside the OCaml heap (custom block or bigarray).

Ring internals (`lib/uringan.ml`): ocaml-uring's `Heap`/`Sketch` are not needed because no OCaml memory is handed to the kernel across calls. Instead:
- `sq` holds queued jobs and `cq` holds `(Res.t * 'a)` completions. `in_flight` counts queued, parked and uncollected jobs, and is bounded by `queue_depth`.
- `parked` maps each fd to FIFO `readers`/`writers` queues. A new job on an fd that already has waiters in the same direction is parked without being attempted, so stream data stays in order. On readiness, only the head of each queue is retried, until one returns `EAGAIN` again. `poll_add` jobs go in a separate `pollers` queue. They consume nothing, so they skip the ordering rule and all of them are rechecked with `poll(2)` (zero timeout) on every event, before readers and writers.
- epoll registrations are `EPOLLONESHOT`. `armed` tracks interest that has not fired yet; `arm` tries `modify` first and falls back to `add` on `ENOENT`, because registrations outlive the `parked` entry.
- Each job has a `state` (`Queued`, `Parked`, `Sleeping`, `Completed`, `Collected`) so that `cancel`, which runs at `submit` like other ops, can find and remove its target. Retryable syscalls are a separate `io` type; parked queues hold `{ job; io }`.
- Timeouts live in `Timer_heap`, a min-heap whose entries know their own index, so cancelled timers are removed in O(log n) instead of lingering. `wait` blocks until the earlier of its own deadline and the earliest timer, rounded up to whole milliseconds, then fires expired timers.
- `Unix.error` has no `ETIME`/`ECANCELED`; they surface as `EUNKNOWNERR` and are exposed as `Uringan.etime`/`Uringan.ecanceled`.
- Socket syscalls live in `lib/socket_stubs.c` behind `lib/sock.ml`. `socket`/`bind`/`listen`/`shutdown` are `Sync` closures, run once at submit and never parked. A `connect` that returns `EINPROGRESS` parks as a writer under a different io, `Connect_finish`, which polls and then reads `SO_ERROR`. That is why `Parked` records the fd and queue it waits in, instead of deriving them from `job.op`. Sockaddrs are encoded into `bytes` at enqueue time using OCaml's `caml_unix_get_sockaddr`. `Sockaddr.t` and `Msghdr.t` are records whose layout `socket_stubs.c` reads and writes directly, so keep the two in sync.
- Syscall stubs return the byte count or `-errno` instead of raising, so `EAGAIN` can be detected cheaply (`Io.eagain`).

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
- ocamlformat options are in `.ocamlformat` (no version pin; the local switch has 0.29.0). Run `opam exec -- dune fmt` before committing; CI checks formatting with `make fmt` on Ubuntu.
- `.github/workflows/ci.yml` still targets OCaml 4.12 and Windows and needs updating to match `dune-project`. Tests have a 1-minute timeout in CI.
- `uringan.opam` is generated from `dune-project` (`generate_opam_files true`) — edit `dune-project`, not the opam file.
