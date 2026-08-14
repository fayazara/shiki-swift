#ifndef SHIKI_ONIG_H
#define SHIKI_ONIG_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ShikiOnigScanner ShikiOnigScanner;

enum ShikiOnigFindOption {
    SHIKI_ONIG_FIND_NONE = 0,
    SHIKI_ONIG_FIND_NOT_BEGIN_STRING = 1 << 0,
    SHIKI_ONIG_FIND_NOT_END_STRING = 1 << 1,
    SHIKI_ONIG_FIND_NOT_BEGIN_POSITION = 1 << 2,
};

ShikiOnigScanner *shiki_onig_scanner_create(void);

bool shiki_onig_scanner_add_pattern(
    ShikiOnigScanner *scanner,
    const uint8_t *pattern,
    size_t pattern_length,
    char *error_message,
    size_t error_message_capacity
);

void shiki_onig_scanner_destroy(ShikiOnigScanner *scanner);

size_t shiki_onig_scanner_max_capture_count(
    const ShikiOnigScanner *scanner
);

int shiki_onig_scanner_find_next(
    ShikiOnigScanner *scanner,
    const uint8_t *string,
    size_t string_length,
    size_t start_position,
    uint32_t options,
    size_t *pattern_index,
    int32_t *capture_starts,
    int32_t *capture_ends,
    size_t capture_capacity,
    size_t *capture_count
);

const char *shiki_onig_version(void);

#ifdef __cplusplus
}
#endif

#endif
