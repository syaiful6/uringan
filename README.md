# uringan

I/O completion interface for epoll and kqueue. Read this blogpost: https://tigerbeetle.com/blog/2022-11-23-a-friendly-abstraction-over-iouring-and-kqueue/

OCaml has [io_uring](https://github.com/ocaml-multicore/ocaml-uring/tree/main) binding, this library provides similar interface
but implemented in term of epoll or kqueue, the implementation will read or write the operation in user space of course.

The motivation is eventually use it for EIO scheduler.

## Installation

### Using Opam

```bash
opam install inquire
```

### Using Esy

```bash
esy add @opam/inquire
```

## Usage

### In OCaml

```ocaml
let () = Uringan.greet "World"
```

## Contributing

Take a look at our [Contributing Guide](CONTRIBUTING.md).
