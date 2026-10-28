// Minimal declarations for the system libarchive (/usr/lib/libarchive.2.dylib).
// The macOS SDK ships the library but not its headers.
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <time.h>

struct archive;
struct archive_entry;

#define LA_ARCHIVE_EOF 1
#define LA_ARCHIVE_OK 0
#define LA_ARCHIVE_RETRY (-10)
#define LA_ARCHIVE_WARN (-20)
#define LA_ARCHIVE_FAILED (-25)
#define LA_ARCHIVE_FATAL (-30)

struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_set_options(struct archive *, const char *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_skip(struct archive *);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_format_name(struct archive *);
int archive_filter_count(struct archive *);
const char *archive_filter_name(struct archive *, int);
int64_t archive_filter_bytes(struct archive *, int);

int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
