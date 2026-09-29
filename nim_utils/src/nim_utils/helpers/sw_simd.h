/* Swiss table SIMD helpers — included as header so Nim can inline across TUs */
#ifndef NX_SW_SIMD_H
#define NX_SW_SIMD_H

#include <stdint.h>
#include <string.h>

#define NX_SW_GROUP 16

#ifdef __aarch64__
#include <arm_neon.h>

/* Match h2 in 16 ctrl bytes. Returns nibble-packed mask:
   64 bits, each nibble (4 bits) is 0xF (match) or 0x0 (miss).
   Slot index = __builtin_ctzll(mask) >> 2                       */
static inline uint64_t nx_sw_match16( const uint8_t *ctrl, uint8_t h2 )
{
  uint8x16_t v  = vld1q_u8( ctrl );
  uint8x16_t eq = vceqq_u8( v, vdupq_n_u8( h2 ) );
  uint8x8_t  pk = vshrn_n_u16( vreinterpretq_u16_u8( eq ), 4 );
  return vget_lane_u64( vreinterpret_u64_u8( pk ), 0 );
}

/* Match empty-or-deleted (top bit set) in 16 ctrl bytes. */
static inline uint64_t nx_sw_match_empty_or_del16( const uint8_t *ctrl )
{
  uint8x16_t v   = vld1q_u8( ctrl );
  uint8x16_t msb = vreinterpretq_u8_s8(
    vshrq_n_s8( vreinterpretq_s8_u8( v ), 7 ) );
  uint8x8_t  pk  = vshrn_n_u16( vreinterpretq_u16_u8( msb ), 4 );
  return vget_lane_u64( vreinterpret_u64_u8( pk ), 0 );
}

static inline uint64_t nx_sw_match_empty16( const uint8_t *ctrl )
{
  return nx_sw_match16( ctrl, 0xFF );
}

#elif defined(__x86_64__) || defined(_M_X64)
/* ── SSE2 path ──────────────────────────────────────────────────── */
#include <emmintrin.h>

static inline uint64_t nx_sw_bitmask_to_nibble( unsigned m16 )
{
  uint64_t spread = m16;
  spread = (spread | (spread << 12)) & 0x000F000F000F000FULL;
  spread = (spread | (spread <<  6)) & 0x0303030303030303ULL;
  spread = (spread | (spread <<  3)) & 0x1111111111111111ULL;
  return spread * 0xFULL;
}

static inline uint64_t nx_sw_match16( const uint8_t *ctrl, uint8_t h2 )
{
  __m128i v  = _mm_loadu_si128( (const __m128i*)ctrl );
  __m128i eq = _mm_cmpeq_epi8( v, _mm_set1_epi8( (char)h2 ) );
  unsigned m = (unsigned)_mm_movemask_epi8( eq );
  return nx_sw_bitmask_to_nibble( m );
}

static inline uint64_t nx_sw_match_empty_or_del16( const uint8_t *ctrl )
{
  __m128i v = _mm_loadu_si128( (const __m128i*)ctrl );
  unsigned m = (unsigned)_mm_movemask_epi8( v );
  return nx_sw_bitmask_to_nibble( m );
}

static inline uint64_t nx_sw_match_empty16( const uint8_t *ctrl )
{
  return nx_sw_match16( ctrl, 0xFF );
}

#else
/* ── scalar fallback ─────────────────────────────────────────────── */
static inline uint64_t nx_sw_match16( const uint8_t *ctrl, uint8_t h2 )
{
  uint64_t mask = 0;
  for( int i = 0; i < 16; i++ )
    if( ctrl[i] == h2 )
      mask |= ( 0xFULL << ( i * 4 ) );
  return mask;
}

static inline uint64_t nx_sw_match_empty_or_del16( const uint8_t *ctrl )
{
  uint64_t mask = 0;
  for( int i = 0; i < 16; i++ )
    if( ctrl[i] & 0x80 )
      mask |= ( 0xFULL << ( i * 4 ) );
  return mask;
}

static inline uint64_t nx_sw_match_empty16( const uint8_t *ctrl )
{
  return nx_sw_match16( ctrl, 0xFF );
}
#endif

/* Nibble-mask helpers (platform-independent). */
static inline int nx_sw_ctz_nibble( uint64_t mask )
{
  return __builtin_ctzll( mask ) >> 2;
}

static inline uint64_t nx_sw_clear_lowest_nibble( uint64_t mask )
{
  int bit = __builtin_ctzll( mask ) & ~3;
  return mask & ~( 0xFULL << bit );
}

#endif /* NX_SW_SIMD_H */
