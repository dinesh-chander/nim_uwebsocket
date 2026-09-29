/*
 * escaped_scan.c — SIMD-accelerated JSON unsafe byte scanner
 *
 * Finds the next byte requiring JSON string escaping:
 *   - control chars (0x00-0x1F)
 *   - double quote (0x22)
 *   - backslash (0x5C)
 *
 * Uses NEON on ARM64 (Apple Silicon), SSE2 on x86-64,
 * and a scalar fallback otherwise.
 */

#include <stdint.h>
#include <stddef.h>

#include <string.h>

/*
 * Escape table: for each byte value, stores the escape sequence.
 * Most bytes are identity (length 1). Only control chars, quote, backslash need escaping.
 */
static const char escape_seqs[256][8] = {
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
static const uint8_t escape_lens[256] = {
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

/*
 * json_scan_copy_quoted — fused scan+copy for JSON string serialization.
 * Writes: quote + src_bytes + quote to dst, while scanning for unsafe bytes.
 * Returns total bytes written (len+2) if entire string is safe.
 * Returns 0 if any unsafe byte is found (caller falls back to slow path).
 * dst must have room for len + 2 bytes.
 */
size_t json_scan_copy_quoted(const char *src, size_t len, char *dst) {
    size_t i = 0;
    const uint8x16_t v_quote = vdupq_n_u8(0x22);
    const uint8x16_t v_slash = vdupq_n_u8(0x5C);
    const uint8x16_t v_space = vdupq_n_u8(0x20);

    /* dst[0] = quote, data starts at dst+1 */
    dst[0] = '"';
    char *out = dst + 1;

    while (i + 16 <= len) {
        uint8x16_t chunk = vld1q_u8((const uint8_t *)(src + i));

        uint8x16_t ctrl = vcltq_u8(chunk, v_space);
        uint8x16_t quot = vceqq_u8(chunk, v_quote);
        uint8x16_t bslash = vceqq_u8(chunk, v_slash);
        uint8x16_t unsafe = vorrq_u8(vorrq_u8(ctrl, quot), bslash);

        uint64_t lo = vgetq_lane_u64(vreinterpretq_u64_u8(unsafe), 0);
        uint64_t hi = vgetq_lane_u64(vreinterpretq_u64_u8(unsafe), 1);
        if (lo | hi) {
            return 0; /* unsafe found — caller falls back */
        }
        /* All 16 bytes safe — store them */
        vst1q_u8((uint8_t *)(out + i), chunk);
        i += 16;
    }

    /* Scalar tail */
    while (i < len) {
        uint8_t c = (uint8_t)src[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C) {
            return 0; /* unsafe found */
        }
        out[i] = c;
        i++;
    }

    out[len] = '"';
    return len + 2;
}

size_t json_next_unsafe(const char *s, size_t len, size_t start) {
    size_t i = start;
    const uint8x16_t v_quote = vdupq_n_u8(0x22);
    const uint8x16_t v_slash = vdupq_n_u8(0x5C);
    const uint8x16_t v_space = vdupq_n_u8(0x20);

    while (i + 16 <= len) {
        uint8x16_t chunk = vld1q_u8((const uint8_t *)(s + i));

        /* control chars: byte < 0x20 */
        uint8x16_t ctrl = vcltq_u8(chunk, v_space);
        uint8x16_t quot = vceqq_u8(chunk, v_quote);
        uint8x16_t bslash = vceqq_u8(chunk, v_slash);
        uint8x16_t unsafe = vorrq_u8(vorrq_u8(ctrl, quot), bslash);

        /* Narrow 16 lanes to 8-bit mask via max-reduce per half */
        uint64_t lo = vgetq_lane_u64(vreinterpretq_u64_u8(unsafe), 0);
        uint64_t hi = vgetq_lane_u64(vreinterpretq_u64_u8(unsafe), 1);
        if (lo | hi) {
            /* Find first unsafe byte in the 16-byte window */
            if (lo) {
                /* ctz on the 64-bit lane gives bit offset; divide by 8 for byte */
                return i + (size_t)(__builtin_ctzll(lo) >> 3);
            } else {
                return i + 8 + (size_t)(__builtin_ctzll(hi) >> 3);
            }
        }
        i += 16;
    }

    /* Scalar tail */
    for (; i < len; i++) {
        uint8_t c = (uint8_t)s[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C)
            return i;
    }
    return len;
}

/*
 * json_write_string — complete JSON string serialization in C.
 * Writes: quote + escaped_content + quote to dst.
 * Uses NEON for fast safe-chunk detection and bulk copy.
 * Returns number of bytes written to dst.
 * dst must have room for at least len*6 + 2 bytes (worst case: all \u00xx).
 */
size_t json_write_string(const char *src, size_t len, char *dst) {
    size_t d = 0;
    size_t i = 0;
    const uint8x16_t v_quote = vdupq_n_u8(0x22);
    const uint8x16_t v_slash = vdupq_n_u8(0x5C);
    const uint8x16_t v_space = vdupq_n_u8(0x20);

    dst[d++] = '"';

    while (i + 16 <= len) {
        uint8x16_t chunk = vld1q_u8((const uint8_t *)(src + i));
        uint8x16_t ctrl = vcltq_u8(chunk, v_space);
        uint8x16_t quot = vceqq_u8(chunk, v_quote);
        uint8x16_t bslash = vceqq_u8(chunk, v_slash);
        uint8x16_t unsafe = vorrq_u8(vorrq_u8(ctrl, quot), bslash);

        uint64_t lo = vgetq_lane_u64(vreinterpretq_u64_u8(unsafe), 0);
        uint64_t hi = vgetq_lane_u64(vreinterpretq_u64_u8(unsafe), 1);
        if (!(lo | hi)) {
            /* All 16 bytes safe — bulk store */
            vst1q_u8((uint8_t *)(dst + d), chunk);
            d += 16;
            i += 16;
        } else {
            /* Process byte-by-byte until next safe 16-byte chunk */
            size_t unsafe_pos;
            if (lo) {
                unsafe_pos = i + (size_t)(__builtin_ctzll(lo) >> 3);
            } else {
                unsafe_pos = i + 8 + (size_t)(__builtin_ctzll(hi) >> 3);
            }
            /* Copy safe prefix */
            size_t safe_len = unsafe_pos - i;
            if (safe_len > 0) {
                memcpy(dst + d, src + i, safe_len);
                d += safe_len;
            }
            /* Escape the unsafe byte */
            uint8_t b = (uint8_t)src[unsafe_pos];
            uint8_t elen = escape_lens[b];
            memcpy(dst + d, escape_seqs[b], elen);
            d += elen;
            i = unsafe_pos + 1;
        }
    }

    /* Scalar tail */
    for (; i < len; i++) {
        uint8_t c = (uint8_t)src[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C) {
            uint8_t elen = escape_lens[c];
            memcpy(dst + d, escape_seqs[c], elen);
            d += elen;
        } else {
            dst[d++] = (char)c;
        }
    }

    dst[d++] = '"';
    return d;
}

#elif defined(__x86_64__) || defined(_M_X64)
#include <emmintrin.h>  /* SSE2 */

/* Runtime AVX2 detection via cpuid */
static int has_avx2_cached = -1;

static int detect_avx2(void) {
    if (has_avx2_cached >= 0) return has_avx2_cached;
#if defined(__GNUC__) || defined(__clang__)
    unsigned int eax, ebx, ecx, edx;
    /* Check OSXSAVE (cpuid 1, ecx bit 27) */
    __asm__ __volatile__("cpuid" : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx)
                         : "a"(1), "c"(0));
    if (!(ecx & (1u << 27))) { has_avx2_cached = 0; return 0; }
    /* Check AVX2 (cpuid 7, ebx bit 5) */
    __asm__ __volatile__("cpuid" : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx)
                         : "a"(7), "c"(0));
    has_avx2_cached = (ebx & (1u << 5)) ? 1 : 0;
#else
    has_avx2_cached = 0;
#endif
    return has_avx2_cached;
}

#if defined(__AVX2__) || defined(JSON_FORCE_AVX2)
#include <immintrin.h>

static size_t json_next_unsafe_avx2(const char *s, size_t len, size_t start) {
    size_t i = start;
    const __m256i v_quote = _mm256_set1_epi8(0x22);
    const __m256i v_slash = _mm256_set1_epi8(0x5C);
    const __m256i v_space = _mm256_set1_epi8(0x20);

    while (i + 32 <= len) {
        __m256i chunk = _mm256_loadu_si256((const __m256i *)(s + i));
        /* control: byte < 0x20 via unsigned saturating sub */
        __m256i below_space = _mm256_cmpeq_epi8(
            _mm256_min_epu8(chunk, _mm256_set1_epi8(0x1F)), chunk);
        __m256i quot = _mm256_cmpeq_epi8(chunk, v_quote);
        __m256i bslash = _mm256_cmpeq_epi8(chunk, v_slash);
        int mask = _mm256_movemask_epi8(
            _mm256_or_si256(_mm256_or_si256(below_space, quot), bslash));
        if (mask) {
            return i + (size_t)__builtin_ctz(mask);
        }
        i += 32;
    }
    /* SSE2 tail for 16-byte remainder */
    {
        const __m128i v_quote128 = _mm_set1_epi8(0x22);
        const __m128i v_slash128 = _mm_set1_epi8(0x5C);
        const __m128i v_space_m1 = _mm_set1_epi8(0x1F);
        while (i + 16 <= len) {
            __m128i chunk = _mm_loadu_si128((const __m128i *)(s + i));
            __m128i ctrl = _mm_cmpeq_epi8(_mm_min_epu8(chunk, v_space_m1), chunk);
            __m128i quot2 = _mm_cmpeq_epi8(chunk, v_quote128);
            __m128i bslash2 = _mm_cmpeq_epi8(chunk, v_slash128);
            int m = _mm_movemask_epi8(_mm_or_si128(_mm_or_si128(ctrl, quot2), bslash2));
            if (m) return i + (size_t)__builtin_ctz(m);
            i += 16;
        }
    }
    for (; i < len; i++) {
        uint8_t c = (uint8_t)s[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C) return i;
    }
    return len;
}
#endif /* __AVX2__ */

static size_t json_next_unsafe_sse2(const char *s, size_t len, size_t start) {
    size_t i = start;
    const __m128i v_quote = _mm_set1_epi8(0x22);
    const __m128i v_slash = _mm_set1_epi8(0x5C);
    const __m128i v_space_m1 = _mm_set1_epi8(0x1F);

    while (i + 16 <= len) {
        __m128i chunk = _mm_loadu_si128((const __m128i *)(s + i));
        __m128i ctrl = _mm_cmpeq_epi8(_mm_min_epu8(chunk, v_space_m1), chunk);
        __m128i quot = _mm_cmpeq_epi8(chunk, v_quote);
        __m128i bslash = _mm_cmpeq_epi8(chunk, v_slash);
        int mask = _mm_movemask_epi8(_mm_or_si128(_mm_or_si128(ctrl, quot), bslash));
        if (mask) {
            return i + (size_t)__builtin_ctz(mask);
        }
        i += 16;
    }

    /* Scalar tail */
    for (; i < len; i++) {
        uint8_t c = (uint8_t)s[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C)
            return i;
    }
    return len;
}

size_t json_next_unsafe(const char *s, size_t len, size_t start) {
#if defined(__AVX2__) || defined(JSON_FORCE_AVX2)
    if (detect_avx2())
        return json_next_unsafe_avx2(s, len, start);
#endif
    return json_next_unsafe_sse2(s, len, start);
}

size_t json_scan_copy_quoted(const char *src, size_t len, char *dst) {
    size_t i = 0;
    const __m128i v_quote = _mm_set1_epi8(0x22);
    const __m128i v_slash = _mm_set1_epi8(0x5C);
    const __m128i v_space_m1 = _mm_set1_epi8(0x1F);

    dst[0] = '"';
    char *out = dst + 1;

    while (i + 16 <= len) {
        __m128i chunk = _mm_loadu_si128((const __m128i *)(src + i));
        __m128i ctrl = _mm_cmpeq_epi8(_mm_min_epu8(chunk, v_space_m1), chunk);
        __m128i quot = _mm_cmpeq_epi8(chunk, v_quote);
        __m128i bslash = _mm_cmpeq_epi8(chunk, v_slash);
        int mask = _mm_movemask_epi8(_mm_or_si128(_mm_or_si128(ctrl, quot), bslash));
        if (mask) return 0;
        _mm_storeu_si128((__m128i *)(out + i), chunk);
        i += 16;
    }
    while (i < len) {
        uint8_t c = (uint8_t)src[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C) return 0;
        out[i] = c;
        i++;
    }
    out[len] = '"';
    return len + 2;
}

size_t json_write_string(const char *src, size_t len, char *dst) {
    size_t d = 0;
    size_t i = 0;
    const __m128i v_quote = _mm_set1_epi8(0x22);
    const __m128i v_slash = _mm_set1_epi8(0x5C);
    const __m128i v_space_m1 = _mm_set1_epi8(0x1F);

    dst[d++] = '"';
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
            uint8_t b = (uint8_t)src[unsafe_pos];
            uint8_t elen = escape_lens[b];
            memcpy(dst + d, escape_seqs[b], elen);
            d += elen;
            i = unsafe_pos + 1;
        }
    }
    for (; i < len; i++) {
        uint8_t c = (uint8_t)src[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C) {
            uint8_t elen = escape_lens[c];
            memcpy(dst + d, escape_seqs[c], elen);
            d += elen;
        } else {
            dst[d++] = (char)c;
        }
    }
    dst[d++] = '"';
    return d;
}

#else
/* Scalar fallback — word-at-a-time */
size_t json_next_unsafe(const char *s, size_t len, size_t start) {
    size_t i = start;
    for (; i < len; i++) {
        uint8_t c = (uint8_t)s[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C)
            return i;
    }
    return len;
}

size_t json_scan_copy_quoted(const char *src, size_t len, char *dst) {
    dst[0] = '"';
    for (size_t i = 0; i < len; i++) {
        uint8_t c = (uint8_t)src[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C) return 0;
        dst[1 + i] = c;
    }
    dst[1 + len] = '"';
    return len + 2;
}

size_t json_write_string(const char *src, size_t len, char *dst) {
    size_t d = 0;
    dst[d++] = '"';
    for (size_t i = 0; i < len; i++) {
        uint8_t c = (uint8_t)src[i];
        if (c < 0x20 || c == 0x22 || c == 0x5C) {
            uint8_t elen = escape_lens[c];
            memcpy(dst + d, escape_seqs[c], elen);
            d += elen;
        } else {
            dst[d++] = (char)c;
        }
    }
    dst[d++] = '"';
    return d;
}
#endif
