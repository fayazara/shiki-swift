#ifndef SWIFT_DIFFS_REGEX_H
#define SWIFT_DIFFS_REGEX_H
#include <stdint.h>
#include <stddef.h>
typedef struct SDRegex SDRegex;
SDRegex *sd_regex_create(const char *pattern, size_t length, int ignore_case, int multiline, char *error, int error_size);
SDRegex *sd_regex_create_flags(const char *pattern, size_t length, const char *flags, char *error, int error_size);
void sd_regex_destroy(SDRegex *regex);
int sd_regex_capture_count(const SDRegex *regex);
/* Returns 1 for a match, 0 for none, -1 for allocation/stack failure, -2 for timeout. */
int sd_regex_exec(SDRegex *regex, const uint16_t *text, int length, int start, int32_t *ranges, int range_capacity, int timeout_ms);
#endif
