#ifndef NX_FM_HASH_H
#define NX_FM_HASH_H

#include <stdint.h>
#include <string.h>

static inline void nx_wymum( uint64_t *a, uint64_t *b )
{
#if defined( __SIZEOF_INT128__ )
  __uint128_t r = *a;
  r *= *b; 
  *a = (uint64_t)r;
  *b = (uint64_t)( r >> 64 );
#else
  uint64_t ha = *a >> 32;
  uint64_t hb = *b >> 32;
  uint64_t la = (uint32_t)*a;
  uint64_t lb = (uint32_t)*b;
  uint64_t rh = ha * hb;
  uint64_t rm0 = ha * lb;
  uint64_t rm1 = hb * la;
  uint64_t rl = la * lb;
  uint64_t t = rl + ( rm0 << 32 );
  uint64_t c = t < rl;
  uint64_t lo = t + ( rm1 << 32 );
  c += lo < t;
  uint64_t hi = rh + ( rm0 >> 32 ) + ( rm1 >> 32 ) + c;
  *a = lo;
  *b = hi;
#endif
}

static inline uint64_t nx_wymix( uint64_t a, uint64_t b )
{
  nx_wymum( &a, &b );
  return a ^ b;
}

static inline uint64_t nx_wyr8( const unsigned char *p )
{
  uint64_t v;
  memcpy( &v, p, 8 );
  return v;
}

static inline uint64_t nx_wyr4( const unsigned char *p )
{
  uint32_t v;
  memcpy( &v, p, 4 );
  return v;
}

static inline uint64_t nx_wyr3( const unsigned char *p, size_t k )
{
  return ( ( (uint64_t)p[ 0 ] ) << 16 ) | ( ( (uint64_t)p[ k >> 1 ] ) << 8 ) | p[ k - 1 ];
}

#ifndef VT_LIKELY
#ifdef __GNUC__
#define VT_LIKELY( expression )   __builtin_expect( (int)( expression ), 1 )
#define VT_UNLIKELY( expression ) __builtin_expect( (int)( expression ), 0 )
#else
#define VT_LIKELY( expression )   ( expression )
#define VT_UNLIKELY( expression ) ( expression )
#endif
#endif

static inline uint64_t nx_fm_wyhash( const void *key, size_t len )
{
  const unsigned char *p = (const unsigned char *)key;
  uint64_t seed = 0xca813bf4c7abf0a9ull;
  uint64_t a;
  uint64_t b;
  if( VT_LIKELY( len <= 16 ) )
  {
    if( VT_LIKELY( len >= 4 ) )
    {
      a = ( nx_wyr4( p ) << 32 ) | nx_wyr4( p + ( ( len >> 3 ) << 2 ) );
      b = ( nx_wyr4( p + len - 4 ) << 32 ) | nx_wyr4( p + len - 4 - ( ( len >> 3 ) << 2 ) );
    }
    else if( VT_LIKELY( len > 0 ) )
    {
      a = nx_wyr3( p, len );
      b = 0;
    }
    else
    {
      a = 0;
      b = 0;
    }
  }
  else
  {
    size_t i = len; 
    if( VT_UNLIKELY( i >= 48 ) )
    {
      uint64_t see1 = seed;
      uint64_t see2 = seed;
      do{
        seed = nx_wymix( nx_wyr8( p ) ^ 0x8bb84b93962eacc9ull, nx_wyr8( p + 8 ) ^ seed );
        see1 = nx_wymix( nx_wyr8( p + 16 ) ^ 0x4b33a62ed433d4a3ull, nx_wyr8( p + 24 ) ^ see1 );
        see2 = nx_wymix( nx_wyr8( p + 32 ) ^ 0x4d5a2da51de1aa47ull, nx_wyr8( p + 40 ) ^ see2 );
        p += 48;
        i -= 48;
      }
      while( VT_LIKELY( i >= 48 ) );
      seed ^= see1 ^ see2;
    }

    while( VT_UNLIKELY( i > 16 ) )
    {
      seed = nx_wymix( nx_wyr8( p ) ^ 0x8bb84b93962eacc9ull, nx_wyr8( p + 8 ) ^ seed );
      i -= 16;
      p += 16;
    }

    a = nx_wyr8( p + i - 16 );
    b = nx_wyr8( p + i - 8 );
  }

  a ^= 0x8bb84b93962eacc9ull;
  b ^= seed;
  nx_wymum( &a, &b );
  return nx_wymix( a ^ 0x2d358dccaa6c78a5ull ^ len, b ^ 0x8bb84b93962eacc9ull );
}

static inline void nx_prefetch( const void *p )
{
  __builtin_prefetch( p, 0, 1 );
}

#endif
