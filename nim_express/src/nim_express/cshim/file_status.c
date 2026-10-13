/* Minimal stat shim for the static file metadata fast path.
 *
 * Keeps the FFI boundary to four scalar fields instead of the full glibc
 * struct stat (whose layout is ABI/version dependent). The stat(2) syscall
 * happens in C where the struct is always correct; no path work is done
 * (no normalization, no allocation) so the static-serving hot path stays
 * allocation-free. See file_helpers.nim (fileStatusOrNone).
 */
#include <sys/stat.h>
#include <time.h>

typedef struct {
  unsigned int mode;
  long long size;
  long long mtime_sec;
  long long mtime_nsec;
} nim_fs_status_out;

int nim_fs_stat(const char *path, nim_fs_status_out *out) {
  struct stat st;
  if (stat(path, &st) != 0) {
    return -1;
  }
  out->mode = st.st_mode;
  out->size = (long long) st.st_size;
  out->mtime_sec = (long long) st.st_mtim.tv_sec;
  out->mtime_nsec = (long long) st.st_mtim.tv_nsec;
  return 0;
}
