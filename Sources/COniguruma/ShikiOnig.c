#include "ShikiOnig.h"

#include "oniguruma.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    OnigRegex regex;
    OnigRegion *region;
} ShikiOnigPattern;

struct ShikiOnigScanner {
    ShikiOnigPattern *patterns;
    size_t count;
    size_t capacity;
    size_t max_capture_count;
};

static pthread_once_t shiki_onig_initialize_once = PTHREAD_ONCE_INIT;
static int shiki_onig_initialize_status = ONIGERR_FAIL_TO_INITIALIZE;

static void shiki_onig_initialize(void) {
    OnigEncoding encodings[] = { ONIG_ENCODING_UTF8 };
    shiki_onig_initialize_status = onig_initialize(encodings, 1);
}

static void copy_error(
    int status,
    const OnigErrorInfo *error_info,
    char *destination,
    size_t capacity
) {
    if (destination == NULL || capacity == 0) {
        return;
    }

    uint8_t message[ONIG_MAX_ERROR_MESSAGE_LEN];
    onig_error_code_to_str(message, status, error_info);
    size_t length = strlen((const char *)message);
    if (length >= capacity) {
        length = capacity - 1;
    }
    memcpy(destination, message, length);
    destination[length] = '\0';
}

ShikiOnigScanner *shiki_onig_scanner_create(void) {
    int once_status = pthread_once(
        &shiki_onig_initialize_once,
        shiki_onig_initialize
    );
    if (once_status != 0 || shiki_onig_initialize_status != ONIG_NORMAL) {
        return NULL;
    }

    return calloc(1, sizeof(ShikiOnigScanner));
}

bool shiki_onig_scanner_add_pattern(
    ShikiOnigScanner *scanner,
    const uint8_t *pattern,
    size_t pattern_length,
    char *error_message,
    size_t error_message_capacity
) {
    if (scanner == NULL || pattern == NULL) {
        return false;
    }

    OnigRegex regex = NULL;
    OnigErrorInfo error_info;
    int status = onig_new(
        &regex,
        pattern,
        pattern + pattern_length,
        ONIG_OPTION_CAPTURE_GROUP,
        ONIG_ENCODING_UTF8,
        ONIG_SYNTAX_DEFAULT,
        &error_info
    );

    if (status != ONIG_NORMAL) {
        copy_error(status, &error_info, error_message, error_message_capacity);
        return false;
    }

    OnigRegion *region = onig_region_new();
    if (region == NULL) {
        onig_free(regex);
        return false;
    }

    if (scanner->count == scanner->capacity) {
        size_t next_capacity = scanner->capacity == 0 ? 8 : scanner->capacity * 2;
        ShikiOnigPattern *next = realloc(
            scanner->patterns,
            next_capacity * sizeof(ShikiOnigPattern)
        );
        if (next == NULL) {
            onig_region_free(region, 1);
            onig_free(regex);
            return false;
        }
        scanner->patterns = next;
        scanner->capacity = next_capacity;
    }

    scanner->patterns[scanner->count].regex = regex;
    scanner->patterns[scanner->count].region = region;
    scanner->count += 1;

    size_t capture_count = (size_t)onig_number_of_captures(regex) + 1;
    if (capture_count > scanner->max_capture_count) {
        scanner->max_capture_count = capture_count;
    }
    return true;
}

void shiki_onig_scanner_destroy(ShikiOnigScanner *scanner) {
    if (scanner == NULL) {
        return;
    }

    for (size_t index = 0; index < scanner->count; index += 1) {
        onig_region_free(scanner->patterns[index].region, 1);
        onig_free(scanner->patterns[index].regex);
    }
    free(scanner->patterns);
    free(scanner);
}

size_t shiki_onig_scanner_max_capture_count(
    const ShikiOnigScanner *scanner
) {
    return scanner == NULL ? 0 : scanner->max_capture_count;
}

static OnigOptionType onig_options(uint32_t options) {
    OnigOptionType result = ONIG_OPTION_NONE;
    if ((options & SHIKI_ONIG_FIND_NOT_BEGIN_STRING) != 0) {
        result |= ONIG_OPTION_NOT_BEGIN_STRING;
    }
    if ((options & SHIKI_ONIG_FIND_NOT_END_STRING) != 0) {
        result |= ONIG_OPTION_NOT_END_STRING;
    }
    if ((options & SHIKI_ONIG_FIND_NOT_BEGIN_POSITION) != 0) {
        result |= ONIG_OPTION_NOT_BEGIN_POSITION;
    }
    return result;
}

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
) {
    if (scanner == NULL || string == NULL || start_position > string_length) {
        return -1;
    }

    OnigRegion *best_region = NULL;
    size_t best_pattern_index = 0;
    int best_location = 0;
    OnigOptionType search_options = onig_options(options);

    for (size_t index = 0; index < scanner->count; index += 1) {
        OnigRegion *region = scanner->patterns[index].region;
        int status = onig_search(
            scanner->patterns[index].regex,
            string,
            string + string_length,
            string + start_position,
            string + string_length,
            region,
            search_options
        );

        if (status < 0 || region->num_regs == 0) {
            continue;
        }

        int location = region->beg[0];
        if (best_region == NULL || location < best_location) {
            best_region = region;
            best_location = location;
            best_pattern_index = index;
        }

        if ((size_t)location == start_position) {
            break;
        }
    }

    if (best_region == NULL) {
        return 0;
    }

    if (pattern_index != NULL) {
        *pattern_index = best_pattern_index;
    }

    size_t count = (size_t)best_region->num_regs;
    if (capture_count != NULL) {
        *capture_count = count;
    }

    size_t copied_count = count < capture_capacity ? count : capture_capacity;
    for (size_t index = 0; index < copied_count; index += 1) {
        capture_starts[index] = (int32_t)best_region->beg[index];
        capture_ends[index] = (int32_t)best_region->end[index];
    }

    return 1;
}

const char *shiki_onig_version(void) {
    return onig_version();
}
