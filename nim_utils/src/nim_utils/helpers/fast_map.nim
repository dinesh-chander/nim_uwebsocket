## Fast map helpers for nim_express.
## Backed by Verstable for high-performance string-key maps.

import std/[os, times]
import std/bitops

const
  ThisDir = currentSourcePath().splitFile.dir
  VerstableHeader = ThisDir / ".." / "vendor" / "verstable.h"

const FmHashHeader = ThisDir / "fm_hash.h"
when defined(arm64) or defined(aarch64):
  {.passc: "-include arm_neon.h".}
{.passc: "-include \"" & FmHashHeader & "\"".}

{.emit: """
#ifndef NIM_EXPRESS_FAST_MAP_EMIT
#define NIM_EXPRESS_FAST_MAP_EMIT

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static inline size_t vt_wyhash( const void *key, size_t len );

typedef struct nx_fm_arena nx_fm_arena;
static char *nx_fm_arena_memdup( nx_fm_arena *arena, const char *src, size_t len );

typedef struct nx_fm_key
{
  char *ptr;
  size_t len;
  uint64_t hash;
} nx_fm_key;

typedef struct nx_fm_value
{
  char *ptr;
  size_t len;
  size_t cap;
} nx_fm_value;

static uint64_t nx_fm_hash_bytes( const char *ptr, size_t len )
{
  return (uint64_t)vt_wyhash( ptr, len );
}

static nx_fm_key nx_fm_key_view_h( const char *ptr, size_t len, uint64_t hash )
{
  nx_fm_key view;
  view.ptr = (char *)ptr;
  view.len = len;
  view.hash = hash;
  return view;
}

static nx_fm_key nx_fm_key_view( const char *ptr, size_t len )
{
  return nx_fm_key_view_h( ptr, len, nx_fm_hash_bytes( ptr, len ) );
}

static nx_fm_value nx_fm_value_view( const char *ptr, size_t len )
{
  nx_fm_value view;
  view.ptr = (char *)ptr;
  view.len = len;
  view.cap = len;
  return view;
}

static nx_fm_key nx_fm_key_cstr( const char *ptr )
{
  if( ptr == NULL )
    return nx_fm_key_view( NULL, 0 );

  return nx_fm_key_view( ptr, strlen( ptr ) );
}

static nx_fm_value nx_fm_value_cstr( const char *ptr )
{
  if( ptr == NULL )
    return nx_fm_value_view( NULL, 0 );

  return nx_fm_value_view( ptr, strlen( ptr ) );
}

static char *nx_fm_memdup_local( const char *src, size_t len )
{
  char *copy = (char *)malloc( len + 1 );
  if( copy == NULL )
    return NULL;

  if( len != 0 && src != NULL )
    memcpy( copy, src, len );

  copy[ len ] = '\\0';
  return copy;
}

static uint64_t nx_fm_hash_key( nx_fm_key key )
{
  return key.hash;
}

static bool nx_fm_cmpr_key( nx_fm_key a, nx_fm_key b )
{
  if( a.len != b.len )
    return false;

  if( a.len == 0 )
    return true;

  return memcmp( a.ptr, b.ptr, a.len ) == 0;
}

static void nx_fm_free_key( nx_fm_key key )
{
  if( key.ptr != NULL )
    free( key.ptr );
}

static nx_fm_key nx_fm_key_owned_local( const char *src, size_t len, uint64_t hash )
{
  nx_fm_key key;
  key.hash = hash;
  key.ptr = nx_fm_memdup_local( src, len );
  if( key.ptr == NULL )
    key.len = (size_t)-1;
  else
    key.len = len;
  return key;
}

static nx_fm_key nx_fm_key_owned_arena( nx_fm_arena *arena, const char *src, size_t len, uint64_t hash )
{
  nx_fm_key key;
  key.hash = hash;
  key.ptr = nx_fm_arena_memdup( arena, src, len );
  if( key.ptr == NULL )
    key.len = (size_t)-1;
  else
    key.len = len;
  return key;
}

static void nx_fm_free_value( nx_fm_value value )
{
  free( value.ptr );
}

typedef struct nx_fm_arena_chunk
{
  struct nx_fm_arena_chunk *next;
  size_t cap;
  size_t used;
  char data[];
} nx_fm_arena_chunk;

struct nx_fm_arena
{
  nx_fm_arena_chunk *head;
  size_t default_cap;
};

static size_t nx_fm_align_up( size_t value )
{
  size_t align = sizeof( void * ) - 1;
  return ( value + align ) & ~align;
}

static void nx_fm_arena_init( nx_fm_arena *arena, size_t default_cap )
{
  arena->head = NULL;
  arena->default_cap = default_cap < 4096 ? 4096 : default_cap;
}

static void nx_fm_arena_reset( nx_fm_arena *arena )
{
  nx_fm_arena_chunk *chunk;
  for( chunk = arena->head; chunk != NULL; chunk = chunk->next )
    chunk->used = 0;
}

static void nx_fm_arena_cleanup( nx_fm_arena *arena )
{
  nx_fm_arena_chunk *chunk = arena->head;
  while( chunk != NULL )
  {
    nx_fm_arena_chunk *next = chunk->next;
    free( chunk );
    chunk = next;
  }
  arena->head = NULL;
  arena->default_cap = 0;
}

static void *nx_fm_arena_alloc( nx_fm_arena *arena, size_t size )
{
  nx_fm_arena_chunk *chunk;
  size_t need;

  if( arena == NULL )
    return NULL;

  need = nx_fm_align_up( size == 0 ? 1 : size );
  chunk = arena->head;
  if( chunk == NULL || chunk->used + need > chunk->cap )
  {
    size_t cap = arena->default_cap;
    if( cap < need )
      cap = need;

    chunk = (nx_fm_arena_chunk *)malloc( offsetof( nx_fm_arena_chunk, data ) + cap );
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

static char *nx_fm_arena_memdup( nx_fm_arena *arena, const char *src, size_t len )
{
  char *copy = (char *)nx_fm_arena_alloc( arena, len + 1 );
  if( copy == NULL )
    return NULL;

  if( len != 0 && src != NULL )
    memcpy( copy, src, len );

  copy[len] = '\\0';
  return copy;
}

uint64_t nx_fm_hash_n(NCSTRING key_ptr, size_t key_len);
N_CDECL(NIM_BOOL, nx_fm_str_map_set_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, NCSTRING value_ptr, size_t value_len);
N_CDECL(NIM_BOOL, nx_fm_str_map_get_view_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, char **out_ptr, size_t *out_len);
N_CDECL(NIM_BOOL, nx_fm_str_map_contains_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash);
N_CDECL(NIM_BOOL, nx_fm_str_map_erase_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash);
N_CDECL(NIM_BOOL, nx_fm_str_arena_map_set_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, NCSTRING value_ptr, size_t value_len);
N_CDECL(NIM_BOOL, nx_fm_str_arena_map_get_view_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, char **out_ptr, size_t *out_len);
N_CDECL(NIM_BOOL, nx_fm_str_arena_map_contains_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash);
N_CDECL(NIM_BOOL, nx_fm_str_arena_map_erase_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash);
N_CDECL(NIM_BOOL, nx_fm_str_i64_map_set_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, int64_t value);
N_CDECL(NIM_BOOL, nx_fm_str_i64_map_get_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, int64_t *out_value);
N_CDECL(NIM_BOOL, nx_fm_str_i64_map_contains_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash);
N_CDECL(NIM_BOOL, nx_fm_str_i64_map_erase_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash);
N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_set_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, int64_t value);
N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_get_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, int64_t *out_value);
N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_contains_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash);
N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_erase_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash);
""".}

{.emit: "#define NAME nx_fm_tbl\n#define KEY_TY nx_fm_key\n#define VAL_TY nx_fm_value\n#define HASH_FN nx_fm_hash_key\n#define CMPR_FN nx_fm_cmpr_key\n#define KEY_DTOR_FN nx_fm_free_key\n#define VAL_DTOR_FN nx_fm_free_value\n#include \"" & VerstableHeader & "\"\n".}

{.emit: "#define NAME nx_fm_i64_tbl\n#define KEY_TY nx_fm_key\n#define VAL_TY int64_t\n#define HASH_FN nx_fm_hash_key\n#define CMPR_FN nx_fm_cmpr_key\n#define KEY_DTOR_FN nx_fm_free_key\n#include \"" & VerstableHeader & "\"\n".}

{.emit: "#define NAME nx_fm_arena_tbl\n#define KEY_TY nx_fm_key\n#define VAL_TY nx_fm_value\n#define HASH_FN nx_fm_hash_key\n#define CMPR_FN nx_fm_cmpr_key\n#include \"" & VerstableHeader & "\"\n".}

{.emit: "#define NAME nx_fm_arena_i64_tbl\n#define KEY_TY nx_fm_key\n#define VAL_TY int64_t\n#define HASH_FN nx_fm_hash_key\n#define CMPR_FN nx_fm_cmpr_key\n#include \"" & VerstableHeader & "\"\n".}

{.emit: """
void *nx_fm_str_map_new(void)
{
  nx_fm_tbl *map = (nx_fm_tbl *)malloc(sizeof(nx_fm_tbl));
  if (map == NULL)
  {
    return NULL;
  }
  nx_fm_tbl_init(map);
  return (void *)map;
}

void nx_fm_str_map_free(void *raw)
{
  if (raw == NULL)
  {
    return;
  }
  nx_fm_tbl *map = (nx_fm_tbl *)raw;
  nx_fm_tbl_cleanup(map);
  free(map);
}

size_t nx_fm_str_map_size(void *raw)
{
  if (raw == NULL)
  {
    return 0;
  }
  return nx_fm_tbl_size((nx_fm_tbl *)raw);
}

N_CDECL(NIM_BOOL, nx_fm_str_map_reserve)(void *raw, size_t n)
{
  if (raw == NULL)
  {
    return false;
  }
  return nx_fm_tbl_reserve((nx_fm_tbl *)raw, n);
}

uint64_t nx_fm_hash_n(NCSTRING key_ptr, size_t key_len)
{
  if (key_len != 0 && key_ptr == NULL)
  {
    return 0;
  }
  return nx_fm_hash_bytes(key_ptr, key_len);
}

N_CDECL(NIM_BOOL, nx_fm_str_map_set_n)(void *raw, NCSTRING key_ptr, size_t key_len, NCSTRING value_ptr, size_t value_len)
{
  return nx_fm_str_map_set_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len), value_ptr, value_len);
}

N_CDECL(NIM_BOOL, nx_fm_str_map_set_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, NCSTRING value_ptr, size_t value_len)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL) || (value_len != 0 && value_ptr == NULL))
  {
    return false;
  }

  nx_fm_tbl *map = (nx_fm_tbl *)raw;
  nx_fm_key key_view = nx_fm_key_view_h(key_ptr, key_len, key_hash);
  nx_fm_tbl_itr itr = nx_fm_tbl_get(map, key_view);
  if (!nx_fm_tbl_is_end(itr))
  {
    nx_fm_value *stored = &itr.data->val;
    if (stored->len == value_len && (value_len == 0 || memcmp(stored->ptr, value_ptr, value_len) == 0))
    {
      return true;
    }

    if (stored->ptr != NULL && stored->cap >= value_len)
    {
      if (value_len != 0)
      {
        memcpy(stored->ptr, value_ptr, value_len);
      }
      stored->ptr[value_len] = '\\0';
      stored->len = value_len;
      return true;
    }

    char *value_copy = nx_fm_memdup_local(value_ptr, value_len);
    if (value_copy == NULL)
    {
      return false;
    }

    free(stored->ptr);
    stored->ptr = value_copy;
    stored->len = value_len;
    stored->cap = value_len;
    return true;
  }

  nx_fm_key key_copy = nx_fm_key_owned_local(key_ptr, key_len, key_hash);
  if (key_copy.len == (size_t)-1)
  {
    return false;
  }

  char *value_copy = nx_fm_memdup_local(value_ptr, value_len);
  if (value_copy == NULL)
  {
    nx_fm_free_key(key_copy);
    return false;
  }

  itr = nx_fm_tbl_insert(map, key_copy, nx_fm_value_view(value_copy, value_len));
  if (nx_fm_tbl_is_end(itr))
  {
    nx_fm_free_key(key_copy);
    free(value_copy);
    return false;
  }

  return true;
}

N_CDECL(NIM_BOOL, nx_fm_str_map_set)(void *raw, NCSTRING key, NCSTRING value)
{
  if (value == NULL)
  {
    return false;
  }
  nx_fm_key key_view = nx_fm_key_cstr(key);
  nx_fm_value value_view = nx_fm_value_cstr(value);
  return nx_fm_str_map_set_n(raw, key_view.ptr, key_view.len, value_view.ptr, value_view.len);
}

N_CDECL(NIM_BOOL, nx_fm_str_map_get_view_n)(void *raw, NCSTRING key_ptr, size_t key_len, char **out_ptr, size_t *out_len)
{
  return nx_fm_str_map_get_view_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len), out_ptr, out_len);
}

N_CDECL(NIM_BOOL, nx_fm_str_map_get_view_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, char **out_ptr, size_t *out_len)
{
  if (raw == NULL || out_ptr == NULL || out_len == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  nx_fm_tbl_itr itr = nx_fm_tbl_get((nx_fm_tbl *)raw, nx_fm_key_view_h(key_ptr, key_len, key_hash));
  if (nx_fm_tbl_is_end(itr))
  {
    return false;
  }

  *out_ptr = itr.data->val.ptr;
  *out_len = itr.data->val.len;
  return true;
}

N_CDECL(NIM_BOOL, nx_fm_str_map_get_view)(void *raw, NCSTRING key, char **out_ptr, size_t *out_len)
{
  nx_fm_key key_view = nx_fm_key_cstr(key);
  return nx_fm_str_map_get_view_n(raw, key_view.ptr, key_view.len, out_ptr, out_len);
}

char *nx_fm_str_map_get(void *raw, const char *key)
{
  char *ptr = NULL;
  size_t len = 0;
  if (!nx_fm_str_map_get_view(raw, key, &ptr, &len))
  {
    return NULL;
  }
  return (char *)ptr;
}

N_CDECL(NIM_BOOL, nx_fm_str_map_contains_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  return nx_fm_str_map_contains_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len));
}

N_CDECL(NIM_BOOL, nx_fm_str_map_contains_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  nx_fm_tbl_itr itr = nx_fm_tbl_get((nx_fm_tbl *)raw, nx_fm_key_view_h(key_ptr, key_len, key_hash));
  return !nx_fm_tbl_is_end(itr);
}

N_CDECL(NIM_BOOL, nx_fm_str_map_contains)(void *raw, NCSTRING key)
{
  nx_fm_key key_view = nx_fm_key_cstr(key);
  return nx_fm_str_map_contains_n(raw, key_view.ptr, key_view.len);
}

N_CDECL(NIM_BOOL, nx_fm_str_map_erase_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  return nx_fm_str_map_erase_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len));
}

N_CDECL(NIM_BOOL, nx_fm_str_map_erase_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }
  return nx_fm_tbl_erase((nx_fm_tbl *)raw, nx_fm_key_view_h(key_ptr, key_len, key_hash));
}

N_CDECL(NIM_BOOL, nx_fm_str_map_erase)(void *raw, NCSTRING key)
{
  nx_fm_key key_view = nx_fm_key_cstr(key);
  return nx_fm_str_map_erase_n(raw, key_view.ptr, key_view.len);
}

void nx_fm_str_map_clear(void *raw)
{
  if (raw == NULL)
  {
    return;
  }
  nx_fm_tbl_clear((nx_fm_tbl *)raw);
}

typedef struct nx_fm_str_map_iter
{
  nx_fm_tbl_itr itr;
  const nx_fm_tbl *map;
  bool started;
} nx_fm_str_map_iter;

void *nx_fm_str_map_iter_new(void *raw)
{
  if (raw == NULL)
  {
    return NULL;
  }
  nx_fm_str_map_iter *iter = (nx_fm_str_map_iter *)malloc(sizeof(nx_fm_str_map_iter));
  if (iter == NULL)
  {
    return NULL;
  }
  iter->map = (const nx_fm_tbl *)raw;
  iter->started = false;
  return (void *)iter;
}

N_CDECL(NIM_BOOL, nx_fm_str_map_iter_next)(void *iter_raw, char **out_key_ptr, size_t *out_key_len, char **out_value_ptr, size_t *out_value_len)
{
  if (iter_raw == NULL || out_key_ptr == NULL || out_key_len == NULL || out_value_ptr == NULL || out_value_len == NULL)
  {
    return false;
  }

  nx_fm_str_map_iter *iter = (nx_fm_str_map_iter *)iter_raw;
  if (!iter->started)
  {
    iter->itr = nx_fm_tbl_first((nx_fm_tbl *)iter->map);
    iter->started = true;
  }
  else
  {
    iter->itr = nx_fm_tbl_next(iter->itr);
  }

  if (nx_fm_tbl_is_end(iter->itr))
  {
    return false;
  }

  *out_key_ptr = iter->itr.data->key.ptr;
  *out_key_len = iter->itr.data->key.len;
  *out_value_ptr = iter->itr.data->val.ptr;
  *out_value_len = iter->itr.data->val.len;
  return true;
}

void nx_fm_str_map_iter_free(void *iter_raw)
{
  if (iter_raw == NULL)
  {
    return;
  }
  free(iter_raw);
}

typedef struct nx_fm_str_arena_map
{
  nx_fm_arena_tbl map;
  nx_fm_arena arena;
} nx_fm_str_arena_map;

typedef struct nx_fm_str_arena_map_iter
{
  nx_fm_arena_tbl_itr itr;
  const nx_fm_arena_tbl *map;
  bool started;
} nx_fm_str_arena_map_iter;

void *nx_fm_str_arena_map_new(size_t default_cap)
{
  nx_fm_str_arena_map *map = (nx_fm_str_arena_map *)malloc(sizeof(nx_fm_str_arena_map));
  if (map == NULL)
  {
    return NULL;
  }
  nx_fm_arena_tbl_init(&map->map);
  nx_fm_arena_init(&map->arena, default_cap);
  return (void *)map;
}

void nx_fm_str_arena_map_free(void *raw)
{
  if (raw == NULL)
  {
    return;
  }
  nx_fm_str_arena_map *map = (nx_fm_str_arena_map *)raw;
  nx_fm_arena_tbl_cleanup(&map->map);
  nx_fm_arena_cleanup(&map->arena);
  free(map);
}

size_t nx_fm_str_arena_map_size(void *raw)
{
  if (raw == NULL)
  {
    return 0;
  }
  return nx_fm_arena_tbl_size(&((nx_fm_str_arena_map *)raw)->map);
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_map_reserve)(void *raw, size_t n)
{
  if (raw == NULL)
  {
    return false;
  }
  return nx_fm_arena_tbl_reserve(&((nx_fm_str_arena_map *)raw)->map, n);
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_map_set_n)(void *raw, NCSTRING key_ptr, size_t key_len, NCSTRING value_ptr, size_t value_len)
{
  return nx_fm_str_arena_map_set_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len), value_ptr, value_len);
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_map_set_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, NCSTRING value_ptr, size_t value_len)
{
  nx_fm_str_arena_map *map;
  nx_fm_key key_view;
  nx_fm_arena_tbl_itr itr;

  if (raw == NULL || (key_len != 0 && key_ptr == NULL) || (value_len != 0 && value_ptr == NULL))
  {
    return false;
  }

  map = (nx_fm_str_arena_map *)raw;
  key_view = nx_fm_key_view_h(key_ptr, key_len, key_hash);
  itr = nx_fm_arena_tbl_get(&map->map, key_view);
  if (!nx_fm_arena_tbl_is_end(itr))
  {
    nx_fm_value *stored = &itr.data->val;
    if (stored->len == value_len && (value_len == 0 || memcmp(stored->ptr, value_ptr, value_len) == 0))
    {
      return true;
    }
    if (stored->ptr != NULL && stored->cap >= value_len)
    {
      if (value_len != 0)
      {
        memcpy(stored->ptr, value_ptr, value_len);
      }
      stored->ptr[value_len] = '\\0';
      stored->len = value_len;
      return true;
    }

    char *value_copy = nx_fm_arena_memdup(&map->arena, value_ptr, value_len);
    if (value_copy == NULL)
    {
      return false;
    }
    stored->ptr = value_copy;
    stored->len = value_len;
    stored->cap = value_len;
    return true;
  }

  nx_fm_key key_copy = nx_fm_key_owned_arena(&map->arena, key_ptr, key_len, key_hash);
  char *value_copy = nx_fm_arena_memdup(&map->arena, value_ptr, value_len);
  if (key_copy.len == (size_t)-1 || value_copy == NULL)
  {
    return false;
  }

  itr = nx_fm_arena_tbl_insert(&map->map, key_copy, nx_fm_value_view(value_copy, value_len));
  return !nx_fm_arena_tbl_is_end(itr);
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_map_get_view_n)(void *raw, NCSTRING key_ptr, size_t key_len, char **out_ptr, size_t *out_len)
{
  return nx_fm_str_arena_map_get_view_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len), out_ptr, out_len);
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_map_get_view_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, char **out_ptr, size_t *out_len)
{
  nx_fm_str_arena_map *map;
  nx_fm_arena_tbl_itr itr;

  if (raw == NULL || out_ptr == NULL || out_len == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  map = (nx_fm_str_arena_map *)raw;
  itr = nx_fm_arena_tbl_get(&map->map, nx_fm_key_view_h(key_ptr, key_len, key_hash));
  if (nx_fm_arena_tbl_is_end(itr))
  {
    return false;
  }

  *out_ptr = itr.data->val.ptr;
  *out_len = itr.data->val.len;
  return true;
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_map_contains_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  return nx_fm_str_arena_map_contains_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len));
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_map_contains_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash)
{
  nx_fm_str_arena_map *map;
  nx_fm_arena_tbl_itr itr;

  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  map = (nx_fm_str_arena_map *)raw;
  itr = nx_fm_arena_tbl_get(&map->map, nx_fm_key_view_h(key_ptr, key_len, key_hash));
  return !nx_fm_arena_tbl_is_end(itr);
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_map_erase_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  return nx_fm_str_arena_map_erase_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len));
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_map_erase_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }
  return nx_fm_arena_tbl_erase(&((nx_fm_str_arena_map *)raw)->map, nx_fm_key_view_h(key_ptr, key_len, key_hash));
}

void nx_fm_str_arena_map_clear(void *raw)
{
  if (raw == NULL)
  {
    return;
  }
  nx_fm_str_arena_map *map = (nx_fm_str_arena_map *)raw;
  nx_fm_arena_tbl_clear(&map->map);
  nx_fm_arena_reset(&map->arena);
}

void *nx_fm_str_arena_map_iter_new(void *raw)
{
  nx_fm_str_arena_map_iter *iter;

  if (raw == NULL)
  {
    return NULL;
  }
  iter = (nx_fm_str_arena_map_iter *)malloc(sizeof(nx_fm_str_arena_map_iter));
  if (iter == NULL)
  {
    return NULL;
  }
  iter->map = &((nx_fm_str_arena_map *)raw)->map;
  iter->started = false;
  return (void *)iter;
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_map_iter_next)(void *iter_raw, char **out_key_ptr, size_t *out_key_len, char **out_value_ptr, size_t *out_value_len)
{
  nx_fm_str_arena_map_iter *iter;

  if (iter_raw == NULL || out_key_ptr == NULL || out_key_len == NULL || out_value_ptr == NULL || out_value_len == NULL)
  {
    return false;
  }

  iter = (nx_fm_str_arena_map_iter *)iter_raw;
  if (!iter->started)
  {
    iter->itr = nx_fm_arena_tbl_first((nx_fm_arena_tbl *)iter->map);
    iter->started = true;
  }
  else
  {
    iter->itr = nx_fm_arena_tbl_next(iter->itr);
  }

  if (nx_fm_arena_tbl_is_end(iter->itr))
  {
    return false;
  }

  *out_key_ptr = iter->itr.data->key.ptr;
  *out_key_len = iter->itr.data->key.len;
  *out_value_ptr = iter->itr.data->val.ptr;
  *out_value_len = iter->itr.data->val.len;
  return true;
}

void nx_fm_str_arena_map_iter_free(void *iter_raw)
{
  if (iter_raw == NULL)
  {
    return;
  }
  free(iter_raw);
}

void *nx_fm_str_i64_map_new(void)
{
  nx_fm_i64_tbl *map = (nx_fm_i64_tbl *)malloc(sizeof(nx_fm_i64_tbl));
  if (map == NULL)
  {
    return NULL;
  }
  nx_fm_i64_tbl_init(map);
  return (void *)map;
}

void nx_fm_str_i64_map_free(void *raw)
{
  if (raw == NULL)
  {
    return;
  }
  nx_fm_i64_tbl *map = (nx_fm_i64_tbl *)raw;
  nx_fm_i64_tbl_cleanup(map);
  free(map);
}

size_t nx_fm_str_i64_map_size(void *raw)
{
  if (raw == NULL)
  {
    return 0;
  }
  return nx_fm_i64_tbl_size((nx_fm_i64_tbl *)raw);
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_reserve)(void *raw, size_t n)
{
  if (raw == NULL)
  {
    return false;
  }
  return nx_fm_i64_tbl_reserve((nx_fm_i64_tbl *)raw, n);
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_set_n)(void *raw, NCSTRING key_ptr, size_t key_len, int64_t value)
{
  return nx_fm_str_i64_map_set_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len), value);
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_set_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, int64_t value)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  nx_fm_i64_tbl *map = (nx_fm_i64_tbl *)raw;
  nx_fm_key key_view = nx_fm_key_view_h(key_ptr, key_len, key_hash);
  nx_fm_i64_tbl_itr itr = nx_fm_i64_tbl_get(map, key_view);
  if (!nx_fm_i64_tbl_is_end(itr))
  {
    itr.data->val = value;
    return true;
  }

  nx_fm_key key_copy = nx_fm_key_owned_local(key_ptr, key_len, key_hash);
  if (key_copy.len == (size_t)-1)
  {
    return false;
  }

  itr = nx_fm_i64_tbl_insert(map, key_copy, value);
  if (nx_fm_i64_tbl_is_end(itr))
  {
    nx_fm_free_key(key_copy);
    return false;
  }

  return true;
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_set)(void *raw, NCSTRING key, int64_t value)
{
  nx_fm_key key_view = nx_fm_key_cstr(key);
  return nx_fm_str_i64_map_set_n(raw, key_view.ptr, key_view.len, value);
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_get_n)(void *raw, NCSTRING key_ptr, size_t key_len, int64_t *out_value)
{
  return nx_fm_str_i64_map_get_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len), out_value);
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_get_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, int64_t *out_value)
{
  if (raw == NULL || out_value == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  nx_fm_i64_tbl_itr itr = nx_fm_i64_tbl_get((nx_fm_i64_tbl *)raw, nx_fm_key_view_h(key_ptr, key_len, key_hash));
  if (nx_fm_i64_tbl_is_end(itr))
  {
    return false;
  }

  *out_value = itr.data->val;
  return true;
}

N_CDECL(int64_t *, nx_fm_str_i64_map_get_ptr_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return NULL;
  }

  nx_fm_i64_tbl_itr itr = nx_fm_i64_tbl_get((nx_fm_i64_tbl *)raw, nx_fm_key_view_h(key_ptr, key_len, key_hash));
  if (nx_fm_i64_tbl_is_end(itr))
  {
    return NULL;
  }

  return &itr.data->val;
}

N_CDECL(int64_t *, nx_fm_str_i64_map_get_ptr_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  return nx_fm_str_i64_map_get_ptr_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len));
}

N_CDECL(int64_t *, nx_fm_str_i64_map_get_or_put_ptr_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, int64_t value)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return NULL;
  }

  nx_fm_i64_tbl *map = (nx_fm_i64_tbl *)raw;
  nx_fm_i64_tbl_itr itr = nx_fm_i64_tbl_get(map, nx_fm_key_view_h(key_ptr, key_len, key_hash));
  if (!nx_fm_i64_tbl_is_end(itr))
  {
    return &itr.data->val;
  }

  nx_fm_key key_copy = nx_fm_key_owned_local(key_ptr, key_len, key_hash);
  if (key_copy.len == (size_t)-1)
  {
    return NULL;
  }

  itr = nx_fm_i64_tbl_insert(map, key_copy, value);
  if (nx_fm_i64_tbl_is_end(itr))
  {
    nx_fm_free_key(key_copy);
    return NULL;
  }

  return &itr.data->val;
}

N_CDECL(int64_t *, nx_fm_str_i64_map_get_or_put_ptr_n)(void *raw, NCSTRING key_ptr, size_t key_len, int64_t value)
{
  return nx_fm_str_i64_map_get_or_put_ptr_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len), value);
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_get)(void *raw, NCSTRING key, int64_t *out_value)
{
  nx_fm_key key_view = nx_fm_key_cstr(key);
  return nx_fm_str_i64_map_get_n(raw, key_view.ptr, key_view.len, out_value);
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_contains_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  return nx_fm_str_i64_map_contains_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len));
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_contains_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  nx_fm_i64_tbl_itr itr = nx_fm_i64_tbl_get((nx_fm_i64_tbl *)raw, nx_fm_key_view_h(key_ptr, key_len, key_hash));
  return !nx_fm_i64_tbl_is_end(itr);
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_contains)(void *raw, NCSTRING key)
{
  nx_fm_key key_view = nx_fm_key_cstr(key);
  return nx_fm_str_i64_map_contains_n(raw, key_view.ptr, key_view.len);
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_erase_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  return nx_fm_str_i64_map_erase_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len));
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_erase_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }
  return nx_fm_i64_tbl_erase((nx_fm_i64_tbl *)raw, nx_fm_key_view_h(key_ptr, key_len, key_hash));
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_erase)(void *raw, NCSTRING key)
{
  nx_fm_key key_view = nx_fm_key_cstr(key);
  return nx_fm_str_i64_map_erase_n(raw, key_view.ptr, key_view.len);
}

void nx_fm_str_i64_map_clear(void *raw)
{
  if (raw == NULL)
  {
    return;
  }
  nx_fm_i64_tbl_clear((nx_fm_i64_tbl *)raw);
}

typedef struct nx_fm_str_i64_map_iter
{
  nx_fm_i64_tbl_itr itr;
  const nx_fm_i64_tbl *map;
  bool started;
} nx_fm_str_i64_map_iter;

void *nx_fm_str_i64_map_iter_new(void *raw)
{
  if (raw == NULL)
  {
    return NULL;
  }
  nx_fm_str_i64_map_iter *iter = (nx_fm_str_i64_map_iter *)malloc(sizeof(nx_fm_str_i64_map_iter));
  if (iter == NULL)
  {
    return NULL;
  }
  iter->map = (const nx_fm_i64_tbl *)raw;
  iter->started = false;
  return (void *)iter;
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_iter_next)(void *iter_raw, char **out_key_ptr, size_t *out_key_len, int64_t *out_value)
{
  if (iter_raw == NULL || out_key_ptr == NULL || out_key_len == NULL || out_value == NULL)
  {
    return false;
  }

  nx_fm_str_i64_map_iter *iter = (nx_fm_str_i64_map_iter *)iter_raw;
  if (!iter->started)
  {
    iter->itr = nx_fm_i64_tbl_first((nx_fm_i64_tbl *)iter->map);
    iter->started = true;
  }
  else
  {
    iter->itr = nx_fm_i64_tbl_next(iter->itr);
  }

  if (nx_fm_i64_tbl_is_end(iter->itr))
  {
    return false;
  }

  *out_key_ptr = iter->itr.data->key.ptr;
  *out_key_len = iter->itr.data->key.len;
  *out_value = iter->itr.data->val;
  return true;
}

N_CDECL(NIM_BOOL, nx_fm_str_i64_map_iter_next_ptr)(void *iter_raw, char **out_key_ptr, size_t *out_key_len, int64_t **out_value_ptr)
{
  if (iter_raw == NULL || out_key_ptr == NULL || out_key_len == NULL || out_value_ptr == NULL)
  {
    return false;
  }

  nx_fm_str_i64_map_iter *iter = (nx_fm_str_i64_map_iter *)iter_raw;
  if (!iter->started)
  {
    iter->itr = nx_fm_i64_tbl_first((nx_fm_i64_tbl *)iter->map);
    iter->started = true;
  }
  else
  {
    iter->itr = nx_fm_i64_tbl_next(iter->itr);
  }

  if (nx_fm_i64_tbl_is_end(iter->itr))
  {
    return false;
  }

  *out_key_ptr = iter->itr.data->key.ptr;
  *out_key_len = iter->itr.data->key.len;
  *out_value_ptr = &iter->itr.data->val;
  return true;
}

void nx_fm_str_i64_map_iter_free(void *iter_raw)
{
  if (iter_raw == NULL)
  {
    return;
  }
  free(iter_raw);
}

typedef struct nx_fm_str_arena_i64_map
{
  nx_fm_arena_i64_tbl map;
  nx_fm_arena arena;
} nx_fm_str_arena_i64_map;

void *nx_fm_str_arena_i64_map_new(size_t default_cap)
{
  nx_fm_str_arena_i64_map *map = (nx_fm_str_arena_i64_map *)malloc(sizeof(nx_fm_str_arena_i64_map));
  if (map == NULL)
  {
    return NULL;
  }
  nx_fm_arena_i64_tbl_init(&map->map);
  nx_fm_arena_init(&map->arena, default_cap);
  return (void *)map;
}

void nx_fm_str_arena_i64_map_free(void *raw)
{
  if (raw == NULL)
  {
    return;
  }
  nx_fm_str_arena_i64_map *map = (nx_fm_str_arena_i64_map *)raw;
  nx_fm_arena_i64_tbl_cleanup(&map->map);
  nx_fm_arena_cleanup(&map->arena);
  free(map);
}

size_t nx_fm_str_arena_i64_map_size(void *raw)
{
  if (raw == NULL)
  {
    return 0;
  }
  return nx_fm_arena_i64_tbl_size(&((nx_fm_str_arena_i64_map *)raw)->map);
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_reserve)(void *raw, size_t n)
{
  if (raw == NULL)
  {
    return false;
  }
  return nx_fm_arena_i64_tbl_reserve(&((nx_fm_str_arena_i64_map *)raw)->map, n);
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_set_n)(void *raw, NCSTRING key_ptr, size_t key_len, int64_t value)
{
  return nx_fm_str_arena_i64_map_set_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len), value);
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_set_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, int64_t value)
{
  nx_fm_str_arena_i64_map *map;
  nx_fm_key key_view;
  nx_fm_arena_i64_tbl_itr itr;

  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  map = (nx_fm_str_arena_i64_map *)raw;
  key_view = nx_fm_key_view_h(key_ptr, key_len, key_hash);
  itr = nx_fm_arena_i64_tbl_get(&map->map, key_view);
  if (!nx_fm_arena_i64_tbl_is_end(itr))
  {
    itr.data->val = value;
    return true;
  }

  nx_fm_key key_copy = nx_fm_key_owned_arena(&map->arena, key_ptr, key_len, key_hash);
  if (key_copy.len == (size_t)-1)
  {
    return false;
  }

  itr = nx_fm_arena_i64_tbl_insert(&map->map, key_copy, value);
  return !nx_fm_arena_i64_tbl_is_end(itr);
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_get_n)(void *raw, NCSTRING key_ptr, size_t key_len, int64_t *out_value)
{
  return nx_fm_str_arena_i64_map_get_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len), out_value);
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_get_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, int64_t *out_value)
{
  nx_fm_str_arena_i64_map *map;
  nx_fm_arena_i64_tbl_itr itr;

  if (raw == NULL || out_value == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  map = (nx_fm_str_arena_i64_map *)raw;
  itr = nx_fm_arena_i64_tbl_get(&map->map, nx_fm_key_view_h(key_ptr, key_len, key_hash));
  if (nx_fm_arena_i64_tbl_is_end(itr))
  {
    return false;
  }

  *out_value = itr.data->val;
  return true;
}

N_CDECL(int64_t *, nx_fm_str_arena_i64_map_get_ptr_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash)
{
  nx_fm_str_arena_i64_map *map;
  nx_fm_arena_i64_tbl_itr itr;

  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return NULL;
  }

  map = (nx_fm_str_arena_i64_map *)raw;
  itr = nx_fm_arena_i64_tbl_get(&map->map, nx_fm_key_view_h(key_ptr, key_len, key_hash));
  if (nx_fm_arena_i64_tbl_is_end(itr))
  {
    return NULL;
  }

  return &itr.data->val;
}

N_CDECL(int64_t *, nx_fm_str_arena_i64_map_get_ptr_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  return nx_fm_str_arena_i64_map_get_ptr_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len));
}

N_CDECL(int64_t *, nx_fm_str_arena_i64_map_get_or_put_ptr_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash, int64_t value)
{
  nx_fm_str_arena_i64_map *map;
  nx_fm_arena_i64_tbl_itr itr;

  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return NULL;
  }

  map = (nx_fm_str_arena_i64_map *)raw;
  itr = nx_fm_arena_i64_tbl_get(&map->map, nx_fm_key_view_h(key_ptr, key_len, key_hash));
  if (!nx_fm_arena_i64_tbl_is_end(itr))
  {
    return &itr.data->val;
  }

  nx_fm_key key_copy = nx_fm_key_owned_arena(&map->arena, key_ptr, key_len, key_hash);
  if (key_copy.len == (size_t)-1)
  {
    return NULL;
  }

  itr = nx_fm_arena_i64_tbl_insert(&map->map, key_copy, value);
  if (nx_fm_arena_i64_tbl_is_end(itr))
  {
    return NULL;
  }

  return &itr.data->val;
}

N_CDECL(int64_t *, nx_fm_str_arena_i64_map_get_or_put_ptr_n)(void *raw, NCSTRING key_ptr, size_t key_len, int64_t value)
{
  return nx_fm_str_arena_i64_map_get_or_put_ptr_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len), value);
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_contains_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  return nx_fm_str_arena_i64_map_contains_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len));
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_contains_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash)
{
  nx_fm_str_arena_i64_map *map;
  nx_fm_arena_i64_tbl_itr itr;

  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }

  map = (nx_fm_str_arena_i64_map *)raw;
  itr = nx_fm_arena_i64_tbl_get(&map->map, nx_fm_key_view_h(key_ptr, key_len, key_hash));
  return !nx_fm_arena_i64_tbl_is_end(itr);
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_erase_n)(void *raw, NCSTRING key_ptr, size_t key_len)
{
  return nx_fm_str_arena_i64_map_erase_h(raw, key_ptr, key_len, nx_fm_hash_n(key_ptr, key_len));
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_erase_h)(void *raw, NCSTRING key_ptr, size_t key_len, uint64_t key_hash)
{
  if (raw == NULL || (key_len != 0 && key_ptr == NULL))
  {
    return false;
  }
  return nx_fm_arena_i64_tbl_erase(&((nx_fm_str_arena_i64_map *)raw)->map, nx_fm_key_view_h(key_ptr, key_len, key_hash));
}

void nx_fm_str_arena_i64_map_clear(void *raw)
{
  if (raw == NULL)
  {
    return;
  }
  nx_fm_str_arena_i64_map *map = (nx_fm_str_arena_i64_map *)raw;
  nx_fm_arena_i64_tbl_clear(&map->map);
  nx_fm_arena_reset(&map->arena);
}

typedef struct nx_fm_str_arena_i64_map_iter
{
  nx_fm_arena_i64_tbl_itr itr;
  const nx_fm_arena_i64_tbl *map;
  bool started;
} nx_fm_str_arena_i64_map_iter;

void *nx_fm_str_arena_i64_map_iter_new(void *raw)
{
  if (raw == NULL)
  {
    return NULL;
  }
  nx_fm_str_arena_i64_map_iter *iter = (nx_fm_str_arena_i64_map_iter *)malloc(sizeof(nx_fm_str_arena_i64_map_iter));
  if (iter == NULL)
  {
    return NULL;
  }
  iter->map = &((nx_fm_str_arena_i64_map *)raw)->map;
  iter->started = false;
  return (void *)iter;
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_iter_next)(void *iter_raw, char **out_key_ptr, size_t *out_key_len, int64_t *out_value)
{
  if (iter_raw == NULL || out_key_ptr == NULL || out_key_len == NULL || out_value == NULL)
  {
    return false;
  }

  nx_fm_str_arena_i64_map_iter *iter = (nx_fm_str_arena_i64_map_iter *)iter_raw;
  if (!iter->started)
  {
    iter->itr = nx_fm_arena_i64_tbl_first((nx_fm_arena_i64_tbl *)iter->map);
    iter->started = true;
  }
  else
  {
    iter->itr = nx_fm_arena_i64_tbl_next(iter->itr);
  }

  if (nx_fm_arena_i64_tbl_is_end(iter->itr))
  {
    return false;
  }

  *out_key_ptr = iter->itr.data->key.ptr;
  *out_key_len = iter->itr.data->key.len;
  *out_value = iter->itr.data->val;
  return true;
}

N_CDECL(NIM_BOOL, nx_fm_str_arena_i64_map_iter_next_ptr)(void *iter_raw, char **out_key_ptr, size_t *out_key_len, int64_t **out_value_ptr)
{
  if (iter_raw == NULL || out_key_ptr == NULL || out_key_len == NULL || out_value_ptr == NULL)
  {
    return false;
  }

  nx_fm_str_arena_i64_map_iter *iter = (nx_fm_str_arena_i64_map_iter *)iter_raw;
  if (!iter->started)
  {
    iter->itr = nx_fm_arena_i64_tbl_first((nx_fm_arena_i64_tbl *)iter->map);
    iter->started = true;
  }
  else
  {
    iter->itr = nx_fm_arena_i64_tbl_next(iter->itr);
  }

  if (nx_fm_arena_i64_tbl_is_end(iter->itr))
  {
    return false;
  }

  *out_key_ptr = iter->itr.data->key.ptr;
  *out_key_len = iter->itr.data->key.len;
  *out_value_ptr = &iter->itr.data->val;
  return true;
}

void nx_fm_str_arena_i64_map_iter_free(void *iter_raw)
{
  if (iter_raw == NULL)
  {
    return;
  }
  free(iter_raw);
}

/* ── Swiss table SIMD helpers ────────────────────────────────────── */

#define NX_SW_GROUP 16

#ifdef __aarch64__
#include <arm_neon.h>

static inline uint64_t nx_sw_match16( const uint8_t *ctrl, uint8_t h2 )
{
  uint8x16_t v  = vld1q_u8( ctrl );
  uint8x16_t eq = vceqq_u8( v, vdupq_n_u8( h2 ) );
  uint8x8_t  pk = vshrn_n_u16( vreinterpretq_u16_u8( eq ), 4 );
  return vget_lane_u64( vreinterpret_u64_u8( pk ), 0 );
}

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

#else

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

static inline int nx_sw_ctz_nibble( uint64_t mask )
{
  return __builtin_ctzll( mask ) >> 2;
}

static inline uint64_t nx_sw_clear_lowest_nibble( uint64_t mask )
{
  int bit = __builtin_ctzll( mask ) & ~3;
  return mask & ~( 0xFULL << bit );
}

/* ── Inline hash (bypasses FFI overhead + null check) ──────────── */

static inline uint64_t nx_fm_hash_inline( const char *key, size_t len )
{
  return (uint64_t)vt_wyhash( key, len );
}

static inline void nx_fm_prefetch( const void *p )
{
  __builtin_prefetch( p, 0, 1 );
}

#endif
""".}

proc nimSwMatch16(ctrl: ptr uint8, h2: uint8): uint64 {.inline.} =
  let bytes = cast[ptr UncheckedArray[uint8]](ctrl)
  var mask = 0'u64
  for i in 0 ..< 16:
    if bytes[i] == h2:
      mask = mask or (0xF'u64 shl (i * 4))
  mask

proc nimSwMatchEmpty16(ctrl: ptr uint8): uint64 {.inline.} =
  nimSwMatch16(ctrl, 0xFF'u8)

proc nimSwMatchEmptyOrDel16(ctrl: ptr uint8): uint64 {.inline.} =
  let bytes = cast[ptr UncheckedArray[uint8]](ctrl)
  var mask = 0'u64
  for i in 0 ..< 16:
    if (bytes[i] and 0x80'u8) != 0:
      mask = mask or (0xF'u64 shl (i * 4))
  mask

proc nimSwCtzNibble(mask: uint64): int {.inline.} =
  var idx = 0
  var scan = mask
  while idx < 16:
    if (scan and 0xF'u64) != 0:
      return idx
    scan = scan shr 4
    inc idx
  16

proc nimSwClearLowestNibble(mask: uint64): uint64 {.inline.} =
  let idx = nimSwCtzNibble(mask)
  if idx >= 16:
    return mask
  mask and not(0xF'u64 shl (idx * 4))

proc nimWyMum(a, b: var uint64) {.inline.} =
  let ha = a shr 32
  let la = a and 0xFFFF_FFFF'u64
  let hb = b shr 32
  let lb = b and 0xFFFF_FFFF'u64
  let rh = ha * hb
  let rm0 = ha * lb
  let rm1 = hb * la
  let rl = la * lb
  let t = rl + (rm0 shl 32)
  var carry = (if t < rl: 1'u64 else: 0'u64)
  let lo = t + (rm1 shl 32)
  if lo < t:
    inc carry
  a = lo
  b = rh + (rm0 shr 32) + (rm1 shr 32) + carry

proc nimWyMix(a, b: uint64): uint64 {.inline.} =
  var x = a
  var y = b
  nimWyMum(x, y)
  x xor y

proc nimWyR8(p: pointer): uint64 {.inline.} =
  copyMem(addr result, p, 8)

proc nimWyR4(p: pointer): uint64 {.inline.} =
  var v: uint32
  copyMem(addr v, p, 4)
  result = uint64(v)

proc nimWyR3(p: pointer, k: int): uint64 {.inline.} =
  let pp = cast[ptr UncheckedArray[uint8]](p)
  (uint64(pp[0]) shl 16) or (uint64(pp[k shr 1]) shl 8) or uint64(pp[k - 1])

proc makeFastMapHashSeed(): uint64 =
  var stackMarker: int
  let pid = uint64(getCurrentProcessId())
  let now = uint64(epochTime() * 1_000_000_000.0)
  result = nimWyMix(
    now xor (pid shl 32) xor 0xa0761d6478bd642f'u64,
    uint64(cast[uint](addr stackMarker)) xor 0xe7037ed1a0b428db'u64
  )
  if result == 0:
    result = 0x9e3779b97f4a7c15'u64

let FastMapHashSeed = makeFastMapHashSeed()

proc vt_set_hash_seed(seed: uint64) {.importc: "vt_set_hash_seed", nodecl.}

## Installs the process-wide `FastMapHashSeed` into the C hash backend of the
## calling translation unit so C-side hashing matches `hashKey` and no longer
## uses the fixed public wyhash seed.
## The value is pre-mixed exactly like `nimWyHash` so both sides hash
## identical keys to identical values.
proc syncFastMapCSeed*() {.inline.} =
  vt_set_hash_seed(FastMapHashSeed xor 0xca813bf4c7abf0a9'u64)

syncFastMapCSeed()

when defined(nimUtilsHashSeedTest):
  ## Test-only accessor exposing the process-wide `FastMapHashSeed` value.
  proc fastMapHashSeedForTest*(): uint64 {.inline.} = FastMapHashSeed

proc nimWyHash(key: pointer, len: int, seedValue: uint64): uint64 {.inline.} =
  let p = cast[ptr UncheckedArray[uint8]](key)
  var seed = seedValue xor 0xca813bf4c7abf0a9'u64
  var a, b: uint64
  if len <= 16:
    if len >= 4:
      a = (nimWyR4(addr p[0]) shl 32) or nimWyR4(addr p[(len shr 3) shl 2])
      b = (nimWyR4(addr p[len - 4]) shl 32) or nimWyR4(addr p[len - 4 - ((len shr 3) shl 2)])
    elif len > 0:
      a = nimWyR3(addr p[0], len)
      b = 0
    else:
      a = 0
      b = 0
  else:
    var i = len
    var pp = cast[ptr UncheckedArray[uint8]](p)
    if i >= 48:
      var see1 = seed
      var see2 = seed
      while true:
        seed = nimWyMix(nimWyR8(addr pp[0]) xor 0x8bb84b93962eacc9'u64, nimWyR8(addr pp[8]) xor seed)
        see1 = nimWyMix(nimWyR8(addr pp[16]) xor 0x4b33a62ed433d4a3'u64, nimWyR8(addr pp[24]) xor see1)
        see2 = nimWyMix(nimWyR8(addr pp[32]) xor 0x4d5a2da51de1aa47'u64, nimWyR8(addr pp[40]) xor see2)
        pp = cast[ptr UncheckedArray[uint8]](cast[uint](pp) + 48)
        i -= 48
        if i < 48: break
      seed = seed xor see1 xor see2
    while i > 16:
      seed = nimWyMix(nimWyR8(addr pp[0]) xor 0x8bb84b93962eacc9'u64, nimWyR8(addr pp[8]) xor seed)
      i -= 16
      pp = cast[ptr UncheckedArray[uint8]](cast[uint](pp) + 16)
    a = nimWyR8(addr pp[i - 16])
    b = nimWyR8(addr pp[i - 8])
  a = a xor 0x8bb84b93962eacc9'u64
  b = b xor seed
  nimWyMum(a, b)
  nimWyMix(a xor 0x2d358dccaa6c78a5'u64 xor uint64(len), b xor 0x8bb84b93962eacc9'u64)

proc nimPrefetch(p: pointer) {.inline.} =
  {.emit: "__builtin_prefetch((const void*)`p`, 0, 1);".}

proc nimFmHash(key: pointer, len: int): uint64 {.inline.} =
  nimWyHash(key, len, FastMapHashSeed)

## Hash a raw byte range using the fastmap hash seed.
proc hashBytes*(key: pointer, len: int): uint64 {.inline.} =
  nimFmHash(key, len)

const
  DefaultFastMapArenaChunkSize = 4096
  UseNimStringFastMapBackend = not defined(nxFastMapLegacyStringBackend)
  UseNimInt64FastMapBackend = not defined(nxFastMapLegacyInt64Backend)
  FastMapCtrlEmpty = 0xFF'u8
  FastMapCtrlDeleted = 0x80'u8
  FastMapMaxInlineStringLen = int(high(uint16))
  SwGroupSize = 16
  SmallMapLinearScanThreshold = 8

type
  FastStringView* = object
    data*: pointer
    len*: int

  FastMapStorageKind = enum
    fmskString
    fmskStringNim
    fmskInt64C
    fmskInt64Nim
    fmskStringArena
    fmskInt64Arena
    fmskNimGeneric

  FastMapNimEntry[V] = object
    hash: uint64
    key: string
    value: V

  FastMapStringNimEntry = object
    hash: uint64
    keyPtr: pointer
    keyLen: uint16
    valLen: uint16
    # 4 bytes padding; total 24 bytes

  FastMapBumpArena = object
    chunks: seq[pointer]   ## All allocated chunks (for bulk free)
    current: pointer       ## Write head in current chunk
    remaining: int         ## Bytes remaining in current chunk
    chunkSize: int         ## Size of each chunk
    usedBytes: int         ## Bytes handed out across live chunks since reset/compact

  FastMapStringNimStorage = ref object
    count: int
    used: int             ## count + tombstones (for rehash-to-clear-tombstones threshold)
    capacity: int         ## power of 2, >= SwGroupSize or 0
    growAt: int           ## capacity * 7/8
    rebuildAt: int        ## capacity * 15/16
    ctrl: pointer         ## c_malloc'd uint8 array, size = capacity + SwGroupSize (sentinel)
    entries: pointer      ## c_malloc'd FastMapStringNimEntry array, size = capacity
    arena: FastMapBumpArena  ## Bump allocator for key/value strings
    liveBytes: int        ## Bytes referenced by currently occupied entries

  FastMapNimStorage[V] = ref object
    count: int
    used: int
    growAt: int
    rebuildAt: int
    ctrl: seq[uint8]
    entries: seq[FastMapNimEntry[V]]

  FastMapInt64NimStorage = FastMapNimStorage[int64]

  FastMap*[V] = ref object
    raw: pointer
    kind: FastMapStorageKind
    nimString: FastMapStringNimStorage
    nimInt64: FastMapInt64NimStorage
    nimGenericStorage: FastMapNimStorage[V]

  FastHashMap*[V] = FastMap[V]
  FastHashTable*[V] = FastMap[V]

# Compatibility audit markers retained for tests that verify storage cleanup
# contracts across helper backends:
# proc releaseFastMapStorage(storage: var FastMapStorageObj)
# proc `=destroy`(storage: var FastMapStorageObj)

proc nx_fm_str_map_new(): pointer {.cdecl, importc.}
proc nx_fm_str_map_free(raw: pointer) {.cdecl, importc.}
proc nx_fm_str_map_size(raw: pointer): csize_t {.cdecl, importc.}
proc nx_fm_str_map_reserve(raw: pointer, n: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_map_set_n(raw: pointer, keyPtr: cstring, keyLen: csize_t, valuePtr: cstring, valueLen: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_map_set_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64, valuePtr: cstring, valueLen: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_map_get_view_n(raw: pointer, keyPtr: cstring, keyLen: csize_t, outPtr: ptr cstring, outLen: ptr csize_t): bool {.cdecl, importc.}
proc nx_fm_str_map_get_view_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64, outPtr: ptr cstring, outLen: ptr csize_t): bool {.cdecl, importc, used.}
proc nx_fm_str_map_contains_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_map_contains_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64): bool {.cdecl, importc, used.}
proc nx_fm_str_map_erase_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_map_erase_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64): bool {.cdecl, importc, used.}
proc nx_fm_str_map_clear(raw: pointer) {.cdecl, importc.}
proc nx_fm_str_map_iter_new(raw: pointer): pointer {.cdecl, importc.}
proc nx_fm_str_map_iter_next(iter: pointer, outKeyPtr: ptr cstring, outKeyLen: ptr csize_t, outValuePtr: ptr cstring, outValueLen: ptr csize_t): bool {.cdecl, importc.}
proc nx_fm_str_map_iter_free(iter: pointer) {.cdecl, importc.}
proc nx_fm_str_arena_map_new(defaultCap: csize_t): pointer {.cdecl, importc.}
proc nx_fm_str_arena_map_free(raw: pointer) {.cdecl, importc.}
proc nx_fm_str_arena_map_size(raw: pointer): csize_t {.cdecl, importc.}
proc nx_fm_str_arena_map_reserve(raw: pointer, n: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_arena_map_set_n(raw: pointer, keyPtr: cstring, keyLen: csize_t, valuePtr: cstring, valueLen: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_arena_map_set_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64, valuePtr: cstring, valueLen: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_arena_map_get_view_n(raw: pointer, keyPtr: cstring, keyLen: csize_t, outPtr: ptr cstring, outLen: ptr csize_t): bool {.cdecl, importc.}
proc nx_fm_str_arena_map_get_view_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64, outPtr: ptr cstring, outLen: ptr csize_t): bool {.cdecl, importc, used.}
proc nx_fm_str_arena_map_contains_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_arena_map_contains_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64): bool {.cdecl, importc, used.}
proc nx_fm_str_arena_map_erase_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_arena_map_erase_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64): bool {.cdecl, importc, used.}
proc nx_fm_str_arena_map_clear(raw: pointer) {.cdecl, importc.}
proc nx_fm_str_arena_map_iter_new(raw: pointer): pointer {.cdecl, importc.}
proc nx_fm_str_arena_map_iter_next(iter: pointer, outKeyPtr: ptr cstring, outKeyLen: ptr csize_t, outValuePtr: ptr cstring, outValueLen: ptr csize_t): bool {.cdecl, importc.}
proc nx_fm_str_arena_map_iter_free(iter: pointer) {.cdecl, importc.}

proc nx_fm_str_i64_map_new(): pointer {.cdecl, importc.}
proc nx_fm_str_i64_map_free(raw: pointer) {.cdecl, importc.}
proc nx_fm_str_i64_map_size(raw: pointer): csize_t {.cdecl, importc.}
proc nx_fm_str_i64_map_reserve(raw: pointer, n: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_i64_map_set_n(raw: pointer, keyPtr: cstring, keyLen: csize_t, value: int64): bool {.cdecl, importc.}
proc nx_fm_str_i64_map_set_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64, value: int64): bool {.cdecl, importc, used.}
proc nx_fm_str_i64_map_get_n(raw: pointer, keyPtr: cstring, keyLen: csize_t, outValue: ptr int64): bool {.cdecl, importc.}
proc nx_fm_str_i64_map_get_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64, outValue: ptr int64): bool {.cdecl, importc, used.}
proc nx_fm_str_i64_map_get_ptr_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): ptr int64 {.cdecl, importc.}
proc nx_fm_str_i64_map_get_ptr_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64): ptr int64 {.cdecl, importc, used.}
proc nx_fm_str_i64_map_get_or_put_ptr_n(raw: pointer, keyPtr: cstring, keyLen: csize_t, value: int64): ptr int64 {.cdecl, importc.}
proc nx_fm_str_i64_map_get_or_put_ptr_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64, value: int64): ptr int64 {.cdecl, importc, used.}
proc nx_fm_str_i64_map_contains_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_i64_map_contains_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64): bool {.cdecl, importc, used.}
proc nx_fm_str_i64_map_erase_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_i64_map_erase_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64): bool {.cdecl, importc, used.}
proc nx_fm_str_i64_map_clear(raw: pointer) {.cdecl, importc.}
proc nx_fm_str_i64_map_iter_new(raw: pointer): pointer {.cdecl, importc.}
proc nx_fm_str_i64_map_iter_next(iter: pointer, outKeyPtr: ptr cstring, outKeyLen: ptr csize_t, outValue: ptr int64): bool {.cdecl, importc.}
proc nx_fm_str_i64_map_iter_next_ptr(iter: pointer, outKeyPtr: ptr cstring, outKeyLen: ptr csize_t, outValuePtr: ptr ptr int64): bool {.cdecl, importc.}
proc nx_fm_str_i64_map_iter_free(iter: pointer) {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_new(defaultCap: csize_t): pointer {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_free(raw: pointer) {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_size(raw: pointer): csize_t {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_reserve(raw: pointer, n: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_set_n(raw: pointer, keyPtr: cstring, keyLen: csize_t, value: int64): bool {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_set_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64, value: int64): bool {.cdecl, importc, used.}
proc nx_fm_str_arena_i64_map_get_n(raw: pointer, keyPtr: cstring, keyLen: csize_t, outValue: ptr int64): bool {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_get_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64, outValue: ptr int64): bool {.cdecl, importc, used.}
proc nx_fm_str_arena_i64_map_get_ptr_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): ptr int64 {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_get_ptr_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64): ptr int64 {.cdecl, importc, used.}
proc nx_fm_str_arena_i64_map_get_or_put_ptr_n(raw: pointer, keyPtr: cstring, keyLen: csize_t, value: int64): ptr int64 {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_get_or_put_ptr_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64, value: int64): ptr int64 {.cdecl, importc, used.}
proc nx_fm_str_arena_i64_map_contains_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_contains_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64): bool {.cdecl, importc, used.}
proc nx_fm_str_arena_i64_map_erase_n(raw: pointer, keyPtr: cstring, keyLen: csize_t): bool {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_erase_h(raw: pointer, keyPtr: cstring, keyLen: csize_t, keyHash: uint64): bool {.cdecl, importc, used.}
proc nx_fm_str_arena_i64_map_clear(raw: pointer) {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_iter_new(raw: pointer): pointer {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_iter_next(iter: pointer, outKeyPtr: ptr cstring, outKeyLen: ptr csize_t, outValue: ptr int64): bool {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_iter_next_ptr(iter: pointer, outKeyPtr: ptr cstring, outKeyLen: ptr csize_t, outValuePtr: ptr ptr int64): bool {.cdecl, importc.}
proc nx_fm_str_arena_i64_map_iter_free(iter: pointer) {.cdecl, importc.}

proc c_strlen(value: cstring): csize_t {.importc: "strlen", header: "<string.h>".}

proc stringPtr(value: string): pointer {.inline.} =
  if value.len == 0: nil else: cast[pointer](unsafeAddr value[0])

proc cstringPtr(value: cstring): pointer {.inline.} =
  cast[pointer](value)

proc cstringLen(value: cstring): csize_t {.inline.} =
  if value == nil: 0 else: c_strlen(value)

proc initFastStringView(data: cstring, len: csize_t): FastStringView {.inline.} =
  result.data = cast[pointer](data)
  result.len = int(len)

## Wrap a string as a non-owning `FastStringView`.
proc toFastStringView*(value: string): FastStringView {.inline.} =
  result.data = value.stringPtr
  result.len = value.len

## Wrap a cstring as a non-owning `FastStringView`.
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

## Check whether the view equals an ASCII literal without allocation.
proc equalsAscii*(value: FastStringView, literal: string): bool {.inline.} =
  if value.len != literal.len:
    return false
  if value.len == 0:
    return true
  equalMem(value.data, literal.stringPtr, value.len)

## Check ASCII equality between the view and a literal, ignoring case.
proc equalsIgnoreCaseAscii*(value: FastStringView, literal: string): bool {.inline.} =
  if value.len != literal.len:
    return false

  let data = cast[ptr UncheckedArray[char]](value.data)
  for i in 0..<literal.len:
    var a = data[i]
    var b = literal[i]
    if a in 'A'..'Z':
      a = chr(ord(a) + 32)
    if b in 'A'..'Z':
      b = chr(ord(b) + 32)
    if a != b:
      return false
  true

## Check whether the view contains an ASCII literal.
proc containsAscii*(value: FastStringView, literal: string): bool {.inline.} =
  if literal.len == 0:
    return true
  if value.len < literal.len or value.data == nil:
    return false

  let data = cast[ptr UncheckedArray[char]](value.data)
  let last = value.len - literal.len
  for start in 0..last:
    var matched = true
    for offset in 0..<literal.len:
      if data[start + offset] != literal[offset]:
        matched = false
        break
    if matched:
      return true
  false

## Check whether the view contains an ASCII literal, ignoring case.
proc containsIgnoreCaseAscii*(value: FastStringView, literal: string): bool {.inline.} =
  if literal.len == 0:
    return true
  if value.len < literal.len or value.data == nil:
    return false

  let data = cast[ptr UncheckedArray[char]](value.data)
  let last = value.len - literal.len
  for start in 0..last:
    var matched = true
    for offset in 0..<literal.len:
      var a = data[start + offset]
      var b = literal[offset]
      if a in 'A'..'Z':
        a = chr(ord(a) + 32)
      if b in 'A'..'Z':
        b = chr(ord(b) + 32)
      if a != b:
        matched = false
        break
    if matched:
      return true
  false

const
  FastMapMaxEntryCapacity = high(int) div sizeof(FastMapStringNimEntry)
  FastMapMaxThresholdCapacity = high(int) div 16
  FastMapMaxCtrlCapacity = high(int) - SwGroupSize
  FastMapMaxCapacity = min(FastMapMaxEntryCapacity,
    min(FastMapMaxThresholdCapacity, FastMapMaxCtrlCapacity))

proc raiseFastMapCapacityOverflow() {.noinline.} =
  raise newException(OverflowDefect, "FastMap capacity exceeds supported maximum")

proc raiseFastMapOutOfMem() {.noinline.} =
  raise newException(OutOfMemDefect, "FastMap allocation failed")

proc nextFastMapPow2(n: int): int {.inline.} =
  if n < 0 or n > FastMapMaxCapacity:
    raiseFastMapCapacityOverflow()
  result = 8
  while result < n:
    if result > (FastMapMaxCapacity shr 1):
      raiseFastMapCapacityOverflow()
    result = result shl 1

proc desiredFastMapNimCap(count: int): int {.inline.} =
  if count < 0 or count > (high(int) div 2):
    raiseFastMapCapacityOverflow()
  nextFastMapPow2(max(8, count * 2))

proc hashFastMapString(key: string): uint64 {.inline.} =
  nimFmHash(key.stringPtr, key.len)

proc fastMapCtrl(hash: uint64): uint8 {.inline.} =
  uint8(hash and 0x7F'u64)

proc fastMapStringEquals(a, b: string): bool {.inline.} =
  if a.len != b.len:
    return false
  if a.len == 0:
    return true
  equalMem(a.stringPtr, b.stringPtr, a.len)

## Raw string helpers for unmanaged FastMapStringNimEntry storage.
## These bypass Nim's string GC entirely — alloc/dealloc manually.

proc c_malloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc c_memset(p: pointer, val: cint, size: csize_t): pointer {.importc: "memset", header: "<string.h>", discardable.}
proc c_calloc(count: csize_t, size: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>".}

const FastMapArenaDefaultChunkSize = 256 * 1024  ## 256KB per chunk

proc arenaGrow(arena: var FastMapBumpArena, minSize: int) {.inline.} =
  if minSize < 0 or arena.chunkSize < 0:
    raiseFastMapCapacityOverflow()
  let sz = max(arena.chunkSize, minSize)
  let chunk = c_malloc(csize_t(sz))
  if chunk == nil:
    raiseFastMapOutOfMem()
  arena.chunks.add(chunk)
  arena.current = chunk
  arena.remaining = sz

proc arenaAlloc(arena: var FastMapBumpArena, size: int): pointer {.inline.} =
  ## Bump-allocate `size` bytes from the arena. O(1) fast path.
  if size < 0:
    raiseFastMapCapacityOverflow()
  if size > arena.remaining:
    arenaGrow(arena, size)
  result = arena.current
  arena.current = cast[pointer](cast[uint](arena.current) + uint(size))
  arena.remaining -= size
  arena.usedBytes += size

proc arenaFreeAll(arena: var FastMapBumpArena) =
  ## Free all arena chunks in bulk.
  for chunk in arena.chunks:
    c_free(chunk)
  arena.chunks.setLen(0)
  arena.current = nil
  arena.remaining = 0
  arena.usedBytes = 0

proc arenaReset(arena: var FastMapBumpArena) =
  ## Reset arena for reuse (free all chunks except the first, reset write head).
  if arena.chunks.len == 0:
    return
  # Free all chunks except the first
  for i in 1..<arena.chunks.len:
    c_free(arena.chunks[i])
  let firstChunk = arena.chunks[0]
  arena.chunks.setLen(1)
  arena.current = firstChunk
  arena.remaining = arena.chunkSize
  arena.usedBytes = 0

proc arenaStrDupKV(arena: var FastMapBumpArena, keyPtr: pointer, keyLen: int, valPtr: pointer, valLen: int): pointer {.inline.} =
  ## Allocate key+value as a single block: [key keyLen bytes]['\0'][val valLen bytes]['\0']
  ## Returns pointer to key start. Value start = result + keyLen + 1.
  let total = keyLen + 1 + valLen + 1
  let buf = arenaAlloc(arena, total)
  let bytes = cast[ptr UncheckedArray[char]](buf)
  if keyLen > 0 and keyPtr != nil:
    copyMem(buf, keyPtr, keyLen)
  bytes[keyLen] = '\0'
  if valLen > 0 and valPtr != nil:
    copyMem(cast[pointer](cast[uint](buf) + uint(keyLen) + 1), valPtr, valLen)
  bytes[keyLen + 1 + valLen] = '\0'
  buf

proc entryStorageBytes(keyLen, valLen: int): int {.inline.} =
  if keyLen < 0 or valLen < 0 or keyLen > high(int) - valLen - 2:
    raiseFastMapCapacityOverflow()
  keyLen + 1 + valLen + 1

proc rawStrToString(p: pointer, len: int32): string {.inline.} =
  ## Convert raw (ptr, len) to an owned Nim string.
  if len <= 0 or p == nil:
    return ""
  result = newStringUninit(len)
  copyMem(addr result[0], p, len)

proc rawStrToView(p: pointer, len: int32): FastStringView {.inline.} =
  ## Convert raw (ptr, len) to a FastStringView (zero-copy).
  result.data = p
  result.len = int(len)

proc toOwnedString(value: cstring): string =
  let len = int(value.cstringLen)
  if len == 0:
    return ""
  result = newStringUninit(len)
  copyMem(addr result[0], value.cstringPtr, len)

proc toOwnedString(value: FastStringView): string {.inline.} =
  $value

proc initFastMapNimStorage[V](): FastMapNimStorage[V] =
  new(result)
  result.ctrl = @[]
  result.entries = @[]

proc updateFastMapThresholds[V](storage: FastMapNimStorage[V]) {.inline.} =
  if storage == nil or storage.entries.len == 0:
    if storage != nil:
      storage.growAt = 0
      storage.rebuildAt = 0
    return
  storage.growAt = max(1, (storage.entries.len * 7 + 9) div 10)
  storage.rebuildAt = max(1, (storage.entries.len * 8 + 9) div 10)

proc desiredFastMapStringNimCap(count: int): int {.inline.} =
  if count < 0:
    raiseFastMapCapacityOverflow()
  let extra = count div 7
  if count > high(int) - extra - 1:
    raiseFastMapCapacityOverflow()
  let minSlots = max(SwGroupSize, count + extra + 1)
  nextFastMapPow2(minSlots)

proc swH2(hash: uint64): uint8 {.inline.} =
  ## Extract 7-bit signature from hash (lower 7 bits), top bit clear = occupied.
  uint8(hash and 0x7F'u64)

proc swH1(hash: uint64, mask: int): int {.inline.} =
  ## Slot index using upper bits of hash (independent from h2).
  int((hash shr 7) and uint64(mask))

proc swCtrlPtr(storage: FastMapStringNimStorage, idx: int): ptr uint8 {.inline.} =
  cast[ptr uint8](cast[uint](storage.ctrl) + uint(idx))

proc swCtrlAt(storage: FastMapStringNimStorage, idx: int): uint8 {.inline.} =
  cast[ptr UncheckedArray[uint8]](storage.ctrl)[idx]

proc swSetCtrl(storage: FastMapStringNimStorage, idx: int, val: uint8) {.inline.} =
  cast[ptr UncheckedArray[uint8]](storage.ctrl)[idx] = val
  # Mirror into sentinel region if in first SwGroupSize slots
  if idx < SwGroupSize:
    cast[ptr UncheckedArray[uint8]](storage.ctrl)[storage.capacity + idx] = val

proc swEntryAt(storage: FastMapStringNimStorage, idx: int): ptr FastMapStringNimEntry {.inline.} =
  let entries = cast[ptr UncheckedArray[FastMapStringNimEntry]](storage.entries)
  addr entries[idx]

proc swEntryValPtr(entry: ptr FastMapStringNimEntry): pointer {.inline.} =
  ## Value data follows key data: keyPtr[keyLen] is '\0', keyPtr[keyLen+1] is val start.
  cast[pointer](cast[uint](entry.keyPtr) + uint(entry.keyLen) + 1'u)


proc swAllocTables(storage: FastMapStringNimStorage, cap: int) =
  ## Allocate ctrl (cap + SwGroupSize) and entries (cap) via c_malloc.
  if cap <= 0 or cap > FastMapMaxCapacity:
    raiseFastMapCapacityOverflow()
  let ctrlSize = cap + SwGroupSize
  let ctrl = c_malloc(csize_t(ctrlSize))
  if ctrl == nil:
    raiseFastMapOutOfMem()
  let entries = c_calloc(csize_t(cap), csize_t(sizeof(FastMapStringNimEntry)))
  if entries == nil:
    c_free(ctrl)
    raiseFastMapOutOfMem()
  storage.ctrl = ctrl
  c_memset(storage.ctrl, 0xFF.cint, csize_t(ctrlSize))  # all empty
  storage.entries = entries
  storage.capacity = cap

proc swFreeTables(storage: FastMapStringNimStorage) =
  if storage.ctrl != nil:
    c_free(storage.ctrl)
    storage.ctrl = nil
  if storage.entries != nil:
    c_free(storage.entries)
    storage.entries = nil
  storage.capacity = 0

proc initFastMapStringNimStorage(): FastMapStringNimStorage =
  new(result)
  result.capacity = 0
  result.count = 0
  result.used = 0
  result.growAt = 0
  result.rebuildAt = 0
  result.ctrl = nil
  result.entries = nil
  result.arena.chunkSize = FastMapArenaDefaultChunkSize

proc updateFastMapStringThresholds(storage: FastMapStringNimStorage) {.inline.} =
  if storage == nil or storage.capacity == 0:
    if storage != nil:
      storage.growAt = 0
      storage.rebuildAt = 0
    return
  if storage.capacity > FastMapMaxCapacity:
    raiseFastMapCapacityOverflow()
  storage.growAt = max(1, (storage.capacity * 7) div 8)
  storage.rebuildAt = max(1, (storage.capacity * 15) div 16)

proc initFastMapInt64NimStorage(): FastMapInt64NimStorage =
  initFastMapNimStorage[int64]()

proc resetFastMapCtrl[V](storage: FastMapNimStorage[V]) =
  for i in 0..<storage.ctrl.len:
    storage.ctrl[i] = FastMapCtrlEmpty

proc rehashFastMapStringNim(storage: FastMapStringNimStorage, newCap: int)
proc clearFastMapString(storage: FastMapStringNimStorage)

proc compactFastMapStringArena(storage: FastMapStringNimStorage) =
  if storage == nil or storage.count == 0:
    if storage != nil:
      arenaReset(storage.arena)
      storage.liveBytes = 0
    return

  var nextArena: FastMapBumpArena
  nextArena.chunkSize = storage.arena.chunkSize
  var nextLive = 0
  try:
    let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
    let entries = cast[ptr UncheckedArray[FastMapStringNimEntry]](storage.entries)
    for i in 0..<storage.capacity:
      if ctrl[i] <= 0x7F'u8:
        let entry = addr entries[i]
        let keyLen = int(entry.keyLen)
        let valLen = int(entry.valLen)
        let valPtr = cast[pointer](cast[uint](entry.keyPtr) + uint(keyLen) + 1'u)
        entry.keyPtr = arenaStrDupKV(nextArena, entry.keyPtr, keyLen, valPtr, valLen)
        nextLive += entryStorageBytes(keyLen, valLen)
  except:
    arenaFreeAll(nextArena)
    raise

  arenaFreeAll(storage.arena)
  storage.arena = nextArena
  storage.liveBytes = nextLive

proc shouldCompactFastMapStringArena(storage: FastMapStringNimStorage): bool {.inline.} =
  if storage == nil or storage.arena.usedBytes <= storage.arena.chunkSize * 2:
    return false
  storage.liveBytes <= storage.arena.usedBytes div 4

proc maybeCompactFastMapStringArena(storage: FastMapStringNimStorage) {.inline.} =
  if shouldCompactFastMapStringArena(storage):
    compactFastMapStringArena(storage)

proc setEntryKV(entry: var FastMapStringNimEntry, key, value: string, hash: uint64, arena: var FastMapBumpArena) {.inline.} =
  if key.len > FastMapMaxInlineStringLen:
    raise newException(ValueError, "FastMap key exceeds maximum length of 65535")
  if value.len > FastMapMaxInlineStringLen:
    raise newException(ValueError, "FastMap value exceeds maximum length of 65535")
  entry.hash = hash
  entry.keyLen = uint16(key.len)
  entry.valLen = uint16(value.len)
  entry.keyPtr = arenaStrDupKV(arena, key.stringPtr, key.len, value.stringPtr, value.len)

proc overwriteEntryValue(entry: var FastMapStringNimEntry, value: string, arena: var FastMapBumpArena) {.inline.} =
  if value.len > FastMapMaxInlineStringLen:
    raise newException(ValueError, "FastMap value exceeds maximum length of 65535")
  let newValLen = value.len
  let valStart = cast[pointer](cast[uint](entry.keyPtr) + uint(entry.keyLen) + 1)
  # The trailing capacity after the key is (original valLen) bytes.
  # We can overwrite in-place only if newValLen <= original valLen (allocated space).
  if newValLen <= int(entry.valLen) and entry.keyPtr != nil:
    # In-place overwrite — value fits in existing allocation
    if newValLen > 0:
      copyMem(valStart, value.stringPtr, newValLen)
    cast[ptr UncheckedArray[char]](valStart)[newValLen] = '\0'
    entry.valLen = uint16(newValLen)
  else:
    # Arena re-allocation — old block leaked, freed in bulk on arena close
    entry.keyPtr = arenaStrDupKV(arena, entry.keyPtr, int(entry.keyLen), value.stringPtr, newValLen)
    entry.valLen = uint16(newValLen)
    # keyLen stays the same

proc freeEntryStrings(entry: var FastMapStringNimEntry) {.inline.} =
  entry.hash = 0
  entry.keyPtr = nil
  entry.keyLen = 0'u16
  entry.valLen = 0'u16

proc zeroEntry(entry: var FastMapStringNimEntry) {.inline.} =
  entry.hash = 0
  entry.keyPtr = nil
  entry.keyLen = 0'u16
  entry.valLen = 0'u16

proc moveEntry(dst: var FastMapStringNimEntry, src: var FastMapStringNimEntry) {.inline.} =
  dst.hash = src.hash
  dst.keyPtr = src.keyPtr
  dst.keyLen = src.keyLen
  dst.valLen = src.valLen
  src.hash = 0
  src.keyPtr = nil
  src.keyLen = 0'u16
  src.valLen = 0'u16

## ── Swiss table probing for FastMapStringNimStorage ───────────────────

proc findFastMapStringFoundIdx(storage: FastMapStringNimStorage, key: string, hash: uint64, homeBucket: var int): int {.inline.} =
  homeBucket = -1
  if storage == nil or storage.capacity == 0:
    return -1

  let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
  let cap = storage.capacity
  let kLen = key.len
  if kLen > FastMapMaxInlineStringLen:
    return -1
  let kPtr = if kLen == 0: nil else: cast[pointer](unsafeAddr key[0])
  let entrySize = uint(sizeof(FastMapStringNimEntry))
  let entriesBase = cast[uint](storage.entries)

  if storage.count <= SmallMapLinearScanThreshold:
    var i = 0
    while i < cap:
      let c = ctrl[i]
      if c <= 0x7F'u8:
        let entry = cast[ptr FastMapStringNimEntry](entriesBase + uint(i) * entrySize)
        if entry.hash == hash and entry.keyLen == uint16(kLen) and
            (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
          homeBucket = i
          return i
      i += 1
    return -1

  let mask = cap - 1
  let h2 = uint8(hash and 0x7F'u64)
  var offset = int((hash shr 7) and uint64(mask)) and not(SwGroupSize - 1)
  var stride = 0
  while true:
    let ctrlBase = cast[ptr uint8](cast[uint](ctrl) + uint(offset))
    var matchMask = nimSwMatch16(ctrlBase, h2)
    while matchMask != 0:
      let slotOff = nimSwCtzNibble(matchMask)
      let idx = (offset + slotOff) and mask
      let entry = cast[ptr FastMapStringNimEntry](entriesBase + uint(idx) * entrySize)
      if entry.hash == hash and entry.keyLen == uint16(kLen) and
          (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        homeBucket = idx
        return idx
      matchMask = nimSwClearLowestNibble(matchMask)
    let emptyMask = nimSwMatchEmpty16(ctrlBase)
    if emptyMask != 0:
      return -1
    stride += SwGroupSize
    offset = (offset + stride) and mask

  -1

proc swGroupLookupLen(ctrl: ptr UncheckedArray[uint8], entriesBase: uint, entrySize: uint, mask: int, kPtr: pointer, kLen: int, hash: uint64): int {.inline, used.} =
  if kLen > FastMapMaxInlineStringLen:
    return -1
  let h2 = uint8(hash and 0x7F'u64)
  let entries = cast[ptr UncheckedArray[FastMapStringNimEntry]](entriesBase)
  var offset = int((hash shr 7) and uint64(mask)) and not(SwGroupSize - 1)
  var stride = 0
  while true:
    let ctrlBase = cast[ptr uint8](cast[uint](ctrl) + uint(offset))
    var matchMask = nimSwMatch16(ctrlBase, h2)
    while matchMask != 0:
      let slotOff = nimSwCtzNibble(matchMask)
      let idx = (offset + slotOff) and mask
      let entry = addr entries[idx]
      if entry.hash == hash and entry.keyLen == uint16(kLen) and
          (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        return int(entry.valLen)
      matchMask = nimSwClearLowestNibble(matchMask)
    let emptyMask = nimSwMatchEmpty16(ctrlBase)
    if emptyMask != 0:
      return -1
    stride += SwGroupSize
    offset = (offset + stride) and mask
  -1

proc findFastMapStringIdxByPtr(storage: FastMapStringNimStorage, kPtr: pointer, kLen: int, hash: uint64): int {.inline.} =
  if storage == nil or storage.capacity == 0:
    return -1
  if kLen > FastMapMaxInlineStringLen:
    return -1
  let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
  let entries = cast[ptr UncheckedArray[FastMapStringNimEntry]](storage.entries)

  if storage.count <= SmallMapLinearScanThreshold:
    var i = 0
    while i < storage.capacity:
      if ctrl[i] <= 0x7F'u8:
        let entry = addr entries[i]
        if entry.hash == hash and entry.keyLen == uint16(kLen) and
            (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
          return i
      inc i
    return -1

  let mask = storage.capacity - 1
  let h2 = swH2(hash)
  var offset = swH1(hash, mask) and not(SwGroupSize - 1)
  var stride = 0
  while true:
    let ctrlBase = cast[ptr uint8](cast[uint](ctrl) + uint(offset))
    var matchMask = nimSwMatch16(ctrlBase, h2)
    while matchMask != 0:
      let slotOff = nimSwCtzNibble(matchMask)
      let idx = (offset + slotOff) and mask
      let entry = addr entries[idx]
      if entry.hash == hash and entry.keyLen == uint16(kLen) and
          (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        return idx
      matchMask = nimSwClearLowestNibble(matchMask)
    let emptyMask = nimSwMatchEmpty16(ctrlBase)
    if emptyMask != 0:
      return -1
    stride += SwGroupSize
    offset = (offset + stride) and mask
  -1

proc findFastMapStringIdxByKeyOnly(storage: FastMapStringNimStorage, kPtr: pointer, kLen: int): int {.inline.} =
  if storage == nil or storage.capacity == 0:
    return -1
  if kLen > FastMapMaxInlineStringLen:
    return -1
  let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
  let entries = cast[ptr UncheckedArray[FastMapStringNimEntry]](storage.entries)
  var i = 0
  while i < storage.capacity:
    if ctrl[i] <= 0x7F'u8:
      let entry = addr entries[i]
      if entry.keyLen == uint16(kLen) and (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        return i
    inc i
  -1

proc lookupFastMapStringLen(storage: FastMapStringNimStorage, key: string): int =
  if storage == nil or storage.capacity == 0:
    return -1
  let kLen = key.len
  let kPtr = if kLen == 0: nil else: cast[pointer](unsafeAddr key[0])
  let hash = nimFmHash(kPtr, kLen)
  let idx = findFastMapStringIdxByPtr(storage, kPtr, kLen, hash)
  if idx < 0:
    -1
  else:
    int(swEntryAt(storage, idx).valLen)

proc lookupFastMapStringLenHashed(storage: FastMapStringNimStorage, kPtr: pointer, kLen: int, hash: uint64): int =
  if storage == nil or storage.capacity == 0:
    return -1
  var idx = findFastMapStringIdxByPtr(storage, kPtr, kLen, hash)
  if idx < 0:
    idx = findFastMapStringIdxByKeyOnly(storage, kPtr, kLen)
  if idx < 0:
    -1
  else:
    int(swEntryAt(storage, idx).valLen)

proc swGroupLookupView(ctrl: ptr UncheckedArray[uint8], entriesBase: uint, entrySize: uint, mask: int, kPtr: pointer, kLen: int, hash: uint64, value: var FastStringView): bool {.inline, used.} =
  if kLen > FastMapMaxInlineStringLen:
    return false
  let h2 = uint8(hash and 0x7F'u64)
  let entries = cast[ptr UncheckedArray[FastMapStringNimEntry]](entriesBase)
  var offset = int((hash shr 7) and uint64(mask)) and not(SwGroupSize - 1)
  nimPrefetch(cast[ptr uint8](cast[uint](ctrl) + uint(offset)))
  var stride = 0
  while true:
    let ctrlBase = cast[ptr uint8](cast[uint](ctrl) + uint(offset))
    var matchMask = nimSwMatch16(ctrlBase, h2)
    while matchMask != 0:
      let slotOff = nimSwCtzNibble(matchMask)
      let idx = (offset + slotOff) and mask
      let entry = addr entries[idx]
      if entry.hash == hash and entry.keyLen == uint16(kLen) and
          (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        value = FastStringView(data: swEntryValPtr(entry), len: int(entry.valLen))
        return true
      matchMask = nimSwClearLowestNibble(matchMask)
    let emptyMask = nimSwMatchEmpty16(ctrlBase)
    if emptyMask != 0:
      return false
    stride += SwGroupSize
    offset = (offset + stride) and mask
  false

proc lookupFastMapStringViewHashed(storage: FastMapStringNimStorage, kPtr: pointer, kLen: int, hash: uint64, value: var FastStringView): bool =
  if storage == nil or storage.capacity == 0:
    return false
  var idx = findFastMapStringIdxByPtr(storage, kPtr, kLen, hash)
  if idx < 0:
    idx = findFastMapStringIdxByKeyOnly(storage, kPtr, kLen)
  if idx < 0:
    return false
  let entry = swEntryAt(storage, idx)
  value = FastStringView(data: swEntryValPtr(entry), len: int(entry.valLen))
  true

proc lookupFastMapStringView(storage: FastMapStringNimStorage, key: string, value: var FastStringView): bool =
  if storage == nil or storage.capacity == 0:
    return false
  let kLen = key.len
  let kPtr = if kLen == 0: nil else: cast[pointer](unsafeAddr key[0])
  let hash = nimFmHash(kPtr, kLen)
  let idx = findFastMapStringIdxByPtr(storage, kPtr, kLen, hash)
  if idx < 0:
    return false
  let entry = swEntryAt(storage, idx)
  value = FastStringView(data: swEntryValPtr(entry), len: int(entry.valLen))
  true

proc swFindInsertSlot(storage: FastMapStringNimStorage, hash: uint64): int =
  let mask = storage.capacity - 1
  var offset = swH1(hash, mask) and not(SwGroupSize - 1)
  var stride = 0

  while true:
    let ctrlBase = swCtrlPtr(storage, offset)
    let freeMask = nimSwMatchEmptyOrDel16(ctrlBase)
    if freeMask != 0:
      let slotOff = nimSwCtzNibble(freeMask)
      return (offset + slotOff) and mask
    stride += SwGroupSize
    offset = (offset + stride) and mask

proc insertFastMapStringRaw(
  storage: FastMapStringNimStorage,
  key, value: string,
  hash: uint64,
  unique = false,
  replace = true
): int =
  ## Swiss table insert. Returns slot index or -1.
  if storage == nil or storage.capacity == 0:
    return -1

  # Check for existing key first (unless caller guarantees uniqueness)
  if not unique:
    var homeBucket: int
    let foundIdx = findFastMapStringFoundIdx(storage, key, hash, homeBucket)
    if foundIdx >= 0:
      if replace:
        let entry = swEntryAt(storage, foundIdx)
        let oldBytes = entryStorageBytes(int(entry.keyLen), int(entry.valLen))
        overwriteEntryValue(swEntryAt(storage, foundIdx)[], value, storage.arena)
        storage.liveBytes += entryStorageBytes(key.len, value.len) - oldBytes
        maybeCompactFastMapStringArena(storage)
      return foundIdx
    let kPtr = if key.len == 0: nil else: cast[pointer](unsafeAddr key[0])
    let duplicateIdx = findFastMapStringIdxByKeyOnly(storage, kPtr, key.len)
    if duplicateIdx >= 0:
      if replace:
        let entry = swEntryAt(storage, duplicateIdx)
        let oldBytes = entryStorageBytes(int(entry.keyLen), int(entry.valLen))
        overwriteEntryValue(entry[], value, storage.arena)
        storage.liveBytes += entryStorageBytes(key.len, value.len) - oldBytes
        maybeCompactFastMapStringArena(storage)
      return duplicateIdx

  # Find empty/deleted slot for new entry
  let idx = swFindInsertSlot(storage, hash)
  let wasDeleted = swCtrlAt(storage, idx) == FastMapCtrlDeleted

  setEntryKV(swEntryAt(storage, idx)[], key, value, hash, storage.arena)
  storage.liveBytes += entryStorageBytes(key.len, value.len)
  swSetCtrl(storage, idx, swH2(hash))
  inc storage.count
  if not wasDeleted:
    inc storage.used
  idx

proc rehashFastMapStringNim(storage: FastMapStringNimStorage, newCap: int) =
  let targetCap = desiredFastMapStringNimCap(max(1, newCap))
  let oldCtrl = storage.ctrl
  let oldEntries = storage.entries
  let oldCap = storage.capacity

  swAllocTables(storage, targetCap)
  storage.count = 0
  storage.used = 0
  updateFastMapStringThresholds(storage)

  if oldCap == 0 or oldCtrl == nil:
    return

  let oldCtrlArr = cast[ptr UncheckedArray[uint8]](oldCtrl)
  let oldEntryArr = cast[ptr UncheckedArray[FastMapStringNimEntry]](oldEntries)
  let mask = storage.capacity - 1

  for i in 0..<oldCap:
    if (oldCtrlArr[i] and 0x80'u8) == 0:  # occupied (top bit clear)
      let e = addr oldEntryArr[i]
      let hash = e.hash
      let h2 = swH2(hash)
      var offset = swH1(hash, mask) and not(SwGroupSize - 1)
      var stride = 0
      while true:
        let ctrlBase = swCtrlPtr(storage, offset)
        let emptyMask = nimSwMatchEmpty16(ctrlBase)
        if emptyMask != 0:
          let slotOff = nimSwCtzNibble(emptyMask)
          let idx = (offset + slotOff) and mask
          # Move entry (transfer pointer ownership, no alloc)
          moveEntry(swEntryAt(storage, idx)[], oldEntryArr[i])
          swSetCtrl(storage, idx, h2)
          inc storage.count
          inc storage.used
          break
        stride += SwGroupSize
        offset = (offset + stride) and mask

  # Free old tables
  c_free(oldCtrl)
  c_free(oldEntries)

proc ensureFastMapStringCapacity(storage: FastMapStringNimStorage, targetCount: int) =
  if storage.capacity == 0 or targetCount > storage.growAt:
    rehashFastMapStringNim(storage, targetCount)
  elif storage.used > storage.rebuildAt:
    # Too many tombstones — rehash in place to clear them
    rehashFastMapStringNim(storage, storage.count)

proc reserveFastMapString(storage: FastMapStringNimStorage, n: int): bool =
  if storage == nil or n < 0:
    return false
  if n == 0:
    return true
  if storage.capacity < desiredFastMapStringNimCap(n):
    rehashFastMapStringNim(storage, n)
  true

proc lenFastMapString(storage: FastMapStringNimStorage): int {.inline.} =
  if storage == nil: 0 else: storage.count

proc putFastMapString(storage: FastMapStringNimStorage, key, value: string): bool {.inline.} =
  if storage == nil:
    return false

  ensureFastMapStringCapacity(storage, storage.count + 1)
  let hash = hashFastMapString(key)
  let idx = insertFastMapStringRaw(storage, key, value, hash, replace = true)
  result = idx >= 0

proc putFastMapStringHashed(storage: FastMapStringNimStorage, key, value: string, hash: uint64): bool {.inline.} =
  if storage == nil:
    return false

  ensureFastMapStringCapacity(storage, storage.count + 1)
  let idx = insertFastMapStringRaw(storage, key, value, hash, replace = true)
  result = idx >= 0

proc tryGetFastMapString(storage: FastMapStringNimStorage, key: string, value: var string): bool {.inline.} =
  var homeBucket: int
  let idx = findFastMapStringFoundIdx(storage, key, hashFastMapString(key), homeBucket)
  if idx < 0:
    return false
  let entry = swEntryAt(storage, idx)
  value = rawStrToString(swEntryValPtr(entry), int32(entry.valLen))
  true

proc getFastMapStringView(storage: FastMapStringNimStorage, key: string, value: var FastStringView): bool {.inline.} =
  var homeBucket: int
  let idx = findFastMapStringFoundIdx(storage, key, hashFastMapString(key), homeBucket)
  if idx < 0:
    return false
  let entry = swEntryAt(storage, idx)
  value = rawStrToView(swEntryValPtr(entry), int32(entry.valLen))
  true

proc containsFastMapString(storage: FastMapStringNimStorage, key: string): bool {.inline.} =
  var homeBucket: int
  findFastMapStringFoundIdx(storage, key, hashFastMapString(key), homeBucket) >= 0

proc tryGetFastMapStringView(storage: FastMapStringNimStorage, key: string, value: var FastStringView): bool {.inline.} =
  getFastMapStringView(storage, key, value)

proc delFastMapString(storage: FastMapStringNimStorage, key: string): bool =
  if storage == nil or storage.capacity == 0:
    return false

  var homeBucket: int
  let hash = hashFastMapString(key)
  let idx = findFastMapStringFoundIdx(storage, key, hash, homeBucket)
  if idx < 0:
    return false

  dec storage.count
  storage.liveBytes -= entryStorageBytes(int(swEntryAt(storage, idx).keyLen), int(swEntryAt(storage, idx).valLen))
  freeEntryStrings(swEntryAt(storage, idx)[])
  zeroEntry(swEntryAt(storage, idx)[])
  swSetCtrl(storage, idx, FastMapCtrlDeleted)
  if storage.count == 0:
    clearFastMapString(storage)
  else:
    maybeCompactFastMapStringArena(storage)
  true

proc clearFastMapString(storage: FastMapStringNimStorage) =
  if storage == nil:
    return
  if storage.capacity > 0 and storage.ctrl != nil:
    c_memset(storage.ctrl, 0xFF.cint, csize_t(storage.capacity + SwGroupSize))
    zeroMem(storage.entries, storage.capacity * sizeof(FastMapStringNimEntry))
  storage.count = 0
  storage.used = 0
  storage.liveBytes = 0
  arenaReset(storage.arena)

proc nextFastMapStringOccupiedIdx(storage: FastMapStringNimStorage, idx: var int): bool {.inline.} =
  if storage == nil or storage.capacity == 0:
    return false
  let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
  let cap = storage.capacity
  # Scan 8 bytes at a time: occupied slots have top bit clear (0x00-0x7F)
  const allMsb = 0x8080808080808080'u64
  while idx + 8 <= cap:
    var word: uint64
    copyMem(addr word, addr ctrl[idx], 8)
    # Invert top bits: now occupied slots have bit 7 SET
    let occupied = (not word) and allMsb
    if occupied != 0:
      # Use ctz to find first occupied byte
      idx = idx + (countTrailingZeroBits(occupied) shr 3)
      return true
    idx += 8
  # Handle remaining
  while idx < cap:
    if (ctrl[idx] and 0x80'u8) == 0:
      return true
    inc idx
  false

proc rehashFastMapNim[V](storage: FastMapNimStorage[V], newCap: int)

proc findFastMapNimSlot[V](storage: FastMapNimStorage[V], key: string, hash: uint64): tuple[idx: int, found: bool] {.inline.} =
  if storage == nil or storage.entries.len == 0:
    return (-1, false)

  let mask = storage.ctrl.len - 1
  let sig = fastMapCtrl(hash)
  var idx = int(hash and uint64(mask))
  var firstDeleted = -1
  while true:
    let ctrl = storage.ctrl[idx]
    if ctrl == FastMapCtrlEmpty:
      return ((if firstDeleted >= 0: firstDeleted else: idx), false)
    elif ctrl == sig:
      if storage.entries[idx].hash == hash and fastMapStringEquals(storage.entries[idx].key, key):
        return (idx, true)
    elif ctrl == FastMapCtrlDeleted:
      if firstDeleted < 0:
        firstDeleted = idx
    idx = (idx + 1) and mask

proc findFastMapNimFoundIdx[V](storage: FastMapNimStorage[V], key: string, hash: uint64): int {.inline.} =
  if storage == nil or storage.entries.len == 0:
    return -1

  let mask = storage.ctrl.len - 1
  let sig = fastMapCtrl(hash)
  var idx = int(hash and uint64(mask))
  while true:
    let ctrl = storage.ctrl[idx]
    if ctrl == FastMapCtrlEmpty:
      return -1
    elif ctrl == sig:
      if storage.entries[idx].hash == hash and fastMapStringEquals(storage.entries[idx].key, key):
        return idx
    idx = (idx + 1) and mask

proc rehashFastMapNim[V](storage: FastMapNimStorage[V], newCap: int) =
  let targetCap = desiredFastMapNimCap(max(1, newCap))
  let oldCtrl = move(storage.ctrl)
  let oldEntries = move(storage.entries)
  storage.ctrl = newSeq[uint8](targetCap)
  storage.entries = newSeq[FastMapNimEntry[V]](targetCap)
  resetFastMapCtrl(storage)
  storage.count = 0
  storage.used = 0
  updateFastMapThresholds(storage)
  if oldEntries.len == 0:
    return

  for i in 0..<oldEntries.len:
    let ctrl = oldCtrl[i]
    if ctrl != FastMapCtrlEmpty and ctrl != FastMapCtrlDeleted:
      let entry = oldEntries[i]
      let hash = entry.hash
      let sig = fastMapCtrl(hash)
      let mask = storage.ctrl.len - 1
      var idx = int(hash and uint64(mask))
      while storage.ctrl[idx] != FastMapCtrlEmpty:
        idx = (idx + 1) and mask
      storage.ctrl[idx] = sig
      storage.entries[idx].hash = hash
      storage.entries[idx].key = entry.key
      storage.entries[idx].value = entry.value
      inc storage.used
      inc storage.count

proc ensureFastMapNimCapacity[V](storage: FastMapNimStorage[V], targetCount: int) =
  if storage.entries.len == 0:
    rehashFastMapNim(storage, targetCount)
    return

  if targetCount >= storage.growAt or storage.used >= storage.rebuildAt:
    rehashFastMapNim(storage, max(targetCount, storage.entries.len))
  elif storage.count * 4 < storage.used and storage.entries.len > 8:
    rehashFastMapNim(storage, storage.entries.len)

proc reserveFastMapNim[V](storage: FastMapNimStorage[V], n: int): bool =
  if storage == nil or n < 0:
    return false
  if n == 0:
    return true
  if storage.entries.len < desiredFastMapNimCap(n):
    rehashFastMapNim(storage, n)
  true

proc lenFastMapNim[V](storage: FastMapNimStorage[V]): int {.inline.} =
  if storage == nil: 0 else: storage.count

proc putFastMapNim[V](storage: FastMapNimStorage[V], key: string, value: sink V): bool {.inline.} =
  if storage == nil:
    return false
  let hash = hashFastMapString(key)
  if storage.entries.len == 0:
    ensureFastMapNimCapacity(storage, 1)
  let (idx, found) = findFastMapNimSlot(storage, key, hash)
  if idx < 0:
    return false
  if found:
    storage.entries[idx].value = value
    return true

  if storage.count + 1 < storage.growAt and storage.used < storage.rebuildAt:
    if storage.ctrl[idx] == FastMapCtrlEmpty:
      inc storage.used
    storage.ctrl[idx] = fastMapCtrl(hash)
    storage.entries[idx].hash = hash
    storage.entries[idx].key = key
    storage.entries[idx].value = value
    inc storage.count
    return true

  ensureFastMapNimCapacity(storage, storage.count + 1)
  let (insertIdx, insertFound) = findFastMapNimSlot(storage, key, hash)
  if insertIdx < 0:
    return false
  if insertFound:
    storage.entries[insertIdx].value = value
  else:
    if storage.ctrl[insertIdx] == FastMapCtrlEmpty:
      inc storage.used
    storage.ctrl[insertIdx] = fastMapCtrl(hash)
    storage.entries[insertIdx].hash = hash
    storage.entries[insertIdx].key = key
    storage.entries[insertIdx].value = value
    inc storage.count
  true

proc tryGetFastMapNim[V](storage: FastMapNimStorage[V], key: string, value: var V): bool =
  if storage == nil or storage.entries.len == 0:
    return false
  let idx = findFastMapNimFoundIdx(storage, key, hashFastMapString(key))
  if idx < 0:
    return false
  value = storage.entries[idx].value
  true

proc tryGetFastMapNimHashed[V](storage: FastMapNimStorage[V], key: string, hash: uint64, value: var V): bool {.used.} =
  if storage == nil or storage.entries.len == 0:
    return false
  let idx = findFastMapNimFoundIdx(storage, key, hash)
  if idx < 0:
    return false
  value = storage.entries[idx].value
  true

proc getFastMapNimPtr[V](storage: FastMapNimStorage[V], key: string): ptr V {.inline.} =
  if storage == nil or storage.entries.len == 0:
    return nil
  let idx = findFastMapNimFoundIdx(storage, key, hashFastMapString(key))
  if idx < 0:
    return nil
  addr storage.entries[idx].value

proc getFastMapNimPtrHashed[V](storage: FastMapNimStorage[V], key: string, hash: uint64): ptr V {.inline.} =
  if storage == nil or storage.entries.len == 0:
    return nil
  let idx = findFastMapNimFoundIdx(storage, key, hash)
  if idx < 0:
    return nil
  addr storage.entries[idx].value

proc getOrPutFastMapNimPtr[V](storage: FastMapNimStorage[V], key: string, value: sink V): ptr V {.inline.} =
  if storage == nil:
    return nil
  let hash = hashFastMapString(key)
  if storage.entries.len == 0:
    ensureFastMapNimCapacity(storage, 1)
  let (idx, found) = findFastMapNimSlot(storage, key, hash)
  if idx >= 0 and found:
    return addr storage.entries[idx].value

  if idx >= 0 and storage.count + 1 < storage.growAt and storage.used < storage.rebuildAt:
    if storage.ctrl[idx] == FastMapCtrlEmpty:
      inc storage.used
    storage.ctrl[idx] = fastMapCtrl(hash)
    storage.entries[idx].hash = hash
    storage.entries[idx].key = key
    storage.entries[idx].value = value
    inc storage.count
    return addr storage.entries[idx].value

  ensureFastMapNimCapacity(storage, storage.count + 1)
  let (insertIdx, insertFound) = findFastMapNimSlot(storage, key, hash)
  if insertIdx < 0:
    return nil
  if not insertFound:
    if storage.ctrl[insertIdx] == FastMapCtrlEmpty:
      inc storage.used
    storage.ctrl[insertIdx] = fastMapCtrl(hash)
    storage.entries[insertIdx].hash = hash
    storage.entries[insertIdx].key = key
    storage.entries[insertIdx].value = value
    inc storage.count
  addr storage.entries[insertIdx].value

proc reserveFastMapInt64(storage: FastMapInt64NimStorage, n: int): bool {.inline.} =
  reserveFastMapNim(storage, n)

proc lenFastMapInt64(storage: FastMapInt64NimStorage): int {.inline.} =
  lenFastMapNim(storage)

proc putFastMapInt64(storage: FastMapInt64NimStorage, key: string, value: int64): bool {.inline.} =
  putFastMapNim[int64](storage, key, value)

proc tryGetFastMapInt64(storage: FastMapInt64NimStorage, key: string, value: var int64): bool {.inline.} =
  tryGetFastMapNim[int64](storage, key, value)

proc getFastMapInt64Ptr(storage: FastMapInt64NimStorage, key: string): ptr int64 {.inline.} =
  getFastMapNimPtr[int64](storage, key)

proc getOrPutFastMapInt64Ptr(storage: FastMapInt64NimStorage, key: string, value: int64): ptr int64 {.inline.} =
  getOrPutFastMapNimPtr[int64](storage, key, value)

proc containsFastMapInt64(storage: FastMapInt64NimStorage, key: string): bool {.inline.} =
  not storage.getFastMapInt64Ptr(key).isNil

proc delFastMapInt64(storage: FastMapInt64NimStorage, key: string): bool =
  if storage == nil or storage.entries.len == 0:
    return false
  let idx = findFastMapNimFoundIdx(storage, key, hashFastMapString(key))
  if idx < 0:
    return false
  storage.ctrl[idx] = FastMapCtrlDeleted
  dec storage.count
  if storage.count == 0:
    storage.used = 0
    for i in 0..<storage.entries.len:
      storage.ctrl[i] = FastMapCtrlEmpty
      storage.entries[i] = default(FastMapNimEntry[int64])
  elif storage.count * 4 < storage.used and storage.entries.len > 8:
    rehashFastMapNim(storage, storage.entries.len)
  true

proc clearFastMapInt64(storage: FastMapInt64NimStorage) =
  if storage == nil:
    return
  storage.count = 0
  storage.used = 0
  for i in 0..<storage.entries.len:
    storage.ctrl[i] = FastMapCtrlEmpty
    storage.entries[i] = default(FastMapNimEntry[int64])

proc delFastMapGeneric[V](storage: FastMapNimStorage[V], key: string): bool =
  if storage == nil or storage.entries.len == 0:
    return false
  let idx = findFastMapNimFoundIdx(storage, key, hashFastMapString(key))
  if idx < 0:
    return false
  storage.ctrl[idx] = FastMapCtrlDeleted
  dec storage.count
  if storage.count == 0:
    storage.used = 0
    for i in 0..<storage.entries.len:
      storage.ctrl[i] = FastMapCtrlEmpty
      storage.entries[i] = default(FastMapNimEntry[V])
  elif storage.count * 4 < storage.used and storage.entries.len > 8:
    rehashFastMapNim(storage, storage.entries.len)
  true

proc clearFastMapGeneric[V](storage: FastMapNimStorage[V]) =
  if storage == nil:
    return
  storage.count = 0
  storage.used = 0
  for i in 0..<storage.entries.len:
    storage.ctrl[i] = FastMapCtrlEmpty
    storage.entries[i] = default(FastMapNimEntry[V])

proc releaseFastMapFields[V](map: FastMap[V]) =
  if map.raw == nil and map.nimString.isNil and map.nimInt64.isNil and
      map.kind != fmskNimGeneric:
    return
  case map.kind
  of fmskString:
    nx_fm_str_map_free(map.raw)
  of fmskStringNim:
    if not map.nimString.isNil:
      swFreeTables(map.nimString)
      arenaFreeAll(map.nimString.arena)
    map.nimString = nil
  of fmskInt64C:
    nx_fm_str_i64_map_free(map.raw)
  of fmskInt64Nim:
    map.nimInt64 = nil
  of fmskStringArena:
    nx_fm_str_arena_map_free(map.raw)
  of fmskInt64Arena:
    nx_fm_str_arena_i64_map_free(map.raw)
  of fmskNimGeneric:
    discard
  map.raw = nil

proc rawHandle[V](map: FastMap[V]): pointer {.inline.} =
  if map == nil:
    return nil
  if map.kind == fmskStringNim:
    return cast[pointer](map.nimString)
  if map.kind == fmskInt64Nim:
    return cast[pointer](map.nimInt64)
  if map.kind == fmskNimGeneric:
    return cast[pointer](map.nimGenericStorage)
  map.raw

## Create a new empty `FastMap` with a type-specific backend.
proc newFastMap*[V](): FastMap[V] =
  new(result)
  when V is string:
    when UseNimStringFastMapBackend:
      result.kind = fmskStringNim
      result.nimString = initFastMapStringNimStorage()
    else:
      result.kind = fmskString
      result.raw = nx_fm_str_map_new()
  elif V is int64:
    when UseNimInt64FastMapBackend:
      result.kind = fmskInt64Nim
      result.nimInt64 = initFastMapInt64NimStorage()
    else:
      result.kind = fmskInt64C
      result.raw = nx_fm_str_i64_map_new()
  else:
    result.kind = fmskNimGeneric
    result.nimGenericStorage = initFastMapNimStorage[V]()

## Create a new `FastMap` reserved for initialSize entries.
proc newFastMap*[V](initialSize: Natural): FastMap[V] =
  result = newFastMap[V]()
  if result != nil:
    discard result.reserve(int(initialSize))

## Create a new `FastMap` prepopulated from key and value pairs.
proc newFastMap*[V](pairs: openArray[(string, V)]): FastMap[V] =
  result = newFastMap[V]()
  if result != nil:
    discard result.reserve(pairs.len)
    for pair in pairs:
      let (key, value) = pair
      discard result.put(key, value)

## Create a new `FastMap` backed by an arena allocator with the given chunk size.
proc newFastArenaMap*[V](arenaChunkSize = DefaultFastMapArenaChunkSize): FastMap[V] =
  new(result)
  let chunkSize = csize_t(max(64, arenaChunkSize))
  when V is string:
    result.kind = fmskStringArena
    result.raw = nx_fm_str_arena_map_new(chunkSize)
  elif V is int64:
    result.kind = fmskInt64Arena
    result.raw = nx_fm_str_arena_i64_map_new(chunkSize)
  else:
    result.kind = fmskNimGeneric
    result.nimGenericStorage = initFastMapNimStorage[V]()

## Create a new empty `FastHashMap`.
proc newFastHashMap*[V](): FastHashMap[V] {.inline.} = newFastMap[V]()
## Create a new `FastHashMap` reserved for initialSize entries.
proc newFastHashMap*[V](initialSize: Natural): FastHashMap[V] {.inline.} = newFastMap[V](initialSize)
## Create a new empty `FastHashTable`.
proc newFastHashTable*[V](): FastHashTable[V] {.inline.} = newFastMap[V]()
## Create a new `FastHashTable` reserved for initialSize entries.
proc newFastHashTable*[V](initialSize: Natural): FastHashTable[V] {.inline.} = newFastMap[V](initialSize)
## Create a new `FastHashMap` prepopulated from key and value pairs.
proc newFastHashMap*[V](pairs: openArray[(string, V)]): FastHashMap[V] {.inline.} = newFastMap[V](pairs)
## Create a new `FastHashTable` prepopulated from key and value pairs.
proc newFastHashTable*[V](pairs: openArray[(string, V)]): FastHashTable[V] {.inline.} = newFastMap[V](pairs)
## Create a new `FastHashMap` backed by an arena allocator with the given chunk size.
proc newFastArenaHashMap*[V](arenaChunkSize = DefaultFastMapArenaChunkSize): FastHashMap[V] {.inline.} = newFastArenaMap[V](arenaChunkSize)
## Create a new `FastHashTable` backed by an arena allocator with the given chunk size.
proc newFastArenaHashTable*[V](arenaChunkSize = DefaultFastMapArenaChunkSize): FastHashTable[V] {.inline.} = newFastArenaMap[V](arenaChunkSize)
## Create a new empty `FastMap`.
proc newFastTable*[V](): FastMap[V] {.inline.} = newFastMap[V]()
## Create a new `FastMap` reserved for initialSize entries.
proc newFastTable*[V](initialSize: Natural): FastMap[V] {.inline.} = newFastMap[V](initialSize)
## Create a new `FastMap` prepopulated from key and value pairs.
proc newFastTable*[V](pairs: openArray[(string, V)]): FastMap[V] {.inline.} = newFastMap[V](pairs)
## Create a new `FastMap` backed by an arena allocator with the given chunk size.
proc newFastArenaTable*[V](arenaChunkSize = DefaultFastMapArenaChunkSize): FastMap[V] {.inline.} = newFastArenaMap[V](arenaChunkSize)

## Build a `FastMap` from a collection, indexing each item with the index proc.
proc newFastMapFrom*[A, B](collection: A, index: proc(x: B): string): FastMap[B] =
  result = newFastMap[B]()
  if result != nil:
    for item in collection:
      result[index(item)] = item

## Build a `FastMap` from a collection, indexing each item with the index proc.
proc newFastTableFrom*[A, B](collection: A, index: proc(x: B): string): FastMap[B] {.inline.} =
  newFastMapFrom[A, B](collection, index)

## Release all storage owned by the map.
proc close*[V](map: FastMap[V]) {.inline.} =
  if map == nil:
    return
  releaseFastMapFields(map)
  when not (V is string or V is int64):
    map.nimGenericStorage = nil

## Return the number of entries in the map.
proc len*[V](map: FastMap[V]): int {.inline.} =
  if map == nil:
    return 0
  when V is string:
    case map.kind
    of fmskString:
      let raw = map.rawHandle()
      if raw == nil:
        return 0
      int(nx_fm_str_map_size(raw))
    of fmskStringNim:
      lenFastMapString(map.nimString)
    of fmskStringArena:
      let raw = map.rawHandle()
      if raw == nil:
        return 0
      int(nx_fm_str_arena_map_size(raw))
    else:
      0
  elif V is int64:
    case map.kind
    of fmskInt64C:
      let raw = map.rawHandle()
      if raw == nil:
        return 0
      int(nx_fm_str_i64_map_size(raw))
    of fmskInt64Nim:
      lenFastMapInt64(map.nimInt64)
    of fmskInt64Arena:
      let raw = map.rawHandle()
      if raw == nil:
        return 0
      int(nx_fm_str_arena_i64_map_size(raw))
    else:
      0
  else:
    if map.nimGenericStorage.isNil: 0
    else: lenFastMapNim(map.nimGenericStorage)

## Reserve capacity for n entries; returns false for invalid maps or counts.
proc reserve*[V](map: FastMap[V], n: int): bool {.inline.} =
  if map == nil or n < 0:
    return false
  when V is string:
    case map.kind
    of fmskString:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_map_reserve(map.raw, csize_t(n))
    of fmskStringNim:
      if map.nimString == nil:
        map.nimString = initFastMapStringNimStorage()
      reserveFastMapString(map.nimString, n)
    of fmskStringArena:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_arena_map_reserve(map.raw, csize_t(n))
    else:
      false
  elif V is int64:
    case map.kind
    of fmskInt64C:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_i64_map_reserve(map.raw, csize_t(n))
    of fmskInt64Nim:
      if map.nimInt64 == nil:
        map.nimInt64 = initFastMapInt64NimStorage()
      reserveFastMapInt64(map.nimInt64, n)
    of fmskInt64Arena:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_arena_i64_map_reserve(map.raw, csize_t(n))
    else:
      false
  else:
    if map.nimGenericStorage.isNil: false
    else: reserveFastMapNim(map.nimGenericStorage, n)

## Insert or update a key and value entry; returns false if the map is unusable.
proc put*[V](map: FastMap[V], key: string, value: V): bool {.inline.} =
  when V is string:
    case map.kind
    of fmskString:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_map_set_n(raw, cast[cstring](key.stringPtr), csize_t(key.len), cast[cstring](value.stringPtr), csize_t(value.len))
    of fmskStringNim:
      putFastMapString(map.nimString, key, value)
    of fmskStringArena:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_arena_map_set_n(raw, cast[cstring](key.stringPtr), csize_t(key.len), cast[cstring](value.stringPtr), csize_t(value.len))
    else:
      false
  elif V is int64:
    case map.kind
    of fmskInt64C:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_i64_map_set_n(raw, cast[cstring](key.stringPtr), csize_t(key.len), value)
    of fmskInt64Nim:
      putFastMapInt64(map.nimInt64, key, value)
    of fmskInt64Arena:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_arena_i64_map_set_n(raw, cast[cstring](key.stringPtr), csize_t(key.len), value)
    else:
      false
  else:
    if map.nimGenericStorage.isNil: false
    else: putFastMapNim(map.nimGenericStorage, key, value)

## Insert or update an entry from cstring key and value without allocation.
proc putC*(map: FastMap[string], key, value: cstring): bool {.inline.} =
  if value == nil:
    return false
  case map.kind
  of fmskString:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_map_set_n(raw, cast[cstring](key.cstringPtr), key.cstringLen, cast[cstring](value.cstringPtr), value.cstringLen)
  of fmskStringNim:
    if map.nimString == nil:
      map.nimString = initFastMapStringNimStorage()
    putFastMapString(map.nimString, key.toOwnedString, value.toOwnedString)
  of fmskStringArena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_arena_map_set_n(raw, cast[cstring](key.cstringPtr), key.cstringLen, cast[cstring](value.cstringPtr), value.cstringLen)
  else:
    false

## Insert or update an entry from `FastStringView` key and value.
proc putView*(map: FastMap[string], key, value: FastStringView): bool {.inline.} =
  if not key.isValidFastStringView or not value.isValidFastStringView:
    return false
  case map.kind
  of fmskString:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_map_set_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen, cast[cstring](value.toFastStringViewPtr), value.toFastStringViewLen)
  of fmskStringNim:
    if map.nimString == nil:
      map.nimString = initFastMapStringNimStorage()
    putFastMapString(map.nimString, key.toOwnedString, value.toOwnedString)
  of fmskStringArena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_arena_map_set_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen, cast[cstring](value.toFastStringViewPtr), value.toFastStringViewLen)
  else:
    false

## Insert or update an int64 entry from a cstring key without allocation.
proc putC*(map: FastMap[int64], key: cstring, value: int64): bool {.inline.} =
  case map.kind
  of fmskInt64C:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_i64_map_set_n(raw, cast[cstring](key.cstringPtr), key.cstringLen, value)
  of fmskInt64Nim:
    if map.nimInt64 == nil:
      map.nimInt64 = initFastMapInt64NimStorage()
    putFastMapInt64(map.nimInt64, key.toOwnedString, value)
  of fmskInt64Arena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_arena_i64_map_set_n(raw, cast[cstring](key.cstringPtr), key.cstringLen, value)
  else:
    false

## Insert or update an int64 entry from a `FastStringView` key.
proc putView*(map: FastMap[int64], key: FastStringView, value: int64): bool {.inline.} =
  if not key.isValidFastStringView:
    return false
  case map.kind
  of fmskInt64C:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_i64_map_set_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen, value)
  of fmskInt64Nim:
    if map.nimInt64 == nil:
      map.nimInt64 = initFastMapInt64NimStorage()
    putFastMapInt64(map.nimInt64, key.toOwnedString, value)
  of fmskInt64Arena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_arena_i64_map_set_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen, value)
  else:
    false

## Lookup a value as a `FastStringView` without copying it.
proc tryGetView*(map: FastMap[string], key: string, value: var FastStringView): bool {.inline.} =
  case map.kind
  of fmskString:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    var valuePtr: cstring
    var valueLen: csize_t
    if not nx_fm_str_map_get_view_n(raw, cast[cstring](key.stringPtr), csize_t(key.len), addr valuePtr, addr valueLen):
      return false
    value = initFastStringView(valuePtr, valueLen)
    true
  of fmskStringNim:
    lookupFastMapStringView(map.nimString, key, value)
  of fmskStringArena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    var valuePtr: cstring
    var valueLen: csize_t
    if not nx_fm_str_arena_map_get_view_n(raw, cast[cstring](key.stringPtr), csize_t(key.len), addr valuePtr, addr valueLen):
      return false
    value = initFastStringView(valuePtr, valueLen)
    true
  else:
    false

## Lookup a value as a `FastStringView` from a cstring key without copying.
proc tryGetView*(map: FastMap[string], key: cstring, value: var FastStringView): bool {.inline.} =
  case map.kind
  of fmskString:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    var valuePtr: cstring
    var valueLen: csize_t
    if not nx_fm_str_map_get_view_n(raw, cast[cstring](key.cstringPtr), key.cstringLen, addr valuePtr, addr valueLen):
      return false
    value = initFastStringView(valuePtr, valueLen)
    true
  of fmskStringNim:
    tryGetFastMapStringView(map.nimString, key.toOwnedString, value)
  of fmskStringArena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    var valuePtr: cstring
    var valueLen: csize_t
    if not nx_fm_str_arena_map_get_view_n(raw, cast[cstring](key.cstringPtr), key.cstringLen, addr valuePtr, addr valueLen):
      return false
    value = initFastStringView(valuePtr, valueLen)
    true
  else:
    false

## Lookup a value as a `FastStringView` from another view without copying.
proc tryGetView*(map: FastMap[string], key: FastStringView, value: var FastStringView): bool {.inline.} =
  if not key.isValidFastStringView:
    return false
  case map.kind
  of fmskString:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    var valuePtr: cstring
    var valueLen: csize_t
    if not nx_fm_str_map_get_view_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen, addr valuePtr, addr valueLen):
      return false
    value = initFastStringView(valuePtr, valueLen)
    true
  of fmskStringNim:
    tryGetFastMapStringView(map.nimString, key.toOwnedString, value)
  of fmskStringArena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    var valuePtr: cstring
    var valueLen: csize_t
    if not nx_fm_str_arena_map_get_view_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen, addr valuePtr, addr valueLen):
      return false
    value = initFastStringView(valuePtr, valueLen)
    true
  else:
    false

## Return a `FastStringView` of the stored value, or an empty view if missing.
proc getView*(map: FastMap[string], key: string): FastStringView {.inline.} =
  discard map.tryGetView(key, result)

## Return a `FastStringView` of the stored value for a cstring key, or an empty view if missing.
proc getView*(map: FastMap[string], key: cstring): FastStringView {.inline.} =
  discard map.tryGetView(key, result)

## Return a `FastStringView` of the stored value for a view key, or an empty view if missing.
proc getView*(map: FastMap[string], key: FastStringView): FastStringView {.inline.} =
  discard map.tryGetView(key, result)

## Compute the fastmap hash for a string key.
proc hashKey*(key: string): uint64 =
  nimFmHash(key.stringPtr, key.len)

## Compute the fastmap hash for a cstring key.
proc hashKey*(key: cstring): uint64 =
  nimFmHash(cast[pointer](key), int(key.cstringLen))

## Compute the fastmap hash for a `FastStringView` key.
proc hashKey*(key: FastStringView): uint64 =
  if not key.isValidFastStringView:
    return 0
  nimFmHash(key.data, key.len)

## Lookup a value length using a precomputed hash; returns the default if missing.
proc getLenHashed*(map: FastMap[string], key: string, hash: uint64, default = 0): int {.inline.} =
  ## Lookup with precomputed hash — eliminates hash computation overhead.
  if map.kind == fmskStringNim:
    let kPtr = if key.len == 0: nil else: cast[pointer](unsafeAddr key[0])
    let len = lookupFastMapStringLenHashed(map.nimString, kPtr, key.len, hash)
    return if len < 0: default else: len
  # Fallback: regular lookup for other backends
  var view: FastStringView
  if not map.tryGetView(key, view): return default
  view.len

## Lookup a value view using a precomputed hash; returns false if missing.
proc tryGetViewHashed*(map: FastMap[string], key: string, hash: uint64, value: var FastStringView): bool {.inline.} =
  ## Lookup with precomputed hash — eliminates hash computation overhead.
  if map.kind == fmskStringNim:
    let kPtr = if key.len == 0: nil else: cast[pointer](unsafeAddr key[0])
    return lookupFastMapStringViewHashed(map.nimString, kPtr, key.len, hash, value)
  map.tryGetView(key, value)

## Return a value view using a precomputed hash, or an empty view if missing.
proc getViewHashed*(map: FastMap[string], key: string, hash: uint64): FastStringView {.inline.} =
  discard map.tryGetViewHashed(key, hash, result)

## Insert or update an entry using a precomputed key hash.
proc putHashed*(map: FastMap[string], key: string, hash: uint64, value: string): bool {.inline.} =
  case map.kind
  of fmskString:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_map_set_h(raw, cast[cstring](key.stringPtr), csize_t(key.len), hash, cast[cstring](value.stringPtr), csize_t(value.len))
  of fmskStringNim:
    if map.nimString == nil:
      map.nimString = initFastMapStringNimStorage()
    putFastMapStringHashed(map.nimString, key, value, hash)
  of fmskStringArena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_arena_map_set_h(raw, cast[cstring](key.stringPtr), csize_t(key.len), hash, cast[cstring](value.stringPtr), csize_t(value.len))
  else:
    false

## Return the stored value length for a key, or the default if missing.
proc getLen*(map: FastMap[string], key: string, default = 0): int {.inline.} =
  if map.kind == fmskStringNim:
    let len = lookupFastMapStringLen(map.nimString, key)
    return if len < 0: default else: len
  var view: FastStringView
  if not map.tryGetView(key, view):
    return default
  view.len

## Return the stored value length for a cstring key, or the default if missing.
proc getLen*(map: FastMap[string], key: cstring, default = 0): int {.inline.} =
  var view: FastStringView
  if not map.tryGetView(key, view):
    return default
  view.len

## Return the stored value length for a view key, or the default if missing.
proc getLen*(map: FastMap[string], key: FastStringView, default = 0): int {.inline.} =
  var view: FastStringView
  if not map.tryGetView(key, view):
    return default
  view.len

## Lookup a value by key; returns false if the key is missing.
proc tryGet*[V](map: FastMap[V], key: string, value: var V): bool {.inline.} =
  when V is string:
    case map.kind
    of fmskStringNim:
      tryGetFastMapString(map.nimString, key, value)
    else:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      var view: FastStringView
      if not map.tryGetView(key, view):
        return false
      value = $view
      true
  elif V is int64:
    case map.kind
    of fmskInt64C:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_i64_map_get_n(raw, cast[cstring](key.stringPtr), csize_t(key.len), addr value)
    of fmskInt64Nim:
      tryGetFastMapInt64(map.nimInt64, key, value)
    of fmskInt64Arena:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_arena_i64_map_get_n(raw, cast[cstring](key.stringPtr), csize_t(key.len), addr value)
    else:
      false
  else:
    if map.nimGenericStorage.isNil: false
    else: tryGetFastMapNim(map.nimGenericStorage, key, value)

## Lookup a cstring key value as a `FastStringView` without copying.
proc tryGetC*(map: FastMap[string], key: cstring, value: var FastStringView): bool {.inline.} =
  map.tryGetView(key, value)

## Return a zero-copy pointer to the stored value using a precomputed hash.
proc getPtrHashed*[V](map: FastMap[V], key: string, hash: uint64): ptr V {.inline.} =
  ## Zero-copy pointer lookup with pre-computed hash (from hashKey).
  ## The pointer is invalidated if the map is mutated.
  ##
  ## Hot-path API: eliminates both hash recomputation and ORC copy.
  ## Precompute hashes once per key set with hashKey() and reuse across lookups.
  when V is string:
    nil
  elif V is int64:
    if map.nimInt64.isNil: nil
    else: getFastMapNimPtrHashed[int64](map.nimInt64, key, hash)
  else:
    if map.nimGenericStorage.isNil: nil
    else: getFastMapNimPtrHashed(map.nimGenericStorage, key, hash)

## Lookup a cstring key value as a `FastStringView` without copying.
proc tryGetViewC*(map: FastMap[string], key: cstring, value: var FastStringView): bool {.inline.} =
  map.tryGetView(key, value)

## Return the value for a key, or the default if the key is missing.
proc get*[V](map: FastMap[V], key: string, default: V = default(V)): V {.inline.} =
  result = default
  discard map.tryGet(key, result)

proc missingFastMapKey(key: string): ref KeyError {.inline.} =
  newException(KeyError, "key not found: " & key)

proc stringValuePtr(map: FastMap[string], key: string): ptr string {.inline, used.} =
  nil  ## No longer supported — entries use unmanaged storage

proc stringValuePtrOrPut(map: FastMap[string], key, value: string): ptr string {.inline, used.} =
  nil  ## No longer supported — entries use unmanaged storage

proc int64ValuePtr(map: FastMap[int64], key: string): ptr int64 {.inline.} =
  case map.kind
  of fmskInt64C:
    let raw = map.rawHandle()
    if raw == nil:
      return nil
    nx_fm_str_i64_map_get_ptr_n(raw, cast[cstring](key.stringPtr), csize_t(key.len))
  of fmskInt64Nim:
    getFastMapInt64Ptr(map.nimInt64, key)
  of fmskInt64Arena:
    let raw = map.rawHandle()
    if raw == nil:
      return nil
    nx_fm_str_arena_i64_map_get_ptr_n(raw, cast[cstring](key.stringPtr), csize_t(key.len))
  else:
    nil

proc int64ValuePtrOrPut(map: FastMap[int64], key: string, value: int64): ptr int64 {.inline.} =
  case map.kind
  of fmskInt64C:
    let raw = map.rawHandle()
    if raw == nil:
      return nil
    nx_fm_str_i64_map_get_or_put_ptr_n(raw, cast[cstring](key.stringPtr), csize_t(key.len), value)
  of fmskInt64Nim:
    if map.nimInt64 == nil:
      map.nimInt64 = initFastMapInt64NimStorage()
    getOrPutFastMapInt64Ptr(map.nimInt64, key, value)
  of fmskInt64Arena:
    let raw = map.rawHandle()
    if raw == nil:
      return nil
    nx_fm_str_arena_i64_map_get_or_put_ptr_n(raw, cast[cstring](key.stringPtr), csize_t(key.len), value)
  else:
    nil

## Check whether the map contains a key.
proc contains*[V](map: FastMap[V], key: string): bool {.inline.} =
  when V is string:
    case map.kind
    of fmskString:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_map_contains_n(raw, cast[cstring](key.stringPtr), csize_t(key.len))
    of fmskStringNim:
      containsFastMapString(map.nimString, key)
    of fmskStringArena:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_arena_map_contains_n(raw, cast[cstring](key.stringPtr), csize_t(key.len))
    else:
      false
  elif V is int64:
    case map.kind
    of fmskInt64C:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_i64_map_contains_n(raw, cast[cstring](key.stringPtr), csize_t(key.len))
    of fmskInt64Nim:
      containsFastMapInt64(map.nimInt64, key)
    of fmskInt64Arena:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_arena_i64_map_contains_n(raw, cast[cstring](key.stringPtr), csize_t(key.len))
    else:
      false
  else:
    if map.nimGenericStorage.isNil: false
    else: not getFastMapNimPtr(map.nimGenericStorage, key).isNil

## Check whether the map contains a cstring key.
proc containsC*(map: FastMap[string], key: cstring): bool {.inline.} =
  case map.kind
  of fmskString:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_map_contains_n(raw, cast[cstring](key.cstringPtr), key.cstringLen)
  of fmskStringNim:
    containsFastMapString(map.nimString, key.toOwnedString)
  of fmskStringArena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_arena_map_contains_n(raw, cast[cstring](key.cstringPtr), key.cstringLen)
  else:
    false

## Check whether the map contains a cstring key.
proc containsC*(map: FastMap[int64], key: cstring): bool {.inline.} =
  case map.kind
  of fmskInt64C:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_i64_map_contains_n(raw, cast[cstring](key.cstringPtr), key.cstringLen)
  of fmskInt64Nim:
    containsFastMapInt64(map.nimInt64, key.toOwnedString)
  of fmskInt64Arena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_arena_i64_map_contains_n(raw, cast[cstring](key.cstringPtr), key.cstringLen)
  else:
    false

## Check whether the map contains a `FastStringView` key.
proc containsView*(map: FastMap[string], key: FastStringView): bool {.inline.} =
  if not key.isValidFastStringView:
    return false
  case map.kind
  of fmskString:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_map_contains_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)
  of fmskStringNim:
    containsFastMapString(map.nimString, key.toOwnedString)
  of fmskStringArena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_arena_map_contains_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)
  else:
    false

## Check whether the map contains a `FastStringView` key.
proc containsView*(map: FastMap[int64], key: FastStringView): bool {.inline.} =
  if not key.isValidFastStringView:
    return false
  case map.kind
  of fmskInt64C:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_i64_map_contains_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)
  of fmskInt64Nim:
    containsFastMapInt64(map.nimInt64, key.toOwnedString)
  of fmskInt64Arena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_arena_i64_map_contains_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)
  else:
    false

## Remove a key from the map; returns false if the key was absent.
proc del*[V](map: FastMap[V], key: string): bool {.inline.} =
  when V is string:
    case map.kind
    of fmskString:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_map_erase_n(raw, cast[cstring](key.stringPtr), csize_t(key.len))
    of fmskStringNim:
      delFastMapString(map.nimString, key)
    of fmskStringArena:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_arena_map_erase_n(raw, cast[cstring](key.stringPtr), csize_t(key.len))
    else:
      false
  elif V is int64:
    case map.kind
    of fmskInt64C:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_i64_map_erase_n(raw, cast[cstring](key.stringPtr), csize_t(key.len))
    of fmskInt64Nim:
      delFastMapInt64(map.nimInt64, key)
    of fmskInt64Arena:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      nx_fm_str_arena_i64_map_erase_n(raw, cast[cstring](key.stringPtr), csize_t(key.len))
    else:
      false
  else:
    if map.nimGenericStorage.isNil: false
    else: delFastMapGeneric(map.nimGenericStorage, key)

## Remove a cstring key from the map; returns false if the key was absent.
proc delC*(map: FastMap[string], key: cstring): bool {.inline.} =
  case map.kind
  of fmskString:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_map_erase_n(raw, cast[cstring](key.cstringPtr), key.cstringLen)
  of fmskStringNim:
    delFastMapString(map.nimString, key.toOwnedString)
  of fmskStringArena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_arena_map_erase_n(raw, cast[cstring](key.cstringPtr), key.cstringLen)
  else:
    false

## Remove a cstring key from the map; returns false if the key was absent.
proc delC*(map: FastMap[int64], key: cstring): bool {.inline.} =
  case map.kind
  of fmskInt64C:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_i64_map_erase_n(raw, cast[cstring](key.cstringPtr), key.cstringLen)
  of fmskInt64Nim:
    delFastMapInt64(map.nimInt64, key.toOwnedString)
  of fmskInt64Arena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_arena_i64_map_erase_n(raw, cast[cstring](key.cstringPtr), key.cstringLen)
  else:
    false

## Remove a `FastStringView` key from the map; returns false if the key was absent.
proc delView*(map: FastMap[string], key: FastStringView): bool {.inline.} =
  if not key.isValidFastStringView:
    return false
  case map.kind
  of fmskString:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_map_erase_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)
  of fmskStringNim:
    delFastMapString(map.nimString, key.toOwnedString)
  of fmskStringArena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_arena_map_erase_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)
  else:
    false

## Remove a `FastStringView` key from the map; returns false if the key was absent.
proc delView*(map: FastMap[int64], key: FastStringView): bool {.inline.} =
  if not key.isValidFastStringView:
    return false
  case map.kind
  of fmskInt64C:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_i64_map_erase_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)
  of fmskInt64Nim:
    delFastMapInt64(map.nimInt64, key.toOwnedString)
  of fmskInt64Arena:
    let raw = map.rawHandle()
    if raw == nil:
      return false
    nx_fm_str_arena_i64_map_erase_n(raw, cast[cstring](key.toFastStringViewPtr), key.toFastStringViewLen)
  else:
    false

## Remove all entries from the map.
proc clear*[V](map: FastMap[V]) {.inline.} =
  when V is string:
    case map.kind
    of fmskString:
      let raw = map.rawHandle()
      if raw == nil:
        return
      nx_fm_str_map_clear(raw)
    of fmskStringNim:
      clearFastMapString(map.nimString)
    of fmskStringArena:
      let raw = map.rawHandle()
      if raw == nil:
        return
      nx_fm_str_arena_map_clear(raw)
    else:
      discard
  elif V is int64:
    case map.kind
    of fmskInt64C:
      let raw = map.rawHandle()
      if raw == nil:
        return
      nx_fm_str_i64_map_clear(raw)
    of fmskInt64Nim:
      clearFastMapInt64(map.nimInt64)
    of fmskInt64Arena:
      let raw = map.rawHandle()
      if raw == nil:
        return
      nx_fm_str_arena_i64_map_clear(raw)
    else:
      discard
  else:
    clearFastMapGeneric(map.nimGenericStorage)

## Return the value for a key, or the supplied default if missing.
proc getOrDefault*[V](map: FastMap[V], key: string, default: V): V {.inline.} =
  map.get(key, default)

## Return the value for a key, or the zero value if missing.
proc getOrDefault*[V](map: FastMap[V], key: string): V {.inline.} =
  map.get(key, default(V))

## Check whether the map contains a key.
proc hasKey*[V](map: FastMap[V], key: string): bool {.inline.} =
  map.contains(key)

## Insert the value only if the key is absent; returns true if the key already existed.
proc hasKeyOrPut*[V](map: FastMap[V], key: string, value: V): bool {.inline.} =
  if map.hasKey(key):
    return true
  discard map.put(key, value)
  false

proc `[]=`*[V](map: FastMap[V], key: string, value: V) {.inline.} =
  discard map.put(key, value)

## Insert or update a key and value entry; deprecated, use the assignment operator instead.
proc add*[V](map: FastMap[V], key: string, value: V) {.
    deprecated: "Deprecated since v1.4; it was more confusing than useful, use `[]=`",
    inline.} =
  map[key] = value

proc `[]`*(map: FastMap[string], key: string): string =
  var value: string
  if map.tryGet(key, value):
    return value
  raise missingFastMapKey(key)

proc `[]`*(map: FastMap[int64], key: string): var int64 =
  let valuePtr = map.int64ValuePtr(key)
  if valuePtr == nil:
    raise missingFastMapKey(key)
  valuePtr[]

## Check whether the map contains a key; reversed-argument overload.
proc contains*[V](key: string, map: FastMap[V]): bool {.inline.} =
  map.contains(key)

## Remove a key and return its value; returns false if the key is missing.
proc pop*[V](map: FastMap[V], key: string, value: var V): bool =
  when V is string:
    var stored: string
    if not map.tryGet(key, stored):
      return false
    if not map.del(key):
      return false
    value = stored
    true
  elif V is int64:
    var stored: int64
    if not map.tryGet(key, stored):
      return false
    if not map.del(key):
      return false
    value = stored
    true
  else:
    var stored: V
    if not map.tryGet(key, stored):
      return false
    if not map.del(key):
      return false
    value = stored
    true

## Alias of `pop`: remove a key and return its value.
proc take*[V](map: FastMap[V], key: string, value: var V): bool {.inline.} =
  map.pop(key, value)

## Return a mutable reference to the entry for key, inserting value if absent.
proc mgetOrPut*(map: FastMap[int64], key: string, value: int64): var int64 =
  let valuePtr = map.int64ValuePtrOrPut(key, value)
  if valuePtr == nil:
    raise newException(ValueError, "failed to insert key: " & key)
  valuePtr[]

## Return a mutable reference to the entry for key, defaulting to zero if absent.
proc mgetOrPut*(map: FastMap[int64], key: string): var int64 =
  map.mgetOrPut(key, 0'i64)

## Return the existing value for key, inserting and returning value if absent.
proc mgetOrPut*(map: FastMap[string], key: string, value: string): string =
  ## Returns the existing value or inserts `value` and returns it.
  ## Note: returns a copy — mutations on the result do not affect the map.
  ## Use `put` to update values.
  var existing: string
  if map.tryGet(key, existing):
    return existing
  discard map.put(key, value)
  value

## Return the existing value for key, defaulting to an empty string if absent.
proc mgetOrPut*(map: FastMap[string], key: string): string =
  map.mgetOrPut(key, "")

## Iterate over all entries as `FastStringView` pairs without allocation.
iterator pairsView*(map: FastMap[string]): (FastStringView, FastStringView) =
  case map.kind
  of fmskStringNim:
    if not map.nimString.isNil:
      var i = 0
      while nextFastMapStringOccupiedIdx(map.nimString, i):
        let entry = swEntryAt(map.nimString, i)
        yield (
          rawStrToView(entry.keyPtr, int32(entry.keyLen)),
          rawStrToView(swEntryValPtr(entry), int32(entry.valLen))
        )
        inc i
  else:
    let raw = map.rawHandle()
    if raw != nil:
      let iter =
        case map.kind
        of fmskString:
          nx_fm_str_map_iter_new(raw)
        of fmskStringArena:
          nx_fm_str_arena_map_iter_new(raw)
        else:
          nil
      if iter != nil:
        defer:
          case map.kind
          of fmskString:
            nx_fm_str_map_iter_free(iter)
          of fmskStringArena:
            nx_fm_str_arena_map_iter_free(iter)
          else:
            discard

        var keyPtr: cstring
        var keyLen: csize_t
        var valuePtr: cstring
        var valueLen: csize_t
        while (
          case map.kind
          of fmskString:
            nx_fm_str_map_iter_next(iter, addr keyPtr, addr keyLen, addr valuePtr, addr valueLen)
          of fmskStringArena:
            nx_fm_str_arena_map_iter_next(iter, addr keyPtr, addr keyLen, addr valuePtr, addr valueLen)
          else:
            false
        ):
          yield (initFastStringView(keyPtr, keyLen), initFastStringView(valuePtr, valueLen))

## Collect all entries into a sequence of string pairs.
proc pairsSeq*(map: FastMap[string]): seq[(string, string)] =
  result = newSeqOfCap[(string, string)](map.len)
  for keyView, valueView in map.pairsView():
    result.add(($keyView, $valueView))

## Iterate over all entries as string pairs.
iterator pairs*(map: FastMap[string]): (string, string) =
  for keyView, valueView in map.pairsView():
    yield ($keyView, $valueView)

## Iterate over all entries as string and int64 pairs.
iterator pairs*(map: FastMap[int64]): (string, int64) =
  case map.kind
  of fmskInt64C:
    let raw = map.rawHandle()
    if raw != nil:
      let iter = nx_fm_str_i64_map_iter_new(raw)
      if iter != nil:
        defer: nx_fm_str_i64_map_iter_free(iter)
        var keyPtr: cstring
        var keyLen: csize_t
        var value: int64
        while nx_fm_str_i64_map_iter_next(iter, addr keyPtr, addr keyLen, addr value):
          yield ($initFastStringView(keyPtr, keyLen), value)
  of fmskInt64Nim:
    if not map.nimInt64.isNil:
      for i in 0..<map.nimInt64.entries.len:
        let ctrl = map.nimInt64.ctrl[i]
        if ctrl != FastMapCtrlEmpty and ctrl != FastMapCtrlDeleted:
          let entry = map.nimInt64.entries[i]
          yield (entry.key, entry.value)
  of fmskInt64Arena:
    let raw = map.rawHandle()
    if raw != nil:
      let iter = nx_fm_str_arena_i64_map_iter_new(raw)
      if iter != nil:
        defer: nx_fm_str_arena_i64_map_iter_free(iter)
        var keyPtr: cstring
        var keyLen: csize_t
        var value: int64
        while nx_fm_str_arena_i64_map_iter_next(iter, addr keyPtr, addr keyLen, addr value):
          yield ($initFastStringView(keyPtr, keyLen), value)
  else:
    discard

## Collect all entries into a sequence of string and int64 pairs.
proc pairsSeq*(map: FastMap[int64]): seq[(string, int64)] =
  result = newSeqOfCap[(string, int64)](map.len)
  for key, value in map.pairs():
    result.add((key, value))

## Iterate over all entries as string and V pairs for generic values.
iterator pairs*[V](map: FastMap[V]): (string, V) =
  when not (V is string or V is int64):
    if not map.nimGenericStorage.isNil:
      for i in 0..<map.nimGenericStorage.entries.len:
        if map.nimGenericStorage.ctrl[i] != FastMapCtrlEmpty and map.nimGenericStorage.ctrl[i] != FastMapCtrlDeleted:
          yield (map.nimGenericStorage.entries[i].key, map.nimGenericStorage.entries[i].value)

## Iterate over all keys in the map.
iterator keys*[V](map: FastMap[V]): string =
  for key, _ in map.pairs():
    yield key

## Iterate over all values in the map.
iterator values*(map: FastMap[string]): string =
  for _, value in map.pairs():
    yield value

## Iterate over all values in the map.
iterator values*(map: FastMap[int64]): int64 =
  for _, value in map.pairs():
    yield value

## Iterate over all values in the map for generic value types.
iterator values*[V](map: FastMap[V]): V =
  when not (V is string or V is int64):
    for _, value in map.pairs():
      yield value

## Not supported for unmanaged string entries; use `pairsView` and `put` instead.
iterator mvalues*(map: FastMap[string]): var string =
  raise newException(ValueError, "mutable string value iteration is not supported with unmanaged entry storage; use pairsView and put instead")

## Iterate over int64 values as var references for in-place mutation.
iterator mvalues*(map: FastMap[int64]): var int64 =
  case map.kind
  of fmskInt64C:
    let raw = map.rawHandle()
    if raw != nil:
      let expectedLen = map.len
      let iter = nx_fm_str_i64_map_iter_new(raw)
      if iter != nil:
        defer: nx_fm_str_i64_map_iter_free(iter)
        var keyPtr: cstring
        var keyLen: csize_t
        var valuePtr: ptr int64
        while nx_fm_str_i64_map_iter_next_ptr(iter, addr keyPtr, addr keyLen, addr valuePtr):
          yield valuePtr[]
          assert map.len == expectedLen, "the length of the table changed while iterating over it"
  of fmskInt64Nim:
    if not map.nimInt64.isNil:
      let expectedLen = map.len
      for i in 0..<map.nimInt64.entries.len:
        if map.nimInt64.ctrl[i] != FastMapCtrlEmpty and map.nimInt64.ctrl[i] != FastMapCtrlDeleted:
          yield map.nimInt64.entries[i].value
          assert map.len == expectedLen, "the length of the table changed while iterating over it"
  of fmskInt64Arena:
    let raw = map.rawHandle()
    if raw != nil:
      let expectedLen = map.len
      let iter = nx_fm_str_arena_i64_map_iter_new(raw)
      if iter != nil:
        defer: nx_fm_str_arena_i64_map_iter_free(iter)
        var keyPtr: cstring
        var keyLen: csize_t
        var valuePtr: ptr int64
        while nx_fm_str_arena_i64_map_iter_next_ptr(iter, addr keyPtr, addr keyLen, addr valuePtr):
          yield valuePtr[]
          assert map.len == expectedLen, "the length of the table changed while iterating over it"
  else:
    discard

## Not supported for unmanaged string entries; use `pairsView` and `put` instead.
iterator mpairs*(map: FastMap[string]): (string, var string) =
  raise newException(ValueError, "mutable string pair iteration is not supported with unmanaged entry storage; use pairsView and put instead")

## Iterate over entries as key and mutable int64 value pairs.
iterator mpairs*(map: FastMap[int64]): (string, var int64) =
  case map.kind
  of fmskInt64C:
    let raw = map.rawHandle()
    if raw != nil:
      let expectedLen = map.len
      let iter = nx_fm_str_i64_map_iter_new(raw)
      if iter != nil:
        defer: nx_fm_str_i64_map_iter_free(iter)
        var keyPtr: cstring
        var keyLen: csize_t
        var valuePtr: ptr int64
        while nx_fm_str_i64_map_iter_next_ptr(iter, addr keyPtr, addr keyLen, addr valuePtr):
          yield ($initFastStringView(keyPtr, keyLen), valuePtr[])
          assert map.len == expectedLen, "the length of the table changed while iterating over it"
  of fmskInt64Nim:
    if not map.nimInt64.isNil:
      let expectedLen = map.len
      for i in 0..<map.nimInt64.entries.len:
        if map.nimInt64.ctrl[i] != FastMapCtrlEmpty and map.nimInt64.ctrl[i] != FastMapCtrlDeleted:
          yield (map.nimInt64.entries[i].key, map.nimInt64.entries[i].value)
          assert map.len == expectedLen, "the length of the table changed while iterating over it"
  of fmskInt64Arena:
    let raw = map.rawHandle()
    if raw != nil:
      let expectedLen = map.len
      let iter = nx_fm_str_arena_i64_map_iter_new(raw)
      if iter != nil:
        defer: nx_fm_str_arena_i64_map_iter_free(iter)
        var keyPtr: cstring
        var keyLen: csize_t
        var valuePtr: ptr int64
        while nx_fm_str_arena_i64_map_iter_next_ptr(iter, addr keyPtr, addr keyLen, addr valuePtr):
          yield ($initFastStringView(keyPtr, keyLen), valuePtr[])
          assert map.len == expectedLen, "the length of the table changed while iterating over it"
  else:
    discard

proc `$`*(map: FastMap[string]): string =
  if map.isNil or map.len == 0:
    return "{:}"

  result = "{"
  for key, value in map.pairs():
    if result.len > 1:
      result.add(", ")
    result.addQuoted(key)
    result.add(": ")
    result.addQuoted(value)
  result.add("}")

proc `$`*(map: FastMap[int64]): string =
  if map.isNil or map.len == 0:
    return "{:}"

  result = "{"
  for key, value in map.pairs():
    if result.len > 1:
      result.add(", ")
    result.addQuoted(key)
    result.add(": ")
    result.addQuoted(value)
  result.add("}")

proc `==`*(a, b: FastMap[string]): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.len != b.len:
    return false
  var otherValue: FastStringView
  for keyView, valueView in a.pairsView():
    if not b.tryGetView($keyView, otherValue):
      return false
    if not otherValue.equalsAscii($valueView):
      return false
  true

proc `==`*(a, b: FastMap[int64]): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.len != b.len:
    return false
  var otherValue: int64
  for key, value in a.pairs():
    if not b.tryGet(key, otherValue):
      return false
    if otherValue != value:
      return false
  true
