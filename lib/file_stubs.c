#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

/* File and directory stubs. They return the result or -errno, and release the
   runtime lock because file system operations can block. Paths are copied out
   of the OCaml heap first, since the GC may move them meanwhile.

   A directory descriptor argument is a [Unix.file_descr option]; [None] means
   the current directory. */

#ifndef O_RSYNC
#define O_RSYNC 0
#endif

static int dir_fd(value v_fd) {
  return Is_block(v_fd) ? Int_val(Field(v_fd, 0)) : AT_FDCWD;
}

static value result(int r, int err) { return Val_int(r == -1 ? -err : r); }

/* In the order of the Unix.open_flag constructors. O_CLOEXEC and O_KEEPEXEC
   are handled separately, as in Unix.openfile. */
static const int open_flags[] = {O_RDONLY, O_WRONLY, O_RDWR,   O_NONBLOCK,
                                 O_APPEND, O_CREAT,  O_TRUNC,  O_EXCL,
                                 O_NOCTTY, O_DSYNC,  O_SYNC,   O_RSYNC,
                                 0 /* O_SHARE_DELETE */, O_CLOEXEC, 0};
static const int keepexec_flag[] = {0, 0, 0, 0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0, 0, 1};

value uringan_openat(value v_dir_fd, value v_path, value v_flags,
                     value v_perm) {
  CAMLparam1(v_path);
  int flags = caml_convert_flag_list(v_flags, open_flags);
  if (!caml_convert_flag_list(v_flags, keepexec_flag) &&
      caml_unix_cloexec_default)
    flags |= O_CLOEXEC;
  int fd = dir_fd(v_dir_fd), perm = Int_val(v_perm), r, err;
  char *path = caml_stat_strdup(String_val(v_path));

  caml_enter_blocking_section();
  do
    r = openat(fd, path, flags, perm);
  while (r == -1 && errno == EINTR);
  err = errno;
  caml_leave_blocking_section();

  caml_stat_free(path);
  CAMLreturn(result(r, err));
}

/* The descriptor is released even if close is interrupted (Linux, and POSIX
   2024), so EINTR must not be retried; report success. */
value uringan_close(value v_fd) {
  int r, err;
  caml_enter_blocking_section();
  r = close(Int_val(v_fd));
  err = errno;
  caml_leave_blocking_section();
  if (r == -1 && err == EINTR) r = 0;
  return result(r, err);
}

value uringan_fsync(value v_fd, value v_data_only) {
  int fd = Int_val(v_fd), data_only = Bool_val(v_data_only), r, err;
  caml_enter_blocking_section();
#ifdef __APPLE__
  (void)data_only;
  r = fsync(fd);
#else
  r = data_only ? fdatasync(fd) : fsync(fd);
#endif
  err = errno;
  caml_leave_blocking_section();
  return result(r, err);
}

value uringan_ftruncate(value v_fd, value v_len) {
  int fd = Int_val(v_fd), r, err;
  off_t len = Int64_val(v_len);
  caml_enter_blocking_section();
  do
    r = ftruncate(fd, len);
  while (r == -1 && errno == EINTR);
  err = errno;
  caml_leave_blocking_section();
  return result(r, err);
}

value uringan_unlinkat(value v_dir_fd, value v_path, value v_dir) {
  CAMLparam1(v_path);
  int fd = dir_fd(v_dir_fd), flags = Bool_val(v_dir) ? AT_REMOVEDIR : 0, r, err;
  char *path = caml_stat_strdup(String_val(v_path));
  caml_enter_blocking_section();
  r = unlinkat(fd, path, flags);
  err = errno;
  caml_leave_blocking_section();
  caml_stat_free(path);
  CAMLreturn(result(r, err));
}

value uringan_mkdirat(value v_dir_fd, value v_path, value v_mode) {
  CAMLparam1(v_path);
  int fd = dir_fd(v_dir_fd), r, err;
  mode_t mode = Int_val(v_mode);
  char *path = caml_stat_strdup(String_val(v_path));
  caml_enter_blocking_section();
  r = mkdirat(fd, path, mode);
  err = errno;
  caml_leave_blocking_section();
  caml_stat_free(path);
  CAMLreturn(result(r, err));
}

value uringan_renameat(value v_old_dir_fd, value v_old, value v_new_dir_fd,
                       value v_new) {
  CAMLparam2(v_old, v_new);
  int old_fd = dir_fd(v_old_dir_fd), new_fd = dir_fd(v_new_dir_fd), r, err;
  char *old_path = caml_stat_strdup(String_val(v_old));
  char *new_path = caml_stat_strdup(String_val(v_new));
  caml_enter_blocking_section();
  r = renameat(old_fd, old_path, new_fd, new_path);
  err = errno;
  caml_leave_blocking_section();
  caml_stat_free(old_path);
  caml_stat_free(new_path);
  CAMLreturn(result(r, err));
}

value uringan_linkat(value v_old_dir_fd, value v_old, value v_new_dir_fd,
                     value v_new, value v_follow) {
  CAMLparam2(v_old, v_new);
  int old_fd = dir_fd(v_old_dir_fd), new_fd = dir_fd(v_new_dir_fd), r, err;
  int flags = Bool_val(v_follow) ? AT_SYMLINK_FOLLOW : 0;
  char *old_path = caml_stat_strdup(String_val(v_old));
  char *new_path = caml_stat_strdup(String_val(v_new));
  caml_enter_blocking_section();
  r = linkat(old_fd, old_path, new_fd, new_path, flags);
  err = errno;
  caml_leave_blocking_section();
  caml_stat_free(old_path);
  caml_stat_free(new_path);
  CAMLreturn(result(r, err));
}

value uringan_symlinkat(value v_target, value v_dir_fd, value v_link) {
  CAMLparam2(v_target, v_link);
  int fd = dir_fd(v_dir_fd), r, err;
  char *target = caml_stat_strdup(String_val(v_target));
  char *link = caml_stat_strdup(String_val(v_link));
  caml_enter_blocking_section();
  r = symlinkat(target, fd, link);
  err = errno;
  caml_leave_blocking_section();
  caml_stat_free(target);
  caml_stat_free(link);
  CAMLreturn(result(r, err));
}

/* Stat buffers are [bytes] of [sizeof(struct stat)]. The kernel writes into a
   local struct, which is copied over once the runtime lock is held again. */

value uringan_stat_size(value v_unit) {
  (void)v_unit;
  return Val_int(sizeof(struct stat));
}

/* An empty [path] examines the directory descriptor itself. */
value uringan_fstatat(value v_dir_fd, value v_path, value v_follow,
                      value v_buf) {
  CAMLparam2(v_path, v_buf);
  int fd = dir_fd(v_dir_fd), r, err;
  int flags = Bool_val(v_follow) ? 0 : AT_SYMLINK_NOFOLLOW;
  int self = caml_string_length(v_path) == 0 && Is_block(v_dir_fd);
  char *path = caml_stat_strdup(String_val(v_path));
  struct stat st;

  caml_enter_blocking_section();
  r = self ? fstat(fd, &st) : fstatat(fd, path, &st, flags);
  err = errno;
  caml_leave_blocking_section();

  caml_stat_free(path);
  if (r == 0) memcpy(Bytes_val(v_buf), &st, sizeof(st));
  CAMLreturn(result(r, err));
}

#ifdef __APPLE__
#define ST_TIM(st, t) ((st)->st_##t##timespec)
#else
#define ST_TIM(st, t) ((st)->st_##t##tim)
#endif

/* In the order of the Stat.kind variants, as listed in uringan.mli. */
static int64_t kind(mode_t m) {
  if (S_ISREG(m)) return 0;
  if (S_ISDIR(m)) return 1;
  if (S_ISLNK(m)) return 2;
  if (S_ISCHR(m)) return 3;
  if (S_ISBLK(m)) return 4;
  if (S_ISFIFO(m)) return 5;
  if (S_ISSOCK(m)) return 6;
  return 7;
}

/* Field [i] of a stat buffer, numbered as in fs.ml. */
int64_t uringan_stat_field_unboxed(value v_buf, intnat i) {
  const struct stat *st = (const struct stat *)Bytes_val(v_buf);
  switch (i) {
  case 0: return kind(st->st_mode);
  case 1: return st->st_mode & 07777;
  case 2: return st->st_size;
  case 3: return st->st_ino;
  case 4: return st->st_dev;
  case 5: return st->st_rdev;
  case 6: return st->st_nlink;
  case 7: return st->st_uid;
  case 8: return st->st_gid;
  case 9: return st->st_blksize;
  case 10: return st->st_blocks;
  case 11: return ST_TIM(st, a).tv_sec;
  case 12: return ST_TIM(st, a).tv_nsec;
  case 13: return ST_TIM(st, m).tv_sec;
  case 14: return ST_TIM(st, m).tv_nsec;
  case 15: return ST_TIM(st, c).tv_sec;
  case 16: return ST_TIM(st, c).tv_nsec;
  default: return 0;
  }
}

value uringan_stat_field(value v_buf, value v_i) {
  return caml_copy_int64(uringan_stat_field_unboxed(v_buf, Long_val(v_i)));
}
