#include "include/SwiftDiffsRegex.h"
#include "Prefix.h"
#include "Vendor/libregexp.h"
#include <stdlib.h>
#include <pthread.h>
#include <time.h>
#include <stdalign.h>
#include <stdint.h>
#include <limits.h>

struct SDRegex { uint8_t *code; uint8_t **captures; size_t allocated; uintptr_t stack_bottom; double deadline; };
typedef union { struct { size_t size; } value; max_align_t alignment; } SDAllocation;
static double sd_clock(void) { struct timespec value; clock_gettime(CLOCK_MONOTONIC, &value); return value.tv_sec + value.tv_nsec / 1e9; }
static void sd_prepare(SDRegex *regex, int timeout_ms) {
    pthread_t thread = pthread_self();
    regex->stack_bottom = (uintptr_t)pthread_get_stackaddr_np(thread) - pthread_get_stacksize_np(thread);
    regex->deadline = sd_clock() + timeout_ms / 1000.0;
}
int lre_check_stack_overflow(void *opaque, size_t size) {
    SDRegex *regex = opaque; volatile char marker;
    uintptr_t current = (uintptr_t)&marker;
    return current <= regex->stack_bottom + 65536 || size >= current - regex->stack_bottom - 65536;
}
int lre_check_timeout(void *opaque) { return sd_clock() > ((SDRegex *)opaque)->deadline; }
void *lre_realloc(void *opaque, void *pointer, size_t size) {
    SDRegex *regex = opaque;
    SDAllocation *old = pointer ? (SDAllocation *)pointer - 1 : NULL;
    size_t old_size = old ? old->value.size : 0;
    if (!size) { regex->allocated -= old_size; free(old); return NULL; }
    const size_t limit = 64 * 1024 * 1024;
    if (size > limit || regex->allocated - old_size > limit - size) return NULL;
    SDAllocation *next = realloc(old, sizeof(SDAllocation) + size);
    if (!next) return NULL;
    next->value.size = size; regex->allocated = regex->allocated - old_size + size;
    return next + 1;
}
static SDRegex *sd_regex_compile(const char *pattern, size_t length, int flags, char *error, int error_size) {
    SDRegex *regex = calloc(1, sizeof(SDRegex));
    if (!regex) return NULL;
    sd_prepare(regex, 1000);
    int size = 0;
    // QuickJS receives CESU-8 for non-Unicode JavaScript patterns. Swift sends
    // UTF-8; split astral literals into surrogate code units in that mode.
    char *converted = NULL;
    if (!(flags & (LRE_FLAG_UNICODE | LRE_FLAG_UNICODE_SETS))) {
        size_t extra = 0;
        for (size_t i = 0; i < length; i++)
            if (((unsigned char)pattern[i] & 0xf8) == 0xf0 && i + 3 < length) { extra += 2; i += 3; }
        if (extra) {
            if (length >= SIZE_MAX - extra) { free(regex); return NULL; }
            converted = lre_realloc(regex, NULL, length + extra + 1);
            if (!converted) { free(regex); return NULL; }
            size_t out = 0;
            for (size_t i = 0; i < length; i++) {
                unsigned char c = pattern[i];
                if ((c & 0xf8) == 0xf0 && i + 3 < length) {
                    uint32_t cp = ((c & 7) << 18) | (((unsigned char)pattern[i + 1] & 63) << 12)
                        | (((unsigned char)pattern[i + 2] & 63) << 6) | ((unsigned char)pattern[i + 3] & 63);
                    cp -= 0x10000;
                    uint16_t halves[2] = { 0xd800 | (cp >> 10), 0xdc00 | (cp & 1023) };
                    for (int n = 0; n < 2; n++) {
                        converted[out++] = 0xe0 | (halves[n] >> 12);
                        converted[out++] = 0x80 | ((halves[n] >> 6) & 63);
                        converted[out++] = 0x80 | (halves[n] & 63);
                    }
                    i += 3;
                } else converted[out++] = c;
            }
            converted[out] = 0; pattern = converted; length = out;
        }
    }
    regex->code = lre_compile(&size, error, error_size, pattern, length, flags, regex);
    if (converted) lre_realloc(regex, converted, 0);
    if (!regex->code) { free(regex); return NULL; }
    regex->captures = lre_realloc(regex, NULL, (size_t)lre_get_alloc_count(regex->code) * sizeof(uint8_t *));
    if (!regex->captures) { lre_realloc(regex, regex->code, 0); free(regex); return NULL; }
    return regex;
}
SDRegex *sd_regex_create(const char *pattern, size_t length, int ignore_case, int multiline, char *error, int error_size) {
    return sd_regex_compile(pattern, length, LRE_FLAG_GLOBAL | (ignore_case ? LRE_FLAG_IGNORECASE : 0) | (multiline ? LRE_FLAG_MULTILINE : 0), error, error_size);
}
SDRegex *sd_regex_create_flags(const char *pattern, size_t length, const char *flags, char *error, int error_size) {
    int bits = 0;
    for (const char *p = flags; *p; p++) {
        int flag;
        switch (*p) {
            case 'g': flag = LRE_FLAG_GLOBAL; break;
            case 'i': flag = LRE_FLAG_IGNORECASE; break;
            case 'm': flag = LRE_FLAG_MULTILINE; break;
            case 's': flag = LRE_FLAG_DOTALL; break;
            case 'u': flag = LRE_FLAG_UNICODE; break;
            case 'y': flag = LRE_FLAG_STICKY; break;
            case 'd': flag = LRE_FLAG_INDICES; break;
            case 'v': flag = LRE_FLAG_UNICODE_SETS; break;
            default: return NULL;
        }
        if (bits & flag) return NULL;
        bits |= flag;
    }
    if ((bits & LRE_FLAG_UNICODE) && (bits & LRE_FLAG_UNICODE_SETS)) return NULL;
    return sd_regex_compile(pattern, length, bits, error, error_size);
}
void sd_regex_destroy(SDRegex *regex) { if (regex) { lre_realloc(regex, regex->captures, 0); lre_realloc(regex, regex->code, 0); free(regex); } }
int sd_regex_capture_count(const SDRegex *regex) { return lre_get_capture_count(regex->code); }
int sd_regex_exec(SDRegex *regex, const uint16_t *text, int length, int start, int32_t *ranges, int capacity, int timeout_ms) {
    int count = lre_get_capture_count(regex->code);
    if (length < 0 || length > INT_MAX / 2 || start < 0 || start > length || capacity < count * 2) return -1;
    uint8_t **captures = regex->captures;
    sd_prepare(regex, timeout_ms);
    int result = lre_exec(captures, regex->code, (const uint8_t *)text, start, length, 1, regex);
    if (result == 1) for (int i = 0; i < count * 2; i++) ranges[i] = captures[i] ? (int32_t)((captures[i] - (const uint8_t *)text) / 2) : -1;
    return result;
}
