#include "ShikiOnig.h"

#include "oniguruma.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// RegSet selection and long-line search caching follow vscode-oniguruma 1.7.0
// (716aeaa229e4ae2e3b0057377b55743e9a3e995b), Copyright Microsoft Corporation.
// See LICENSES/vscode-oniguruma.txt for its MIT license.

typedef struct {
    OnigRegex regex;
    OnigRegion *region;
    bool has_g_anchor;
    uint64_t search_generation;
    size_t search_position;
    OnigOptionType search_options;
    bool search_matched;
} ShikiOnigPattern;

struct ShikiOnigScanner {
    ShikiOnigPattern *patterns;
    size_t count;
    size_t capacity;
    size_t max_capture_count;
    OnigRegSet *regset; // Owns the compiled regexes, plus its own regions.
    uint64_t search_generation;
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

    ShikiOnigScanner *scanner = calloc(1, sizeof(ShikiOnigScanner));
    if (scanner == NULL) return NULL;
    if (onig_regset_new(&scanner->regset, 0, NULL) != ONIG_NORMAL) {
        free(scanner);
        return NULL;
    }
    scanner->search_generation = 1;
    return scanner;
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

    status = onig_regset_add(scanner->regset, regex);
    if (status != ONIG_NORMAL) {
        onig_region_free(region, 1);
        onig_free(regex);
        return false;
    }
    bool has_g_anchor = false;
    for (size_t index = 0; index + 1 < pattern_length; index += 1) {
        if (pattern[index] == '\\' && pattern[index + 1] == 'G') {
            has_g_anchor = true;
            break;
        }
    }
    scanner->patterns[scanner->count] = (ShikiOnigPattern){
        .regex = regex, .region = region, .has_g_anchor = has_g_anchor
    };
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
    }
    onig_regset_free(scanner->regset);
    free(scanner->patterns);
    free(scanner);
}

void shiki_onig_scanner_reset_search_cache(ShikiOnigScanner *scanner) {
    if (scanner == NULL) return;
    scanner->search_generation += 1;
    if (scanner->search_generation == 0) {
        for (size_t index = 0; index < scanner->count; index += 1) {
            scanner->patterns[index].search_generation = 0;
        }
        scanner->search_generation = 1;
    }
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

    if (scanner->count == 0) return 0;

    if (string_length < 1000) {
        int index = onig_regset_search(
            scanner->regset, string, string + string_length,
            string + start_position, string + string_length,
            ONIG_REGSET_POSITION_LEAD, search_options, &best_location
        );
        if (index < 0) return 0;
        best_pattern_index = (size_t)index;
        best_region = onig_regset_get_region(scanner->regset, index);
    } else {
        for (size_t index = 0; index < scanner->count; index += 1) {
            ShikiOnigPattern *pattern = &scanner->patterns[index];
            OnigRegion *region = pattern->region;
            bool can_reuse = !pattern->has_g_anchor
                && pattern->search_generation == scanner->search_generation
                && pattern->search_options == search_options
                && pattern->search_position <= start_position;
            if (can_reuse && !pattern->search_matched) continue;
            bool reuse_match = can_reuse && region->num_regs > 0
                && region->beg[0] >= 0 && (size_t)region->beg[0] >= start_position;
            if (!reuse_match) {
                int status = onig_search(
                    pattern->regex,
                    string,
                    string + string_length,
                    string + start_position,
                    string + string_length,
                    region,
                    search_options
                );
                pattern->search_generation = scanner->search_generation;
                pattern->search_position = start_position;
                pattern->search_options = search_options;
                pattern->search_matched = status >= 0 && region->num_regs > 0;
            }
            if (!pattern->search_matched) {
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
