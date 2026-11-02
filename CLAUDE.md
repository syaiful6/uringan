# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

uringan is an OCaml library providing an io_uring-style I/O completion interface implemented on top of epoll (Linux) and kqueue (macOS/BSD). Reads and writes are performed in user space once readiness is reported, so callers see completion semantics rather than readiness semantics. Design reference: https://tigerbeetle.com/blog/2022-11-23-a-friendly-abstraction-over-iouring-and-kqueue/. The API should mirror the existing [ocaml-uring](https://github.com/ocaml-multicore/ocaml-uring) bindings where practical; the long-term goal is to back an Eio scheduler.

`lib/uringan.mli` holds the designed interface; `lib/uringan.ml` implements it over either backend. Execution model (documented at the top of the `.mli`): operations are queued, attempted eagerly and non-blocking on `submit`; `EAGAIN` parks them on the fd until epoll/kqueue readiness; regular-file and metadata ops run synchronously; timeouts live in a user-space timer heap. Deliberate design decisions:

- Callers must set `O_NONBLOCK` on sockets/pipes themselves; `socket`/`accept` return non-blocking fds.
- `file_offset = Optint.Int63.minus_one` means current position and is required for non-seekable fds (unlike ocaml-uring, which uses zero for sockets).
- `Res.t` is abstract (errno values differ across platforms), but keeps ocaml-uring's accessors.
- io_uring-only features (fixed buffers/`Region`, setup/rw flags, `openat2`, `statx`, `splice`, `fallocate`, probing, `register_eventfd`) are intentionally omitted; `wakeup` replaces `register_eventfd`.
- Target runtime is OCaml >= 5.4.1. Linux and macOS/BSD only (no Windows).

C stubs live in `lib/*_stubs.c` (compiled with `-Wall -Wextra -Werror`) behind thin internal OCaml modules (e.g. `lib/epoll.ml`), which `Uringan.Private` re-exports so tests can reach them. Blocking stubs release the runtime lock, so buffers they write to must live outside the OCaml heap (custom block or bigarray).

Backend selection (`lib/config/discover.ml`): a dune-configurator executable probes the platform macros and writes `lib/config.h` defining exactly one of `USE_EPOLL` / `USE_KQUEUE`. Both C and OCaml read that one file:
- Platform-specific C stubs `#include "config.h"` and wrap their whole body in `#ifdef USE_EPOLL` / `#ifdef USE_KQUEUE`, leaving an empty translation unit on the other platform (`config.h` is in the stubs' `extra_deps`).
- OCaml modules use `ppx_optcomp`: `[%%import "config.h"]` then `[%%ifdef ...]`. `lib/epoll.ml`/`.mli` and `lib/kqueue.ml`/`.mli` are each empty on the platform they do not serve, and `uringan.ml` aliases the surviving one as `Poller`. Adding a conditional module means adding `config.h` to that directory's `preprocessor_deps`; `test/dune` copies `lib/config.h` for the same reason.
- `Epoll` and `Kqueue` present the same interface, so only the alias, `backend`, and `Waker` are conditional. kqueue has no flag word, so `kqueue_stubs.c` defines its own epoll-shaped bits and translates filters into them: `EVFILT_READ` is `pollin`, `EVFILT_WRITE` is `pollout`, and `EV_EOF` is `pollrdhup` on a read and `pollhup` on a write. `add` and `modify` are the same `EV_ADD`, so a kqueue `modify` of an unregistered descriptor succeeds where `epoll_ctl` would fail with `ENOENT`, and one `wait` can report a descriptor's two directions as two events.
- `lib/waker.ml` is the wake-up channel behind `Uringan.wakeup`: an eventfd (`eventfd_stubs.c`) on Linux, a self-pipe elsewhere. It hides that difference behind `Waker.fd`, the descriptor the poller watches.

Ring internals (`lib/uringan.ml`): ocaml-uring's `Heap`/`Sketch` are not needed because no OCaml memory is handed to the kernel across calls. Instead:
- `sq` holds queued jobs and `cq` holds `(Res.t * 'a)` completions. `in_flight` counts queued, parked and uncollected jobs, and is bounded by `queue_depth`.
- `parked` maps each fd to FIFO `readers`/`writers` queues. A new job on an fd that already has waiters in the same direction is parked without being attempted, so stream data stays in order. On readiness, only the head of each queue is retried, until one returns `EAGAIN` again. `poll_add` jobs go in a separate `pollers` queue. They consume nothing, so they skip the ordering rule and all of them are rechecked with `poll(2)` (zero timeout) on every event, before readers and writers.
- Poller registrations are one-shot (`EPOLLONESHOT` / `EV_ONESHOT`). `armed` tracks interest that has not fired yet; `arm` tries `modify` first and falls back to `add` on `ENOENT`, because registrations outlive the `parked` entry.
- Each job has a `state` (`Queued`, `Parked`, `Sleeping`, `Completed`, `Collected`) so that `cancel`, which runs at `submit` like other ops, can find and remove its target. Retryable syscalls are a separate `io` type; parked queues hold `{ job; io }`.
- Timeouts live in `Timer_heap`, a min-heap whose entries know their own index, so cancelled timers are removed in O(log n) instead of lingering. `wait` blocks until the earlier of its own deadline and the earliest timer, rounded up to whole milliseconds, then fires expired timers.
- `Unix.error` has no `ETIME`/`ECANCELED`; they surface as `EUNKNOWNERR` and are exposed as `Uringan.etime`/`Uringan.ecanceled`.
- Socket syscalls live in `lib/socket_stubs.c` behind `lib/sock.ml`. `socket`/`bind`/`listen`/`shutdown` are `Sync` closures, run once at submit and never parked. A `connect` that returns `EINPROGRESS` parks as a writer under a different io, `Connect_finish`, which polls and then reads `SO_ERROR`. That is why `Parked` records the fd and queue it waits in, instead of deriving them from `job.op`. Sockaddrs are encoded into `bytes` at enqueue time using OCaml's `caml_unix_get_sockaddr`. `Sockaddr.t` and `Msghdr.t` are records whose layout `socket_stubs.c` reads and writes directly, so keep the two in sync.
- File and directory syscalls live in `lib/file_stubs.c` behind `lib/fs.ml`, and run as `Sync` closures. They release the runtime lock, so paths are copied with `caml_stat_strdup` first, and `fstatat` copies its `struct stat` into the `Stat.t` bytes only after the lock is held again. `close` is its own `op`, because it needs the ring: it fails parked jobs with `ecanceled` and deletes the poller registration before closing, so a stale registration cannot fire for a reused fd number.
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
