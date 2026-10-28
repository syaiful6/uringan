#include <stdint.h>
#include <time.h>

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/mlvalues.h>

int64_t uringan_clock_now_unboxed(value v_unit) {
  (void)v_unit;
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

value uringan_clock_now(value v_unit) {
  return caml_copy_int64(uringan_clock_now_unboxed(v_unit));
}
