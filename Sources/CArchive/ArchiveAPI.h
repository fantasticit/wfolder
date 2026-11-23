#ifndef WFOLDER_ARCHIVE_API_H
#define WFOLDER_ARCHIVE_API_H
#include <stdint.h>
#include <sys/types.h>

// Public libarchive declarations for the system library, whose headers are absent from the macOS SDK.
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_format_zip_seekable(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_into_fd(struct archive *, int);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
#endif
