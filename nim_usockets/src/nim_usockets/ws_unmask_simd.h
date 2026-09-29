#ifndef NIM_USOCKETS_WS_UNMASK_SIMD_H
#define NIM_USOCKETS_WS_UNMASK_SIMD_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

static inline void ws_unmask_tail(char *p, size_t len, const char mask_key[4]) {
  uint32_t mk;
  memcpy(&mk, mask_key, sizeof(mk));
  uint64_t m64 = (uint64_t)mk | ((uint64_t)mk << 32);
  while (len >= 8) {
    uint64_t v;
    memcpy(&v, p, 8);
    v ^= m64;
    memcpy(p, &v, 8);
    p += 8;
    len -= 8;
  }
  for (size_t i = 0; i < len; ++i) {
    p[i] ^= mask_key[i & 3];
  }
}

#if defined(__AVX2__) && (defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86))

#include <immintrin.h>

__attribute__((target("avx2")))
static inline void ws_unmask(char *payload, size_t len, const char mask_key[4]) {
  uint32_t mk;
  memcpy(&mk, mask_key, sizeof(mk));
  __m128i mask128 = _mm_set1_epi32((int)mk);
  __m256i mask256 = _mm256_set1_epi32((int)mk);
  char *p = payload;
  while (len >= 32) {
    __m256i v = _mm256_loadu_si256((const __m256i *)p);
    v = _mm256_xor_si256(v, mask256);
    _mm256_storeu_si256((__m256i *)p, v);
    p += 32;
    len -= 32;
  }
  while (len >= 16) {
    __m128i v = _mm_loadu_si128((const __m128i *)p);
    v = _mm_xor_si128(v, mask128);
    _mm_storeu_si128((__m128i *)p, v);
    p += 16;
    len -= 16;
  }
  ws_unmask_tail(p, len, mask_key);
}

#elif (defined(__x86_64__) || defined(_M_X64)) || ((defined(__i386__) || defined(_M_IX86)) && (defined(__SSE2__) || (defined(_MSC_VER) && defined(_M_IX86) && (_M_IX86_FP >= 2))))

#include <emmintrin.h>

static inline void ws_unmask(char *payload, size_t len, const char mask_key[4]) {
  uint32_t mk;
  memcpy(&mk, mask_key, sizeof(mk));
  __m128i mask128 = _mm_set1_epi32((int)mk);
  char *p = payload;
  while (len >= 16) {
    __m128i v = _mm_loadu_si128((const __m128i *)p);
    v = _mm_xor_si128(v, mask128);
    _mm_storeu_si128((__m128i *)p, v);
    p += 16;
    len -= 16;
  }
  ws_unmask_tail(p, len, mask_key);
}

#elif defined(__aarch64__) || defined(_M_ARM64)

#include <arm_neon.h>

static inline void ws_unmask(char *payload, size_t len, const char mask_key[4]) {
  uint32_t mk;
  memcpy(&mk, mask_key, sizeof(mk));
  uint32x4_t maskWords = vdupq_n_u32(mk);
  uint8x16_t mask = vreinterpretq_u8_u32(maskWords);
  char *p = payload;
  while (len >= 16) {
    uint8x16_t v = vld1q_u8((const uint8_t *)p);
    v = veorq_u8(v, mask);
    vst1q_u8((uint8_t *)p, v);
    p += 16;
    len -= 16;
  }
  ws_unmask_tail(p, len, mask_key);
}

#else

static inline void ws_unmask(char *payload, size_t len, const char mask_key[4]) {
  ws_unmask_tail(payload, len, mask_key);
}

#endif

#endif
