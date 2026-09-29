#include <stdint.h>
#include <stddef.h>
#include <string.h>

static const char escape_seqs_log[256][8] = {
    [0x00] = "\\u0000", [0x01] = "\\u0001", [0x02] = "\\u0002", [0x03] = "\\u0003",
    [0x04] = "\\u0004", [0x05] = "\\u0005", [0x06] = "\\u0006", [0x07] = "\\u0007",
    [0x08] = "\\b",     [0x09] = "\\t",     [0x0A] = "\\n",     [0x0B] = "\\u000b",
    [0x0C] = "\\f",     [0x0D] = "\\r",     [0x0E] = "\\u000e", [0x0F] = "\\u000f",
    [0x10] = "\\u0010", [0x11] = "\\u0011", [0x12] = "\\u0012", [0x13] = "\\u0013",
    [0x14] = "\\u0014", [0x15] = "\\u0015", [0x16] = "\\u0016", [0x17] = "\\u0017",
    [0x18] = "\\u0018", [0x19] = "\\u0019", [0x1A] = "\\u001a", [0x1B] = "\\u001b",
    [0x1C] = "\\u001c", [0x1D] = "\\u001d", [0x1E] = "\\u001e", [0x1F] = "\\u001f",
    [0x22] = "\\\"",    [0x5C] = "\\\\"
};
static const uint8_t escape_lens_log[256] = {
    [0x00] = 6, [0x01] = 6, [0x02] = 6, [0x03] = 6,
    [0x04] = 6, [0x05] = 6, [0x06] = 6, [0x07] = 6,
    [0x08] = 2, [0x09] = 2, [0x0A] = 2, [0x0B] = 6,
    [0x0C] = 2, [0x0D] = 2, [0x0E] = 6, [0x0F] = 6,
    [0x10] = 6, [0x11] = 6, [0x12] = 6, [0x13] = 6,
    [0x14] = 6, [0x15] = 6, [0x16] = 6, [0x17] = 6,
    [0x18] = 6, [0x19] = 6, [0x1A] = 6, [0x1B] = 6,
    [0x1C] = 6, [0x1D] = 6, [0x1E] = 6, [0x1F] = 6,
    [0x22] = 2, [0x5C] = 2
};

#if defined(__aarch64__)
#include <arm_neon.h>

size_t log_find_field_sep(const uint8_t *data, size_t len) {
    size_t i = 0;
    const uint8x16_t v_sep = vdupq_n_u8(0x1F);
    while (i + 16 <= len) {
        uint8x16_t chunk = vld1q_u8(data + i);
        uint8x16_t eq = vceqq_u8(chunk, v_sep);
        uint64_t lo = vgetq_lane_u64(vreinterpretq_u64_u8(eq), 0);
        uint64_t hi = vgetq_lane_u64(vreinterpretq_u64_u8(eq), 1);
        if (lo) return i + (size_t)(__builtin_ctzll(lo) >> 3);
        if (hi) return i + 8 + (size_t)(__builtin_ctzll(hi) >> 3);
        i += 16;
    }
    for (; i < len; i++) {
        if (data[i] == 0x1F) return i;
    }
    return len;
}

size_t log_json_escape(const uint8_t *src, size_t len, uint8_t *dst) {
    size_t d = 0, i = 0;
    const uint8x16_t v_quote = vdupq_n_u8(0x22);
    const uint8x16_t v_slash = vdupq_n_u8(0x5C);
    const uint8x16_t v_space = vdupq_n_u8(0x20);

    while (i + 16 <= len) {
        uint8x16_t chunk = vld1q_u8(src + i);
        uint8x16_t ctrl = vcltq_u8(chunk, v_space);
        uint8x16_t quot = vceqq_u8(chunk, v_quote);
        uint8x16_t bslash = vceqq_u8(chunk, v_slash);
        uint8x16_t unsafe = vorrq_u8(vorrq_u8(ctrl, quot), bslash);

        uint64_t lo = vgetq_lane_u64(vreinterpretq_u64_u8(unsafe), 0);
        uint64_t hi = vgetq_lane_u64(vreinterpretq_u64_u8(unsafe), 1);
        if (!(lo | hi)) {
            vst1q_u8(dst + d, chunk);
            d += 16; i += 16;
        } else {
            size_t unsafe_pos;
            if (lo) unsafe_pos = i + (size_t)(__builtin_ctzll(lo) >> 3);
            else    unsafe_pos = i + 8 + (size_t)(__builtin_ctzll(hi) >> 3);
            size_t safe_len = unsafe_pos - i;
            if (safe_len > 0) { memcpy(dst + d, src + i, safe_len); d += safe_len; }
            uint8_t b = src[unsafe_pos];
            uint8_t elen = escape_lens_log[b];
            memcpy(dst + d, escape_seqs_log[b], elen);
            d += elen;
            i = unsafe_pos + 1;
        }
    }
    for (; i < len; i++) {
        uint8_t c = src[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C) {
            uint8_t elen = escape_lens_log[c];
            memcpy(dst + d, escape_seqs_log[c], elen);
            d += elen;
        } else {
            dst[d++] = c;
        }
    }
    return d;
}

int log_needs_escape(const uint8_t *src, size_t len) {
    size_t i = 0;
    const uint8x16_t v_quote = vdupq_n_u8(0x22);
    const uint8x16_t v_slash = vdupq_n_u8(0x5C);
    const uint8x16_t v_space = vdupq_n_u8(0x20);
    while (i + 16 <= len) {
        uint8x16_t chunk = vld1q_u8(src + i);
        uint8x16_t ctrl = vcltq_u8(chunk, v_space);
        uint8x16_t quot = vceqq_u8(chunk, v_quote);
        uint8x16_t bslash = vceqq_u8(chunk, v_slash);
        uint8x16_t unsafe = vorrq_u8(vorrq_u8(ctrl, quot), bslash);
        uint64_t lo = vgetq_lane_u64(vreinterpretq_u64_u8(unsafe), 0);
        uint64_t hi = vgetq_lane_u64(vreinterpretq_u64_u8(unsafe), 1);
        if (lo | hi) return 1;
        i += 16;
    }
    for (; i < len; i++) {
        uint8_t c = src[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C) return 1;
    }
    return 0;
}

#elif defined(__x86_64__) || defined(_M_X64)
#include <emmintrin.h>

size_t log_find_field_sep(const uint8_t *data, size_t len) {
    size_t i = 0;
    const __m128i v_sep = _mm_set1_epi8(0x1F);
    while (i + 16 <= len) {
        __m128i chunk = _mm_loadu_si128((const __m128i *)(data + i));
        int mask = _mm_movemask_epi8(_mm_cmpeq_epi8(chunk, v_sep));
        if (mask) return i + (size_t)__builtin_ctz(mask);
        i += 16;
    }
    for (; i < len; i++) {
        if (data[i] == 0x1F) return i;
    }
    return len;
}

size_t log_json_escape(const uint8_t *src, size_t len, uint8_t *dst) {
    size_t d = 0, i = 0;
    const __m128i v_quote = _mm_set1_epi8(0x22);
    const __m128i v_slash = _mm_set1_epi8(0x5C);
    const __m128i v_space_m1 = _mm_set1_epi8(0x1F);

    while (i + 16 <= len) {
        __m128i chunk = _mm_loadu_si128((const __m128i *)(src + i));
        __m128i ctrl = _mm_cmpeq_epi8(_mm_min_epu8(chunk, v_space_m1), chunk);
        __m128i quot = _mm_cmpeq_epi8(chunk, v_quote);
        __m128i bslash = _mm_cmpeq_epi8(chunk, v_slash);
        int mask = _mm_movemask_epi8(_mm_or_si128(_mm_or_si128(ctrl, quot), bslash));
        if (!mask) {
            _mm_storeu_si128((__m128i *)(dst + d), chunk);
            d += 16; i += 16;
        } else {
            size_t unsafe_pos = i + (size_t)__builtin_ctz(mask);
            size_t safe_len = unsafe_pos - i;
            if (safe_len > 0) { memcpy(dst + d, src + i, safe_len); d += safe_len; }
            uint8_t b = src[unsafe_pos];
            uint8_t elen = escape_lens_log[b];
            memcpy(dst + d, escape_seqs_log[b], elen);
            d += elen;
            i = unsafe_pos + 1;
        }
    }
    for (; i < len; i++) {
        uint8_t c = src[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C) {
            uint8_t elen = escape_lens_log[c];
            memcpy(dst + d, escape_seqs_log[c], elen);
            d += elen;
        } else {
            dst[d++] = c;
        }
    }
    return d;
}

int log_needs_escape(const uint8_t *src, size_t len) {
    size_t i = 0;
    const __m128i v_quote = _mm_set1_epi8(0x22);
    const __m128i v_slash = _mm_set1_epi8(0x5C);
    const __m128i v_space_m1 = _mm_set1_epi8(0x1F);
    while (i + 16 <= len) {
        __m128i chunk = _mm_loadu_si128((const __m128i *)(src + i));
        __m128i ctrl = _mm_cmpeq_epi8(_mm_min_epu8(chunk, v_space_m1), chunk);
        __m128i quot = _mm_cmpeq_epi8(chunk, v_quote);
        __m128i bslash = _mm_cmpeq_epi8(chunk, v_slash);
        int mask = _mm_movemask_epi8(_mm_or_si128(_mm_or_si128(ctrl, quot), bslash));
        if (mask) return 1;
        i += 16;
    }
    for (; i < len; i++) {
        uint8_t c = src[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C) return 1;
    }
    return 0;
}

#else

size_t log_find_field_sep(const uint8_t *data, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (data[i] == 0x1F) return i;
    }
    return len;
}

size_t log_json_escape(const uint8_t *src, size_t len, uint8_t *dst) {
    size_t d = 0;
    for (size_t i = 0; i < len; i++) {
        uint8_t c = src[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C) {
            uint8_t elen = escape_lens_log[c];
            memcpy(dst + d, escape_seqs_log[c], elen);
            d += elen;
        } else {
            dst[d++] = c;
        }
    }
    return d;
}

int log_needs_escape(const uint8_t *src, size_t len) {
    for (size_t i = 0; i < len; i++) {
        uint8_t c = src[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C) return 1;
    }
    return 0;
}

#endif
