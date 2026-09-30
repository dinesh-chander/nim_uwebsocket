## Fast set helpers for nim_express.
## Backed by Verstable for high-performance string-key sets.

import std/os
import std/bitops
from ./fast_map import hashBytes, syncFastMapCSeed

# Install the shared per-process seed into this module's C translation unit
# (each TU keeps its own copy of the verstable seed variable).
syncFastMapCSeed()

const
  ThisDir = currentSourcePath().splitFile.dir
  VerstableHeader = ThisDir / ".." / "vendor" / "verstable.h"

{.emit: """
#ifndef NIM_EXPRESS_FAST_SET_EMIT
#define NIM_EXPRESS_FAST_SET_EMIT

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static inline size_t vt_wyhash( const void *key, size_t len );

typedef struct nx_fs_arena nx_fs_arena;
static char *nx_fs_arena_memdup( nx_fs_arena *arena, const char *src, size_t len );

typedef struct nx_fs_key
{
  char *ptr;
  size_t len;
} nx_fs_key;

static nx_fs_key nx_fs_key_view( const char *ptr, size_t len )
{
  nx_fs_key view;
  view.ptr = (char *)ptr;
  view.len = len;
  return view;
}

static nx_fs_key nx_fs_key_cstr( const char *ptr )
{
  if( ptr == NULL )
    return nx_fs_key_view( NULL, 0 );

  return nx_fs_key_view( ptr, strlen( ptr ) );
}

static char *nx_fs_memdup_local( const char *src, size_t len )
{
  char *copy = (char *)malloc( len + 1 );
  if( copy == NULL )
    return NULL;

  if( len != 0 && src != NULL )
    memcpy( copy, src, len );

  copy[ len ] = '\\0';
  return copy;
}

typedef struct nx_fs_arena_chunk
{
  struct nx_fs_arena_chunk *next;
  size_t cap;
  size_t used;
  char data[];
} nx_fs_arena_chunk;

struct nx_fs_arena
{
  nx_fs_arena_chunk *head;
  size_t default_cap;
};

static size_t nx_fs_align_up( size_t value )
{
  size_t align = sizeof( void * ) - 1;
  return ( value + align ) & ~align;
}

static void nx_fs_arena_init( nx_fs_arena *arena, size_t default_cap )
{
  arena->head = NULL;
  arena->default_cap = default_cap < 4096 ? 4096 : default_cap;
}

static void nx_fs_arena_reset( nx_fs_arena *arena )
{
  nx_fs_arena_chunk *chunk;
  for( chunk = arena->head; chunk != NULL; chunk = chunk->next )
    chunk->used = 0;
}

static void nx_fs_arena_cleanup( nx_fs_arena *arena )
{
  nx_fs_arena_chunk *chunk = arena->head;
  while( chunk != NULL )
  {
    nx_fs_arena_chunk *next = chunk->next;
    free( chunk );
    chunk = next;
  }
  arena->head = NULL;
  arena->default_cap = 0;
}

static void *nx_fs_arena_alloc( nx_fs_arena *arena, size_t size )
{
  nx_fs_arena_chunk *chunk;
  size_t need;

  if( arena == NULL )
    return NULL;

  need = nx_fs_align_up( size == 0 ? 1 : size );
  chunk = arena->head;
  if( chunk == NULL || chunk->used + need > chunk->cap )
  {
    size_t cap = arena->default_cap;
    if( cap < need )
      cap = need;

    chunk = (nx_fs_arena_chunk *)malloc( offsetof( nx_fs_arena_chunk, data ) + cap );
    if( chunk == NULL )
      return NULL;

    chunk->next = arena->head;
    chunk->cap = cap;
    chunk->used = 0;
    arena->head = chunk;
  }

  void *ptr = chunk->data + chunk->used;
  chunk->used += need;
  return ptr;
}

static char *nx_fs_arena_memdup( nx_fs_arena *arena, const char *src, size_t len )
{
  char *copy = (char *)nx_fs_arena_alloc( arena, len + 1 );
  if( copy == NULL )
    return NULL;

  if( len != 0 && src != NULL )
    memcpy( copy, src, len );

  copy[ len ] = '\\0';
  return copy;
}

static uint64_t nx_fs_hash_key( nx_fs_key key )
{
  return (uint64_t)vt_wyhash( key.ptr, key.len );
}

static bool nx_fs_cmpr_key( nx_fs_key a, nx_fs_key b )
{
  if( a.len != b.len )
    return false;

  if( a.len == 0 )
    return true;

  return memcmp( a.ptr, b.ptr, a.len ) == 0;
}

static void nx_fs_free_key( nx_fs_key key )
{
  if( key.ptr != NULL )
    free( key.ptr );
}

static nx_fs_key nx_fs_key_owned_local( const char *src, size_t len )
{
  nx_fs_key key;
  key.ptr = nx_fs_memdup_local( src, len );
  if( key.ptr == NULL )
    key.len = (size_t)-1;
  else
    key.len = len;
  return key;
}

static nx_fs_key nx_fs_key_owned_arena( nx_fs_arena *arena, const char *src, size_t len )
{
  nx_fs_key key;
  key.ptr = nx_fs_arena_memdup( arena, src, len );
  if( key.ptr == NULL )
    key.len = (size_t)-1;
  else
    key.len = len;
  return key;
}
""".}

{.emit: "#define NAME nx_fs_tbl\n#define KEY_TY nx_fs_key\n#define HASH_FN nx_fs_hash_key\n#define CMPR_FN nx_fs_cmpr_key\n#define KEY_DTOR_FN nx_fs_free_key\n#include \"" & VerstableHeader & "\"\n".}

{.emit: "#define NAME nx_fs_arena_tbl\n#define KEY_TY nx_fs_key\n#define HASH_FN nx_fs_hash_key\n#define CMPR_FN nx_fs_cmpr_key\n#include \"" & VerstableHeader & "\"\n".}

{.emit: """
void *nx_fs_str_set_new(void)
{
  nx_fs_tbl *set = (nx_fs_tbl *)malloc(sizeof(nx_fs_tbl));
  if (set == NULL)
  {
    return NULL;
  }
  nx_fs_tbl_init(set);
  return (void *)set;
}

void nx_fs_str_set_free(void *raw)
{
  if (raw == NULL)
  {
    return;
  }
  nx_fs_tbl *set = (nx_fs_tbl *)raw;
  nx_fs_tbl_cleanup(set);
  free(set);
}

size_t nx_fs_str_set_size(void *raw)
{
  if (raw == NULL)
  {
    return 0;
  }
  return nx_fs_tbl_size((nx_fs_tbl *)raw);
}

N_CDECL(NIM_BOOL, nx_fs_str_set_reserve)(void *raw, size_t n)
{
  if (raw == NULL)
  {
    return false;
  }
  return nx_fs_tbl_reserve((nx_fs_tbl *)raw, n);
}

N_CDECL(NIM_BOOL, nx_fs_str_set_add_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  nx_fs_tbl *set = (nx_fs_tbl *)raw;
  nx_fs_key key_view = nx_fs_key_view(key_ptr, key_len);
  nx_fs_tbl_itr itr = nx_fs_tbl_get(set, key_view);
  if (!nx_fs_tbl_is_end(itr))
  {
    return true;
  }

  nx_fs_key key_copy = nx_fs_key_owned_local(key_ptr, key_len);
  if (key_copy.len == (size_t)-1)
  {
    return false;
  }

  itr = nx_fs_tbl_insert(set, key_copy);
  if (nx_fs_tbl_is_end(itr))
  {
    nx_fs_free_key(key_copy);
    return false;
  }

  return true;
}

N_CDECL(NIM_BOOL, nx_fs_str_set_contains_or_incl_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  nx_fs_tbl *set = (nx_fs_tbl *)raw;
  nx_fs_key key_view = nx_fs_key_view(key_ptr, key_len);
  nx_fs_tbl_itr itr = nx_fs_tbl_get(set, key_view);
  if (!nx_fs_tbl_is_end(itr))
  {
    return true;
  }

  nx_fs_key key_copy = nx_fs_key_owned_local(key_ptr, key_len);
  if (key_copy.len == (size_t)-1)
  {
    return false;
  }

  itr = nx_fs_tbl_insert(set, key_copy);
  if (nx_fs_tbl_is_end(itr))
  {
    nx_fs_free_key(key_copy);
    return false;
  }

  return false;
}

N_CDECL(NIM_BOOL, nx_fs_str_set_add)(void *raw, NCSTRING key)
{
  nx_fs_key key_view = nx_fs_key_cstr(key);
  return nx_fs_str_set_add_n(raw, key_view.ptr, key_view.len);
}

N_CDECL(NIM_BOOL, nx_fs_str_set_contains_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  nx_fs_tbl_itr itr = nx_fs_tbl_get((nx_fs_tbl *)raw, nx_fs_key_view(key_ptr, key_len));
  return !nx_fs_tbl_is_end(itr);
}

N_CDECL(NIM_BOOL, nx_fs_str_set_contains)(void *raw, NCSTRING key)
{
  nx_fs_key key_view = nx_fs_key_cstr(key);
  return nx_fs_str_set_contains_n(raw, key_view.ptr, key_view.len);
}

N_CDECL(NIM_BOOL, nx_fs_str_set_erase_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }
  return nx_fs_tbl_erase((nx_fs_tbl *)raw, nx_fs_key_view(key_ptr, key_len));
}

N_CDECL(NIM_BOOL, nx_fs_str_set_erase)(void *raw, NCSTRING key)
{
  nx_fs_key key_view = nx_fs_key_cstr(key);
  return nx_fs_str_set_erase_n(raw, key_view.ptr, key_view.len);
}

void nx_fs_str_set_clear(void *raw)
{
  if (raw == NULL)
  {
    return;
  }
  nx_fs_tbl_clear((nx_fs_tbl *)raw);
}

typedef struct nx_fs_str_set_iter
{
  nx_fs_tbl_itr itr;
  const nx_fs_tbl *set;
  bool started;
} nx_fs_str_set_iter;

void *nx_fs_str_set_iter_new(void *raw)
{
  if (raw == NULL)
  {
    return NULL;
  }
  nx_fs_str_set_iter *iter = (nx_fs_str_set_iter *)malloc(sizeof(nx_fs_str_set_iter));
  if (iter == NULL)
  {
    return NULL;
  }
  iter->set = (const nx_fs_tbl *)raw;
  iter->started = false;
  return (void *)iter;
}

N_CDECL(NIM_BOOL, nx_fs_str_set_iter_next)(void *iter_raw, char **out_key_ptr, size_t *out_key_len)
{
  if (iter_raw == NULL || out_key_ptr == NULL || out_key_len == NULL)
  {
    return false;
  }

  nx_fs_str_set_iter *iter = (nx_fs_str_set_iter *)iter_raw;
  if (!iter->started)
  {
    iter->itr = nx_fs_tbl_first((nx_fs_tbl *)iter->set);
    iter->started = true;
  }
  else
  {
    iter->itr = nx_fs_tbl_next(iter->itr);
  }

  if (nx_fs_tbl_is_end(iter->itr))
  {
    return false;
  }

  *out_key_ptr = iter->itr.data->key.ptr;
  *out_key_len = iter->itr.data->key.len;
  return true;
}

void nx_fs_str_set_iter_free(void *iter_raw)
{
  if (iter_raw == NULL)
  {
    return;
  }
  free(iter_raw);
}

typedef struct nx_fs_str_arena_set
{
  nx_fs_arena_tbl set;
  nx_fs_arena arena;
} nx_fs_str_arena_set;

typedef struct nx_fs_str_arena_set_iter
{
  nx_fs_arena_tbl_itr itr;
  const nx_fs_arena_tbl *set;
  bool started;
} nx_fs_str_arena_set_iter;

void *nx_fs_str_arena_set_new(size_t default_cap)
{
  nx_fs_str_arena_set *set = (nx_fs_str_arena_set *)malloc(sizeof(nx_fs_str_arena_set));
  if (set == NULL)
  {
    return NULL;
  }
  nx_fs_arena_tbl_init(&set->set);
  nx_fs_arena_init(&set->arena, default_cap);
  return (void *)set;
}

void nx_fs_str_arena_set_free(void *raw)
{
  if (raw == NULL)
  {
    return;
  }
  nx_fs_str_arena_set *set = (nx_fs_str_arena_set *)raw;
  nx_fs_arena_tbl_cleanup(&set->set);
  nx_fs_arena_cleanup(&set->arena);
  free(set);
}

size_t nx_fs_str_arena_set_size(void *raw)
{
  if (raw == NULL)
  {
    return 0;
  }
  return nx_fs_arena_tbl_size(&((nx_fs_str_arena_set *)raw)->set);
}

N_CDECL(NIM_BOOL, nx_fs_str_arena_set_reserve)(void *raw, size_t n)
{
  if (raw == NULL)
  {
    return false;
  }
  return nx_fs_arena_tbl_reserve(&((nx_fs_str_arena_set *)raw)->set, n);
}

N_CDECL(NIM_BOOL, nx_fs_str_arena_set_add_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  nx_fs_str_arena_set *set = (nx_fs_str_arena_set *)raw;
  nx_fs_key key_view = nx_fs_key_view(key_ptr, key_len);
  nx_fs_arena_tbl_itr itr = nx_fs_arena_tbl_get(&set->set, key_view);
  if (!nx_fs_arena_tbl_is_end(itr))
  {
    return true;
  }

  nx_fs_key key_copy = nx_fs_key_owned_arena(&set->arena, key_ptr, key_len);
  if (key_copy.len == (size_t)-1)
  {
    return false;
  }

  itr = nx_fs_arena_tbl_insert(&set->set, key_copy);
  return !nx_fs_arena_tbl_is_end(itr);
}

N_CDECL(NIM_BOOL, nx_fs_str_arena_set_contains_or_incl_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  nx_fs_str_arena_set *set = (nx_fs_str_arena_set *)raw;
  nx_fs_key key_view = nx_fs_key_view(key_ptr, key_len);
  nx_fs_arena_tbl_itr itr = nx_fs_arena_tbl_get(&set->set, key_view);
  if (!nx_fs_arena_tbl_is_end(itr))
  {
    return true;
  }

  nx_fs_key key_copy = nx_fs_key_owned_arena(&set->arena, key_ptr, key_len);
  if (key_copy.len == (size_t)-1)
  {
    return false;
  }

  itr = nx_fs_arena_tbl_insert(&set->set, key_copy);
  if (nx_fs_arena_tbl_is_end(itr))
  {
    return false;
  }

  return false;
}

N_CDECL(NIM_BOOL, nx_fs_str_arena_set_contains_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  nx_fs_arena_tbl_itr itr = nx_fs_arena_tbl_get(&((nx_fs_str_arena_set *)raw)->set, nx_fs_key_view(key_ptr, key_len));
  return !nx_fs_arena_tbl_is_end(itr);
}

N_CDECL(NIM_BOOL, nx_fs_str_arena_set_erase_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }
  return nx_fs_arena_tbl_erase(&((nx_fs_str_arena_set *)raw)->set, nx_fs_key_view(key_ptr, key_len));
}

void nx_fs_str_arena_set_clear(void *raw)
{
  if (raw == NULL)
  {
    return;
  }
  nx_fs_str_arena_set *set = (nx_fs_str_arena_set *)raw;
  nx_fs_arena_tbl_clear(&set->set);
  nx_fs_arena_reset(&set->arena);
}

void *nx_fs_str_arena_set_iter_new(void *raw)
{
  if (raw == NULL)
  {
    return NULL;
  }
  nx_fs_str_arena_set_iter *iter = (nx_fs_str_arena_set_iter *)malloc(sizeof(nx_fs_str_arena_set_iter));
  if (iter == NULL)
  {
    return NULL;
  }
  iter->set = &((nx_fs_str_arena_set *)raw)->set;
  iter->started = false;
  return (void *)iter;
}

N_CDECL(NIM_BOOL, nx_fs_str_arena_set_iter_next)(void *iter_raw, char **out_key_ptr, size_t *out_key_len)
{
  if (iter_raw == NULL || out_key_ptr == NULL || out_key_len == NULL)
  {
    return false;
  }

  nx_fs_str_arena_set_iter *iter = (nx_fs_str_arena_set_iter *)iter_raw;
  if (!iter->started)
  {
    iter->itr = nx_fs_arena_tbl_first((nx_fs_arena_tbl *)iter->set);
    iter->started = true;
  }
  else
  {
    iter->itr = nx_fs_arena_tbl_next(iter->itr);
  }

  if (nx_fs_arena_tbl_is_end(iter->itr))
  {
    return false;
  }

  *out_key_ptr = iter->itr.data->key.ptr;
  *out_key_len = iter->itr.data->key.len;
  return true;
}

void nx_fs_str_arena_set_iter_free(void *iter_raw)
{
  if (iter_raw == NULL)
  {
    return;
  }
  free(iter_raw);
}

#endif
""".}

{.emit: """
/* ── Swiss table SIMD helpers ────────────────────────────────────── */

#define NX_FS_SW_GROUP 16

#ifdef __aarch64__
#include <arm_neon.h>

static inline uint64_t nx_fs_sw_match16( const uint8_t *ctrl, uint8_t h2 )
{
  uint8x16_t v  = vld1q_u8( ctrl );
  uint8x16_t eq = vceqq_u8( v, vdupq_n_u8( h2 ) );
  uint8x8_t  pk = vshrn_n_u16( vreinterpretq_u16_u8( eq ), 4 );
  return vget_lane_u64( vreinterpret_u64_u8( pk ), 0 );
}

static inline uint64_t nx_fs_sw_match_empty_or_del16( const uint8_t *ctrl )
{
  uint8x16_t v   = vld1q_u8( ctrl );
  uint8x16_t msb = vreinterpretq_u8_s8(
    vshrq_n_s8( vreinterpretq_s8_u8( v ), 7 ) );
  uint8x8_t  pk  = vshrn_n_u16( vreinterpretq_u16_u8( msb ), 4 );
  return vget_lane_u64( vreinterpret_u64_u8( pk ), 0 );
}

static inline uint64_t nx_fs_sw_match_empty16( const uint8_t *ctrl )
{
  return nx_fs_sw_match16( ctrl, 0xFF );
}

#else

static inline uint64_t nx_fs_sw_match16( const uint8_t *ctrl, uint8_t h2 )
{
  uint64_t mask = 0;
  for( int i = 0; i < 16; i++ )
    if( ctrl[i] == h2 )
      mask |= ( 0xFULL << ( i * 4 ) );
  return mask;
}

static inline uint64_t nx_fs_sw_match_empty_or_del16( const uint8_t *ctrl )
{
  uint64_t mask = 0;
  for( int i = 0; i < 16; i++ )
    if( ctrl[i] & 0x80 )
      mask |= ( 0xFULL << ( i * 4 ) );
  return mask;
}

static inline uint64_t nx_fs_sw_match_empty16( const uint8_t *ctrl )
{
  return nx_fs_sw_match16( ctrl, 0xFF );
}
#endif

static inline int nx_fs_sw_ctz_nibble( uint64_t mask )
{
  return __builtin_ctzll( mask ) >> 2;
}

static inline uint64_t nx_fs_hash_inline( const char *key, size_t len )
{
  return (uint64_t)vt_wyhash( key, len );
}

static inline void nx_fs_prefetch( const void *p )
{
  __builtin_prefetch( p, 0, 1 );
}
""".}

proc nx_fs_sw_match16(ctrl: ptr uint8, h2: uint8): uint64 {.importc, nodecl.}
proc nx_fs_sw_match_empty_or_del16(ctrl: ptr uint8): uint64 {.importc, nodecl.}
proc nx_fs_sw_match_empty16(ctrl: ptr uint8): uint64 {.importc, nodecl.}
proc nx_fs_sw_ctz_nibble(mask: uint64): cint {.importc, nodecl.}

type
  FastSetStorageKind = enum
    fsskDefault
    fsskNim
    fsskArena

const
  DefaultFastSetArenaChunkSize = 4096
  UseNimStringFastSetBackend = not defined(nxFastSetLegacyStringBackend)
  FastSetCtrlEmpty = 0xFF'u8
  FastSetCtrlDeleted = 0x80'u8
  FastSetMaxInlineStringLen = int(high(uint16))
  FastSetSwGroupSize = 16
  FastSetArenaDefaultChunkSize = 256 * 1024

type
  FastStringView* = object
    data*: pointer
    len*: int

  FastSetStringNimEntry = object
    keyPtr: pointer
    keyLen: uint16

  FastSetBumpArena = object
    chunks: seq[pointer]
    current: pointer
    remaining: int
    chunkSize: int
    usedBytes: int

  FastSetStringNimStorage = ref object
    count: int
    used: int
    capacity: int
    growAt: int
    rebuildAt: int
    ctrl: pointer
    entries: pointer
    arena: FastSetBumpArena
    liveBytes: int

  FastSetStorageObj = object
    raw: pointer
    kind: FastSetStorageKind
    nimString: FastSetStringNimStorage

  FastSet* = ref object
    storage: FastSetStorageObj

  FastHashSet* = FastSet

proc nx_fs_str_set_new(): pointer {.cdecl, importc, used.}
proc nx_fs_str_set_free(raw: pointer) {.cdecl, importc.}
proc nx_fs_str_set_size(raw: pointer): csize_t {.cdecl, importc.}
proc nx_fs_str_set_reserve(raw: pointer, n: csize_t): bool {.cdecl, importc.}
proc nx_fs_str_set_add_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fs_str_set_contains_or_incl_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fs_str_set_contains_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fs_str_set_erase_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fs_str_set_clear(raw: pointer) {.cdecl, importc.}
proc nx_fs_str_set_iter_new(raw: pointer): pointer {.cdecl, importc.}
proc nx_fs_str_set_iter_next(iter: pointer, outKeyPtr: ptr cstring, outKeyLen: ptr csize_t): bool {.cdecl, importc.}
proc nx_fs_str_set_iter_free(iter: pointer) {.cdecl, importc.}
proc nx_fs_str_arena_set_new(defaultCap: csize_t): pointer {.cdecl, importc.}
proc nx_fs_str_arena_set_free(raw: pointer) {.cdecl, importc.}
proc nx_fs_str_arena_set_size(raw: pointer): csize_t {.cdecl, importc.}
proc nx_fs_str_arena_set_reserve(raw: pointer, n: csize_t): bool {.cdecl, importc.}
proc nx_fs_str_arena_set_add_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fs_str_arena_set_contains_or_incl_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fs_str_arena_set_contains_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fs_str_arena_set_erase_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fs_str_arena_set_clear(raw: pointer) {.cdecl, importc.}
proc nx_fs_str_arena_set_iter_new(raw: pointer): pointer {.cdecl, importc.}
proc nx_fs_str_arena_set_iter_next(iter: pointer, outKeyPtr: ptr cstring, outKeyLen: ptr csize_t): bool {.cdecl, importc.}
proc nx_fs_str_arena_set_iter_free(iter: pointer) {.cdecl, importc.}

proc c_strlen(value: cstring): csize_t {.importc: "strlen", header: "<string.h>".}
proc c_malloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc c_memset(p: pointer, val: cint, size: csize_t): pointer {.importc: "memset", header: "<string.h>", discardable.}
proc c_calloc(count: csize_t, size: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>".}

proc stringPtr(value: string): pointer {.inline.} =
  if value.len == 0: nil else: cast[pointer](unsafeAddr value[0])

proc cstringPtr(value: cstring): pointer {.inline.} =
  cast[pointer](value)

proc cstringLen(value: cstring): csize_t {.inline.} =
  if value == nil: 0 else: c_strlen(value)

proc initFastStringView(data: cstring, len: csize_t): FastStringView {.inline.} =
  result.data = cast[pointer](data)
  result.len = int(len)

## Builds a `FastStringView` over the Nim string `value` without copying.
proc toFastStringView*(value: string): FastStringView {.inline.} =
  result.data = value.stringPtr
  result.len = value.len

## Builds a `FastStringView` over the C string `value` without copying.
proc toFastStringView*(value: cstring): FastStringView {.inline.} =
  result.data = value.cstringPtr
  result.len = int(value.cstringLen)

proc isValidFastStringView(value: FastStringView): bool {.inline.} =
  value.len >= 0 and (value.len == 0 or value.data != nil)

proc toFastStringViewPtr(value: FastStringView): pointer {.inline.} = value.data
proc toFastStringViewLen(value: FastStringView): csize_t {.inline.} =
  if value.len <= 0: 0.csize_t else: csize_t(value.len)

proc `$`*(value: FastStringView): string =
  if value.len <= 0 or value.data == nil:
    return ""

  result = newStringUninit(value.len)
  copyMem(addr result[0], value.data, value.len)

const
  FastSetMaxEntryCapacity = high(int) div sizeof(FastSetStringNimEntry)
  FastSetMaxThresholdCapacity = high(int) div 8
  FastSetMaxCtrlCapacity = high(int) - FastSetSwGroupSize
  FastSetMaxCapacity = min(FastSetMaxEntryCapacity,
    min(FastSetMaxThresholdCapacity, FastSetMaxCtrlCapacity))

proc raiseFastSetCapacityOverflow() {.noinline.} =
  raise newException(OverflowDefect, "FastSet capacity exceeds supported maximum")

proc raiseFastSetOutOfMem() {.noinline.} =
  raise newException(OutOfMemDefect, "FastSet allocation failed")

proc nextFastSetPow2(n: int): int {.inline.} =
  if n < 0 or n > FastSetMaxCapacity:
    raiseFastSetCapacityOverflow()
  result = FastSetSwGroupSize
  while result < n:
    if result > (FastSetMaxCapacity shr 1):
      raiseFastSetCapacityOverflow()
    result = result shl 1

proc desiredFastSetStringNimCap(count: int): int {.inline.} =
  if count < 0:
    raiseFastSetCapacityOverflow()
  let extra = count div 3
  if count > high(int) - extra - 1:
    raiseFastSetCapacityOverflow()
  let minSlots = max(FastSetSwGroupSize, count + extra + 1)
  nextFastSetPow2(minSlots)

proc hashFastSetString(key: string): uint64 {.inline.} =
  hashBytes(key.stringPtr, key.len)

proc hashFastSetRaw(kPtr: pointer, kLen: int): uint64 {.inline.} =
  hashBytes(kPtr, kLen)

when defined(nimUtilsHashSeedTest):
  ## Exposes the internal FastSet string hash for test verification.
  proc fastSetHashForTest*(key: string): uint64 {.inline.} =
    hashFastSetString(key)

proc arenaGrow(arena: var FastSetBumpArena, minSize: int) {.inline.} =
  if minSize < 0 or arena.chunkSize < 0:
    raiseFastSetCapacityOverflow()
  let sz = max(arena.chunkSize, minSize)
  let chunk = c_malloc(csize_t(sz))
  if chunk == nil:
    raiseFastSetOutOfMem()
  arena.chunks.add(chunk)
  arena.current = chunk
  arena.remaining = sz

proc arenaAlloc(arena: var FastSetBumpArena, size: int): pointer {.inline.} =
  if size < 0:
    raiseFastSetCapacityOverflow()
  if size > arena.remaining:
    arenaGrow(arena, size)
  result = arena.current
  arena.current = cast[pointer](cast[uint](arena.current) + uint(size))
  arena.remaining -= size
  arena.usedBytes += size

proc arenaFreeAll(arena: var FastSetBumpArena) =
  for chunk in arena.chunks:
    c_free(chunk)
  arena.chunks.setLen(0)
  arena.current = nil
  arena.remaining = 0
  arena.usedBytes = 0

proc arenaReset(arena: var FastSetBumpArena) =
  if arena.chunks.len == 0:
    return
  for i in 1..<arena.chunks.len:
    c_free(arena.chunks[i])
  let firstChunk = arena.chunks[0]
  arena.chunks.setLen(1)
  arena.current = firstChunk
  arena.remaining = arena.chunkSize
  arena.usedBytes = 0

proc arenaStrDup(arena: var FastSetBumpArena, src: pointer, len: int): pointer {.inline.} =
  if len <= 0:
    return nil
  let buf = arenaAlloc(arena, len + 1)
  if src != nil:
    copyMem(buf, src, len)
  cast[ptr UncheckedArray[char]](buf)[len] = '\0'
  buf

proc entryStorageBytes(keyLen: int): int {.inline.} =
  if keyLen < 0 or keyLen > high(int) - 1:
    raiseFastSetCapacityOverflow()
  keyLen + 1

proc rawStrToView(p: pointer, len: int32): FastStringView {.inline.} =
  result.data = p
  result.len = int(len)

proc swH2(hash: uint64): uint8 {.inline.} =
  uint8(hash and 0x7F'u64)

proc swH1(hash: uint64, mask: int): int {.inline.} =
  int((hash shr 7) and uint64(mask))

proc swCtrlPtr(storage: FastSetStringNimStorage, idx: int): ptr uint8 {.inline.} =
  cast[ptr uint8](cast[uint](storage.ctrl) + uint(idx))

proc swCtrlAt(storage: FastSetStringNimStorage, idx: int): uint8 {.inline.} =
  cast[ptr UncheckedArray[uint8]](storage.ctrl)[idx]

proc swSetCtrl(storage: FastSetStringNimStorage, idx: int, val: uint8) {.inline.} =
  cast[ptr UncheckedArray[uint8]](storage.ctrl)[idx] = val
  if idx < FastSetSwGroupSize:
    cast[ptr UncheckedArray[uint8]](storage.ctrl)[storage.capacity + idx] = val

proc swEntryAt(storage: FastSetStringNimStorage, idx: int): ptr FastSetStringNimEntry {.inline.} =
  cast[ptr FastSetStringNimEntry](cast[uint](storage.entries) + uint(idx * sizeof(FastSetStringNimEntry)))

proc swAllocTables(storage: FastSetStringNimStorage, cap: int) =
  if cap <= 0 or cap > FastSetMaxCapacity:
    raiseFastSetCapacityOverflow()
  let ctrlSize = cap + FastSetSwGroupSize
  let ctrl = c_malloc(csize_t(ctrlSize))
  if ctrl == nil:
    raiseFastSetOutOfMem()
  let entries = c_calloc(csize_t(cap), csize_t(sizeof(FastSetStringNimEntry)))
  if entries == nil:
    c_free(ctrl)
    raiseFastSetOutOfMem()
  storage.ctrl = ctrl
  c_memset(storage.ctrl, 0xFF.cint, csize_t(ctrlSize))
  storage.entries = entries
  storage.capacity = cap

proc swFreeTables(storage: FastSetStringNimStorage) =
  if storage.ctrl != nil:
    c_free(storage.ctrl)
    storage.ctrl = nil
  if storage.entries != nil:
    c_free(storage.entries)
    storage.entries = nil
  storage.capacity = 0

proc initFastSetStringNimStorage(): FastSetStringNimStorage =
  new(result)
  result.arena.chunkSize = FastSetArenaDefaultChunkSize

proc updateFastSetStringThresholds(storage: FastSetStringNimStorage) {.inline.} =
  if storage == nil or storage.capacity == 0:
    if storage != nil:
      storage.growAt = 0
      storage.rebuildAt = 0
    return
  if storage.capacity > FastSetMaxCapacity:
    raiseFastSetCapacityOverflow()
  storage.growAt = max(1, (storage.capacity * 3) div 4)
  storage.rebuildAt = max(1, (storage.capacity * 7) div 8)

proc compactFastSetStringArena(storage: FastSetStringNimStorage) =
  if storage == nil or storage.count == 0:
    if storage != nil:
      arenaReset(storage.arena)
      storage.liveBytes = 0
    return

  var nextArena: FastSetBumpArena
  nextArena.chunkSize = storage.arena.chunkSize
  var nextLive = 0
  try:
    let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
    let entries = cast[ptr UncheckedArray[FastSetStringNimEntry]](storage.entries)
    for i in 0..<storage.capacity:
      if ctrl[i] <= 0x7F'u8:
        let entry = addr entries[i]
        let keyLen = int(entry.keyLen)
        entry.keyPtr = arenaStrDup(nextArena, entry.keyPtr, keyLen)
        nextLive += entryStorageBytes(keyLen)
  except:
    arenaFreeAll(nextArena)
    raise

  arenaFreeAll(storage.arena)
  storage.arena = nextArena
  storage.liveBytes = nextLive

proc shouldCompactFastSetStringArena(storage: FastSetStringNimStorage): bool {.inline.} =
  if storage == nil or storage.arena.usedBytes <= storage.arena.chunkSize * 2:
    return false
  storage.liveBytes <= storage.arena.usedBytes div 4

proc maybeCompactFastSetStringArena(storage: FastSetStringNimStorage) {.inline.} =
  if shouldCompactFastSetStringArena(storage):
    compactFastSetStringArena(storage)

proc setEntryKey(entry: var FastSetStringNimEntry, key: string, arena: var FastSetBumpArena) {.inline.} =
  if key.len > FastSetMaxInlineStringLen:
    raise newException(ValueError, "FastSet key exceeds maximum length of 65535")
  entry.keyLen = uint16(key.len)
  entry.keyPtr = arenaStrDup(arena, key.stringPtr, key.len)

proc setEntryKeyRaw(entry: var FastSetStringNimEntry, keyPtr: pointer, keyLen: int, arena: var FastSetBumpArena) {.inline.} =
  if keyLen > FastSetMaxInlineStringLen:
    raise newException(ValueError, "FastSet key exceeds maximum length of 65535")
  entry.keyLen = uint16(keyLen)
  entry.keyPtr = arenaStrDup(arena, keyPtr, keyLen)

proc freeEntryString(entry: var FastSetStringNimEntry) {.inline.} =
  entry.keyPtr = nil
  entry.keyLen = 0'u16

proc zeroEntry(entry: var FastSetStringNimEntry) {.inline.} =
  entry.keyPtr = nil
  entry.keyLen = 0'u16

proc moveEntry(dst: var FastSetStringNimEntry, src: var FastSetStringNimEntry) {.inline.} =
  dst.keyPtr = src.keyPtr
  dst.keyLen = src.keyLen
  src.keyPtr = nil
  src.keyLen = 0'u16

proc findFastSetStringFoundIdx(storage: FastSetStringNimStorage, key: string, hash: uint64): int =
  if storage == nil or storage.capacity == 0:
    return -1
  let mask = storage.capacity - 1
  let kLen = key.len
  if kLen > FastSetMaxInlineStringLen:
    return -1
  let kPtr = if kLen == 0: nil else: cast[pointer](unsafeAddr key[0])
  let h2 = swH2(hash)
  var offset = swH1(hash, mask)
  var stride = 0
  while true:
    let ctrlBase = swCtrlPtr(storage, offset)
    var matchMask = nx_fs_sw_match16(ctrlBase, h2)
    while matchMask != 0:
      let slotOff = int(nx_fs_sw_ctz_nibble(matchMask))
      let idx = (offset + slotOff) and mask
      let entry = swEntryAt(storage, idx)
      if entry.keyLen == uint16(kLen) and
          (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        return idx
      matchMask = matchMask and not (0xF'u64 shl (slotOff * 4))
    if nx_fs_sw_match_empty16(ctrlBase) != 0:
      return -1
    stride += FastSetSwGroupSize
    offset = (offset + stride) and mask

proc findFastSetRawFoundIdx(storage: FastSetStringNimStorage, kPtr: pointer, kLen: int, hash: uint64): int =
  if storage == nil or storage.capacity == 0:
    return -1
  if kLen > FastSetMaxInlineStringLen:
    return -1
  let mask = storage.capacity - 1
  let h2 = swH2(hash)
  var offset = swH1(hash, mask)
  var stride = 0
  while true:
    let ctrlBase = swCtrlPtr(storage, offset)
    var matchMask = nx_fs_sw_match16(ctrlBase, h2)
    while matchMask != 0:
      let slotOff = int(nx_fs_sw_ctz_nibble(matchMask))
      let idx = (offset + slotOff) and mask
      let entry = swEntryAt(storage, idx)
      if entry.keyLen == uint16(kLen) and
          (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        return idx
      matchMask = matchMask and not (0xF'u64 shl (slotOff * 4))
    if nx_fs_sw_match_empty16(ctrlBase) != 0:
      return -1
    stride += FastSetSwGroupSize
    offset = (offset + stride) and mask

proc swFindInsertSlot(storage: FastSetStringNimStorage, hash: uint64): int =
  let mask = storage.capacity - 1
  var offset = swH1(hash, mask)
  var stride = 0
  while true:
    let ctrlBase = swCtrlPtr(storage, offset)
    let freeMask = nx_fs_sw_match_empty_or_del16(ctrlBase)
    if freeMask != 0:
      let slotOff = int(nx_fs_sw_ctz_nibble(freeMask))
      return (offset + slotOff) and mask
    stride += FastSetSwGroupSize
    offset = (offset + stride) and mask

proc rehashFastSetStringNim(storage: FastSetStringNimStorage, newCap: int)
proc ensureFastSetStringCapacity(storage: FastSetStringNimStorage, targetCount: int)
proc clearFastSetString(storage: FastSetStringNimStorage)

proc findOrInsertFastSetString(storage: FastSetStringNimStorage, key: string, hash: uint64, foundExisting: var bool): int {.inline.} =
  if storage == nil:
    foundExisting = false
    return -1

  while true:
    if storage.capacity == 0:
      ensureFastSetStringCapacity(storage, storage.count + 1)

    let idx = findFastSetStringFoundIdx(storage, key, hash)
    if idx >= 0:
      foundExisting = true
      return idx

    if storage.count + 1 > storage.growAt or storage.used > storage.rebuildAt:
      ensureFastSetStringCapacity(storage, storage.count + 1)
      continue

    foundExisting = false
    return swFindInsertSlot(storage, hash)

proc findOrInsertFastSetRaw(storage: FastSetStringNimStorage, keyPtr: pointer, keyLen: int, hash: uint64, foundExisting: var bool): int {.inline.} =
  if storage == nil:
    foundExisting = false
    return -1

  while true:
    if storage.capacity == 0:
      ensureFastSetStringCapacity(storage, storage.count + 1)

    let idx = findFastSetRawFoundIdx(storage, keyPtr, keyLen, hash)
    if idx >= 0:
      foundExisting = true
      return idx

    if storage.count + 1 > storage.growAt or storage.used > storage.rebuildAt:
      ensureFastSetStringCapacity(storage, storage.count + 1)
      continue

    foundExisting = false
    return swFindInsertSlot(storage, hash)

proc ensureFastSetStringCapacity(storage: FastSetStringNimStorage, targetCount: int) =
  if storage.capacity == 0 or targetCount > storage.growAt:
    rehashFastSetStringNim(storage, targetCount)
  elif storage.used > storage.rebuildAt:
    rehashFastSetStringNim(storage, storage.count)

proc rehashFastSetStringNim(storage: FastSetStringNimStorage, newCap: int) =
  let targetCap = desiredFastSetStringNimCap(max(1, newCap))
  let oldCtrl = storage.ctrl
  let oldEntries = storage.entries
  let oldCap = storage.capacity

  swAllocTables(storage, targetCap)
  storage.count = 0
  storage.used = 0
  updateFastSetStringThresholds(storage)

  if oldCap == 0 or oldCtrl == nil:
    return

  let oldCtrlArr = cast[ptr UncheckedArray[uint8]](oldCtrl)
  let oldEntryArr = cast[ptr UncheckedArray[FastSetStringNimEntry]](oldEntries)
  let mask = storage.capacity - 1

  for i in 0..<oldCap:
    if (oldCtrlArr[i] and 0x80'u8) == 0:
      let e = addr oldEntryArr[i]
      let hash = hashFastSetRaw(e.keyPtr, int(e.keyLen))
      let h2 = swH2(hash)
      var offset = swH1(hash, mask)
      var stride = 0
      while true:
        let ctrlBase = swCtrlPtr(storage, offset)
        let emptyMask = nx_fs_sw_match_empty16(ctrlBase)
        if emptyMask != 0:
          let slotOff = int(nx_fs_sw_ctz_nibble(emptyMask))
          let idx = (offset + slotOff) and mask
          moveEntry(swEntryAt(storage, idx)[], oldEntryArr[i])
          swSetCtrl(storage, idx, h2)
          inc storage.count
          inc storage.used
          break
        stride += FastSetSwGroupSize
        offset = (offset + stride) and mask

  c_free(oldCtrl)
  c_free(oldEntries)

proc reserveFastSetString(storage: FastSetStringNimStorage, n: int): bool =
  if storage == nil or n < 0:
    return false
  if n == 0:
    return true
  if storage.capacity < desiredFastSetStringNimCap(n):
    rehashFastSetStringNim(storage, n)
  true

proc lenFastSetString(storage: FastSetStringNimStorage): int {.inline.} =
  if storage == nil: 0 else: storage.count

proc inclFastSetString(storage: FastSetStringNimStorage, key: string): bool {.inline.} =
  if storage == nil:
    return false
  let hash = hashFastSetString(key)
  var foundExisting = false
  let idx = findOrInsertFastSetString(storage, key, hash, foundExisting)
  if idx < 0:
    return false
  if foundExisting:
    return true
  let wasDeleted = swCtrlAt(storage, idx) == FastSetCtrlDeleted
  setEntryKey(swEntryAt(storage, idx)[], key, storage.arena)
  storage.liveBytes += entryStorageBytes(key.len)
  swSetCtrl(storage, idx, swH2(hash))
  inc storage.count
  if not wasDeleted:
    inc storage.used
  true

proc inclFastSetRaw(storage: FastSetStringNimStorage, keyPtr: pointer, keyLen: int): bool {.inline.} =
  if storage == nil:
    return false
  let hash = hashFastSetRaw(keyPtr, keyLen)
  var foundExisting = false
  let idx = findOrInsertFastSetRaw(storage, keyPtr, keyLen, hash, foundExisting)
  if idx < 0:
    return false
  if foundExisting:
    return true
  let wasDeleted = swCtrlAt(storage, idx) == FastSetCtrlDeleted
  setEntryKeyRaw(swEntryAt(storage, idx)[], keyPtr, keyLen, storage.arena)
  storage.liveBytes += entryStorageBytes(keyLen)
  swSetCtrl(storage, idx, swH2(hash))
  inc storage.count
  if not wasDeleted:
    inc storage.used
  true

proc containsFastSetString(storage: FastSetStringNimStorage, key: string): bool {.inline.} =
  if storage == nil or storage.capacity == 0:
    return false
  findFastSetStringFoundIdx(storage, key, hashFastSetString(key)) >= 0

proc containsFastSetRaw(storage: FastSetStringNimStorage, keyPtr: pointer, keyLen: int): bool {.inline.} =
  if storage == nil or storage.capacity == 0:
    return false
  findFastSetRawFoundIdx(storage, keyPtr, keyLen, hashFastSetRaw(keyPtr, keyLen)) >= 0

proc containsOrInclFastSetString(storage: FastSetStringNimStorage, key: string): bool {.inline.} =
  if storage == nil:
    return false
  let hash = hashFastSetString(key)
  var foundExisting = false
  let idx = findOrInsertFastSetString(storage, key, hash, foundExisting)
  if idx < 0:
    return false
  if foundExisting:
    return true
  let wasDeleted = swCtrlAt(storage, idx) == FastSetCtrlDeleted
  setEntryKey(swEntryAt(storage, idx)[], key, storage.arena)
  storage.liveBytes += entryStorageBytes(key.len)
  swSetCtrl(storage, idx, swH2(hash))
  inc storage.count
  if not wasDeleted:
    inc storage.used
  false

proc containsOrInclFastSetRaw(storage: FastSetStringNimStorage, keyPtr: pointer, keyLen: int): bool {.inline.} =
  if storage == nil:
    return false
  let hash = hashFastSetRaw(keyPtr, keyLen)
  var foundExisting = false
  let idx = findOrInsertFastSetRaw(storage, keyPtr, keyLen, hash, foundExisting)
  if idx < 0:
    return false
  if foundExisting:
    return true
  let wasDeleted = swCtrlAt(storage, idx) == FastSetCtrlDeleted
  setEntryKeyRaw(swEntryAt(storage, idx)[], keyPtr, keyLen, storage.arena)
  storage.liveBytes += entryStorageBytes(keyLen)
  swSetCtrl(storage, idx, swH2(hash))
  inc storage.count
  if not wasDeleted:
    inc storage.used
  false

proc exclFastSetString(storage: FastSetStringNimStorage, key: string): bool =
  if storage == nil or storage.capacity == 0:
    return false
  let idx = findFastSetStringFoundIdx(storage, key, hashFastSetString(key))
  if idx < 0:
    return false
  dec storage.count
  storage.liveBytes -= entryStorageBytes(int(swEntryAt(storage, idx).keyLen))
  freeEntryString(swEntryAt(storage, idx)[])
  zeroEntry(swEntryAt(storage, idx)[])
  swSetCtrl(storage, idx, FastSetCtrlDeleted)
  if storage.count == 0:
    clearFastSetString(storage)
  else:
    maybeCompactFastSetStringArena(storage)
  true

proc exclFastSetRaw(storage: FastSetStringNimStorage, keyPtr: pointer, keyLen: int): bool =
  if storage == nil or storage.capacity == 0:
    return false
  let idx = findFastSetRawFoundIdx(storage, keyPtr, keyLen, hashFastSetRaw(keyPtr, keyLen))
  if idx < 0:
    return false
  dec storage.count
  storage.liveBytes -= entryStorageBytes(int(swEntryAt(storage, idx).keyLen))
  freeEntryString(swEntryAt(storage, idx)[])
  zeroEntry(swEntryAt(storage, idx)[])
  swSetCtrl(storage, idx, FastSetCtrlDeleted)
  if storage.count == 0:
    clearFastSetString(storage)
  else:
    maybeCompactFastSetStringArena(storage)
  true

proc clearFastSetString(storage: FastSetStringNimStorage) =
  if storage == nil:
    return
  if storage.capacity > 0 and storage.ctrl != nil:
    c_memset(storage.ctrl, FastSetCtrlEmpty.cint, csize_t(storage.capacity + FastSetSwGroupSize))
    zeroMem(storage.entries, storage.capacity * sizeof(FastSetStringNimEntry))
  storage.count = 0
  storage.used = 0
  storage.liveBytes = 0
  arenaReset(storage.arena)

proc nextFastSetStringOccupiedIdx(storage: FastSetStringNimStorage, idx: var int): bool {.inline.} =
  if storage == nil or storage.capacity == 0:
    return false
  let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
  let cap = storage.capacity
  const allMsb = 0x8080808080808080'u64
  while idx + 8 <= cap:
    var word: uint64
    copyMem(addr word, addr ctrl[idx], 8)
    let occupied = (not word) and allMsb
    if occupied != 0:
      idx = idx + (countTrailingZeroBits(occupied) shr 3)
      return true
    idx += 8
  while idx < cap:
    if (ctrl[idx] and 0x80'u8) == 0:
      return true
    inc idx
  false

proc releaseFastSetStorage(storage: var FastSetStorageObj) =
  if storage.raw == nil and storage.nimString.isNil:
    return
  case storage.kind
  of fsskDefault:
    nx_fs_str_set_free(storage.raw)
  of fsskNim:
    if not storage.nimString.isNil:
      swFreeTables(storage.nimString)
      arenaFreeAll(storage.nimString.arena)
    storage.nimString = nil
  of fsskArena:
    nx_fs_str_arena_set_free(storage.raw)
  storage.raw = nil

proc `=destroy`(storage: var FastSetStorageObj) =
  releaseFastSetStorage(storage)

## Creates an empty `FastSet` with the default storage backend.
proc newFastSet*(): FastSet =
  new(result)
  when UseNimStringFastSetBackend:
    result.storage.kind = fsskNim
    result.storage.nimString = initFastSetStringNimStorage()
  else:
    result.storage.kind = fsskDefault
    result.storage.raw = nx_fs_str_set_new()

## Creates an empty `FastSet` pre-sized for roughly `initialSize` keys.
proc newFastSet*(initialSize: Natural): FastSet =
  result = newFastSet()
  if result == nil:
    return
  case result.storage.kind
  of fsskDefault:
    if result.storage.raw != nil:
      discard nx_fs_str_set_reserve(result.storage.raw, csize_t(initialSize))
  of fsskNim:
    discard reserveFastSetString(result.storage.nimString, int(initialSize))
  of fsskArena:
    discard

## Creates a `FastSet` pre-filled with the keys in `keys`.
proc newFastSet*(keys: openArray[string]): FastSet =
  result = newFastSet()
  if result == nil:
    return
  case result.storage.kind
  of fsskDefault:
    if result.storage.raw != nil:
      discard nx_fs_str_set_reserve(result.storage.raw, csize_t(keys.len))
      for key in keys:
        discard nx_fs_str_set_add_n(result.storage.raw, cast[cstring](key.stringPtr), csize_t(key.len))
  of fsskNim:
    discard reserveFastSetString(result.storage.nimString, keys.len)
    for key in keys:
      discard inclFastSetString(result.storage.nimString, key)
  of fsskArena:
    discard

## Creates an empty `FastHashSet` with the default storage backend.
proc newFastHashSet*(): FastHashSet {.inline.} = newFastSet()
## Creates an empty `FastHashSet` pre-sized for roughly `initialSize` keys.
proc newFastHashSet*(initialSize: Natural): FastHashSet {.inline.} = newFastSet(initialSize)
## Creates a `FastHashSet` pre-filled with the keys in `keys`.
proc newFastHashSet*(keys: openArray[string]): FastHashSet {.inline.} = newFastSet(keys)

## Creates an arena-backed `FastSet` with `arenaChunkSize` chunk size.
proc newFastArenaSet*(arenaChunkSize = DefaultFastSetArenaChunkSize): FastSet =
  new(result)
  result.storage.kind = fsskArena
  result.storage.raw = nx_fs_str_arena_set_new(csize_t(max(64, arenaChunkSize)))

## Creates an arena-backed `FastSet` pre-filled with the keys in `keys`.
proc newFastArenaSet*(keys: openArray[string], arenaChunkSize = DefaultFastSetArenaChunkSize): FastSet =
  result = newFastArenaSet(arenaChunkSize)
  if result != nil and result.storage.raw != nil:
    discard nx_fs_str_arena_set_reserve(result.storage.raw, csize_t(keys.len))
    for key in keys:
      discard nx_fs_str_arena_set_add_n(result.storage.raw, cast[cstring](key.stringPtr), csize_t(key.len))

## Creates an arena-backed `FastHashSet` with `arenaChunkSize` chunk size.
proc newFastArenaHashSet*(arenaChunkSize = DefaultFastSetArenaChunkSize): FastHashSet {.inline.} =
  newFastArenaSet(arenaChunkSize)

## Creates an arena-backed `FastHashSet` pre-filled with the keys in `keys`.
proc newFastArenaHashSet*(keys: openArray[string], arenaChunkSize = DefaultFastSetArenaChunkSize): FastHashSet {.inline.} =
  newFastArenaSet(keys, arenaChunkSize)

## Releases all storage owned by `setObj`.
proc close*(setObj: FastSet) {.inline.} =
  if setObj == nil:
    return
  releaseFastSetStorage(setObj.storage)

## Returns the number of keys stored in `setObj`.
proc len*(setObj: FastSet): int {.inline.} =
  if setObj == nil:
    return 0
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return 0
    int(nx_fs_str_set_size(setObj.storage.raw))
  of fsskNim:
    lenFastSetString(setObj.storage.nimString)
  of fsskArena:
    if setObj.storage.raw == nil:
      return 0
    int(nx_fs_str_arena_set_size(setObj.storage.raw))

## Grows `setObj` to fit at least `n` keys so inserts avoid rehashing.
proc reserve*(setObj: FastSet, n: int): bool {.inline.} =
  if setObj == nil or n < 0:
    return false
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_set_reserve(setObj.storage.raw, csize_t(n))
  of fsskNim:
    reserveFastSetString(setObj.storage.nimString, n)
  of fsskArena:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_arena_set_reserve(setObj.storage.raw, csize_t(n))

## Inserts `key` into `setObj` and returns true when it was newly added.
proc incl*(setObj: FastSet, key: string): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_set_add_n(setObj.storage.raw, cast[cstring](key.stringPtr), csize_t(key.len))
  of fsskNim:
    inclFastSetString(setObj.storage.nimString, key)
  of fsskArena:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_arena_set_add_n(setObj.storage.raw, cast[cstring](key.stringPtr), csize_t(key.len))

## Inserts the C string `key` into `setObj` and returns true when newly added.
proc inclC*(setObj: FastSet, key: cstring): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_set_add_n(setObj.storage.raw, cast[cstring](key.cstringPtr), key.cstringLen)
  of fsskNim:
    inclFastSetRaw(setObj.storage.nimString, key.cstringPtr, int(key.cstringLen))
  of fsskArena:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_arena_set_add_n(setObj.storage.raw, cast[cstring](key.cstringPtr), key.cstringLen)

## Inserts the `FastStringView` `key` into `setObj` and returns true when newly added.
proc inclView*(setObj: FastSet, key: FastStringView): bool {.inline.} =
  if setObj == nil:
    return false
  if not key.isValidFastStringView:
    return false
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_set_add_n(setObj.storage.raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)
  of fsskNim:
    inclFastSetRaw(setObj.storage.nimString, key.toFastStringViewPtr, key.len)
  of fsskArena:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_arena_set_add_n(setObj.storage.raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)

## Returns true when `setObj` already holds `key`.
proc contains*(setObj: FastSet, key: string): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_set_contains_n(setObj.storage.raw, cast[cstring](key.stringPtr), csize_t(key.len))
  of fsskNim:
    containsFastSetString(setObj.storage.nimString, key)
  of fsskArena:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_arena_set_contains_n(setObj.storage.raw, cast[cstring](key.stringPtr), csize_t(key.len))

## Returns true when `setObj` holds the C string `key`.
proc containsC*(setObj: FastSet, key: cstring): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_set_contains_n(setObj.storage.raw, cast[cstring](key.cstringPtr), key.cstringLen)
  of fsskNim:
    containsFastSetRaw(setObj.storage.nimString, key.cstringPtr, int(key.cstringLen))
  of fsskArena:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_arena_set_contains_n(setObj.storage.raw, cast[cstring](key.cstringPtr), key.cstringLen)

## Returns true when `setObj` holds the `FastStringView` `key`.
proc containsView*(setObj: FastSet, key: FastStringView): bool {.inline.} =
  if setObj == nil:
    return false
  if not key.isValidFastStringView:
    return false
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_set_contains_n(setObj.storage.raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)
  of fsskNim:
    containsFastSetRaw(setObj.storage.nimString, key.toFastStringViewPtr, key.len)
  of fsskArena:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_arena_set_contains_n(setObj.storage.raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)

## Removes `key` from `setObj` and returns true when it was present.
proc excl*(setObj: FastSet, key: string): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_set_erase_n(setObj.storage.raw, cast[cstring](key.stringPtr), csize_t(key.len))
  of fsskNim:
    exclFastSetString(setObj.storage.nimString, key)
  of fsskArena:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_arena_set_erase_n(setObj.storage.raw, cast[cstring](key.stringPtr), csize_t(key.len))

## Removes the C string `key` from `setObj` and returns true when it was present.
proc exclC*(setObj: FastSet, key: cstring): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_set_erase_n(setObj.storage.raw, cast[cstring](key.cstringPtr), key.cstringLen)
  of fsskNim:
    exclFastSetRaw(setObj.storage.nimString, key.cstringPtr, int(key.cstringLen))
  of fsskArena:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_arena_set_erase_n(setObj.storage.raw, cast[cstring](key.cstringPtr), key.cstringLen)

## Removes the `FastStringView` `key` from `setObj` and returns true when it was present.
proc exclView*(setObj: FastSet, key: FastStringView): bool {.inline.} =
  if setObj == nil:
    return false
  if not key.isValidFastStringView:
    return false
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_set_erase_n(setObj.storage.raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)
  of fsskNim:
    exclFastSetRaw(setObj.storage.nimString, key.toFastStringViewPtr, key.len)
  of fsskArena:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_arena_set_erase_n(setObj.storage.raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)

## Removes all keys from `setObj`.
proc clear*(setObj: FastSet) {.inline.} =
  if setObj == nil:
    return
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return
    nx_fs_str_set_clear(setObj.storage.raw)
  of fsskNim:
    clearFastSetString(setObj.storage.nimString)
  of fsskArena:
    if setObj.storage.raw == nil:
      return
    nx_fs_str_arena_set_clear(setObj.storage.raw)

## Reversed-argument form of `contains` for fluent call syntax.
proc contains*(key: string, setObj: FastSet): bool {.inline.} =
  setObj.contains(key)

## Returns true when `key` is already in `setObj`, inserting it otherwise.
proc containsOrIncl*(setObj: FastSet, key: string): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_set_contains_or_incl_n(setObj.storage.raw, cast[cstring](key.stringPtr), csize_t(key.len))
  of fsskNim:
    containsOrInclFastSetString(setObj.storage.nimString, key)
  of fsskArena:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_arena_set_contains_or_incl_n(setObj.storage.raw, cast[cstring](key.stringPtr), csize_t(key.len))

## Returns true when the C string `key` is in `setObj`, inserting it otherwise.
proc containsOrInclC*(setObj: FastSet, key: cstring): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_set_contains_or_incl_n(setObj.storage.raw, cast[cstring](key.cstringPtr), key.cstringLen)
  of fsskNim:
    containsOrInclFastSetRaw(setObj.storage.nimString, key.cstringPtr, int(key.cstringLen))
  of fsskArena:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_arena_set_contains_or_incl_n(setObj.storage.raw, cast[cstring](key.cstringPtr), key.cstringLen)

## Returns true when the `FastStringView` `key` is in `setObj`, inserting it otherwise.
proc containsOrInclView*(setObj: FastSet, key: FastStringView): bool {.inline.} =
  if setObj == nil:
    return false
  if not key.isValidFastStringView:
    return false
  case setObj.storage.kind
  of fsskDefault:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_set_contains_or_incl_n(setObj.storage.raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)
  of fsskNim:
    containsOrInclFastSetRaw(setObj.storage.nimString, key.toFastStringViewPtr, key.len)
  of fsskArena:
    if setObj.storage.raw == nil:
      return false
    nx_fs_str_arena_set_contains_or_incl_n(setObj.storage.raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)

## Removes `key` from `setObj` and returns true when it was missing.
proc missingOrExcl*(setObj: FastSet, key: string): bool {.inline.} =
  if setObj == nil:
    return true
  not setObj.excl(key)

## Removes the C string `key` from `setObj` and returns true when it was missing.
proc missingOrExclC*(setObj: FastSet, key: cstring): bool {.inline.} =
  if setObj == nil:
    return true
  not setObj.exclC(key)

## Removes the `FastStringView` `key` from `setObj` and returns true when it was missing.
proc missingOrExclView*(setObj: FastSet, key: FastStringView): bool {.inline.} =
  if setObj == nil:
    return true
  not setObj.exclView(key)

## Iterates the keys of `setObj` as borrowed `FastStringView` values without copying.
iterator itemsView*(setObj: FastSet): FastStringView =
  if setObj != nil:
    case setObj.storage.kind
    of fsskNim:
      var idx = 0
      while nextFastSetStringOccupiedIdx(setObj.storage.nimString, idx):
        let entry = swEntryAt(setObj.storage.nimString, idx)
        yield rawStrToView(entry.keyPtr, int32(entry.keyLen))
        inc idx
    of fsskDefault, fsskArena:
      if setObj.storage.raw != nil:
        let iter =
          case setObj.storage.kind
          of fsskDefault:
            nx_fs_str_set_iter_new(setObj.storage.raw)
          of fsskArena:
            nx_fs_str_arena_set_iter_new(setObj.storage.raw)
          else:
            nil
        if iter != nil:
          defer:
            case setObj.storage.kind
            of fsskDefault:
              nx_fs_str_set_iter_free(iter)
            of fsskArena:
              nx_fs_str_arena_set_iter_free(iter)
            else:
              discard

          var keyPtr: cstring
          var keyLen: csize_t
          while (
            case setObj.storage.kind
            of fsskDefault:
              nx_fs_str_set_iter_next(iter, addr keyPtr, addr keyLen)
            of fsskArena:
              nx_fs_str_arena_set_iter_next(iter, addr keyPtr, addr keyLen)
            else:
              false
          ):
            yield initFastStringView(keyPtr, keyLen)

## Collects all keys of `setObj` into a newly allocated sequence of strings.
proc itemsSeq*(setObj: FastSet): seq[string] =
  result = newSeqOfCap[string](setObj.len)
  for itemView in setObj.itemsView():
    result.add($itemView)

## Iterates the keys of `setObj` as copied Nim strings.
iterator items*(setObj: FastSet): string =
  for itemView in setObj.itemsView():
    yield $itemView

proc `$`*(setObj: FastSet): string =
  if setObj.isNil or setObj.len == 0:
    return "{}"

  result = "{"
  for item in setObj.items():
    if result.len > 1:
      result.add(", ")
    result.addQuoted(item)
  result.add("}")

proc `==`*(a, b: FastSet): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.len != b.len:
    return false
  for itemView in a.itemsView():
    if not b.containsView(itemView):
      return false
  true
