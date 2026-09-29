#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct nim_simdjson_doc nim_simdjson_doc;

enum nim_simdjson_kind {
  NIM_SIMDJSON_NULL = 0,
  NIM_SIMDJSON_BOOL = 1,
  NIM_SIMDJSON_INT64 = 2,
  NIM_SIMDJSON_UINT64 = 3,
  NIM_SIMDJSON_DOUBLE = 4,
  NIM_SIMDJSON_STRING = 5,
  NIM_SIMDJSON_ARRAY = 6,
  NIM_SIMDJSON_OBJECT = 7
};

typedef struct nim_simdjson_project_entry {
  const char *key;
  size_t key_len;
  uint32_t status;
  int found_kind;
  const char *str_data;
  size_t str_len;
  bool bool_value;
  int64_t int64_value;
  uint64_t uint64_value;
  double double_value;
  size_t child_handle;
} nim_simdjson_project_entry;

typedef struct nim_simdjson_ondemand_value {
  uint32_t status;
  int found_kind;
  const char *data;
  size_t data_len;
  bool bool_value;
  int64_t int64_value;
  uint64_t uint64_value;
  double double_value;
} nim_simdjson_ondemand_value;

typedef struct nim_simdjson_ondemand_entry {
  const char *key;
  size_t key_len;
  uint32_t status;
  int found_kind;
  const char *data;
  size_t data_len;
  bool bool_value;
  int64_t int64_value;
  uint64_t uint64_value;
  double double_value;
} nim_simdjson_ondemand_entry;

typedef struct nim_simdjson_medium_todo_item {
  int64_t id;
  const char *title_data;
  size_t title_len;
  bool completed;
} nim_simdjson_medium_todo_item;

typedef struct nim_simdjson_medium_todo_envelope {
  uint32_t status;
  char *owned_json;
  size_t owned_json_len;
  nim_simdjson_medium_todo_item *todos;
  size_t todos_len;
  int64_t page;
  int64_t count;
  void *arena_state;
} nim_simdjson_medium_todo_envelope;

typedef struct nim_simdjson_nested_string_item {
  const char *data;
  size_t len;
} nim_simdjson_nested_string_item;

typedef struct nim_simdjson_nested_permission_item {
  const char *scope_data;
  size_t scope_len;
  bool allowed;
} nim_simdjson_nested_permission_item;

typedef struct nim_simdjson_nested_owner_item {
  int64_t id;
  const char *name_data;
  size_t name_len;
  nim_simdjson_nested_permission_item *permissions;
  size_t permissions_len;
} nim_simdjson_nested_owner_item;

typedef struct nim_simdjson_nested_comment_item {
  const char *author_data;
  size_t author_len;
  const char *message_data;
  size_t message_len;
  int64_t score;
} nim_simdjson_nested_comment_item;

typedef struct nim_simdjson_nested_task_item {
  int64_t id;
  const char *title_data;
  size_t title_len;
  bool completed;
  nim_simdjson_nested_string_item *tags;
  size_t tags_len;
  nim_simdjson_nested_comment_item *comments;
  size_t comments_len;
} nim_simdjson_nested_task_item;

typedef struct nim_simdjson_nested_project_stats {
  int64_t open_count;
  int64_t closed_count;
  double velocity;
} nim_simdjson_nested_project_stats;

typedef struct nim_simdjson_nested_project_item {
  int64_t project_id;
  const char *name_data;
  size_t name_len;
  bool active;
  nim_simdjson_nested_owner_item *owners;
  size_t owners_len;
  nim_simdjson_nested_task_item *tasks;
  size_t tasks_len;
  nim_simdjson_nested_project_stats stats;
} nim_simdjson_nested_project_item;

typedef struct nim_simdjson_nested_project_envelope {
  uint32_t status;
  nim_simdjson_nested_project_item *projects;
  size_t projects_len;
  int64_t page;
  int64_t count;
  void *arena_state;
} nim_simdjson_nested_project_envelope;

enum nim_simdjson_native_plan_kind {
  NIM_SIMDJSON_NATIVE_PLAN_UNSUPPORTED = 0,
  NIM_SIMDJSON_NATIVE_PLAN_OBJECT = 1,
  NIM_SIMDJSON_NATIVE_PLAN_SEQ_OBJECT = 2,
  NIM_SIMDJSON_NATIVE_PLAN_STRING = 3,
  NIM_SIMDJSON_NATIVE_PLAN_BOOL = 4,
  NIM_SIMDJSON_NATIVE_PLAN_SIGNED_INT = 5,
  NIM_SIMDJSON_NATIVE_PLAN_UNSIGNED_INT = 6,
  NIM_SIMDJSON_NATIVE_PLAN_FLOAT = 7
};

typedef struct nim_simdjson_native_plan_node {
  const char *name;
  size_t name_len;
  uint64_t name_hash;
  uint8_t first_char;
  int kind;
  size_t child_count;
  size_t subtree_size;
} nim_simdjson_native_plan_node;

typedef struct nim_simdjson_native_value nim_simdjson_native_value;

struct nim_simdjson_native_value {
  uint32_t status;
  int found_kind;
  const char *data;
  size_t data_len;
  bool bool_value;
  int64_t int64_value;
  uint64_t uint64_value;
  double double_value;
  nim_simdjson_native_value *children;
  size_t children_len;
  void *arena_state;
};

uint32_t nim_simdjson_parse(const char *data, size_t len, nim_simdjson_doc **out_doc);
bool nim_simdjson_is_valid(const char *data, size_t len);
void nim_simdjson_doc_free(nim_simdjson_doc *doc);
uint32_t nim_simdjson_doc_root(const nim_simdjson_doc *doc, size_t *out_handle);

uint32_t nim_simdjson_value_kind(const nim_simdjson_doc *doc, size_t handle, int *out_kind);
uint32_t nim_simdjson_value_len(const nim_simdjson_doc *doc, size_t handle, size_t *out_len);
uint32_t nim_simdjson_value_get_string(
  const nim_simdjson_doc *doc,
  size_t handle,
  char **out_data,
  size_t *out_len
);
uint32_t nim_simdjson_value_get_bool(const nim_simdjson_doc *doc, size_t handle, bool *out_value);
uint32_t nim_simdjson_value_get_int64(const nim_simdjson_doc *doc, size_t handle, int64_t *out_value);
uint32_t nim_simdjson_value_get_uint64(const nim_simdjson_doc *doc, size_t handle, uint64_t *out_value);
uint32_t nim_simdjson_value_get_double(const nim_simdjson_doc *doc, size_t handle, double *out_value);
uint32_t nim_simdjson_value_contains_key(
  const nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  bool *out_present
);
uint32_t nim_simdjson_value_key_kind(
  const nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  int *out_kind
);
uint32_t nim_simdjson_value_get_key(
  nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  size_t *out_child
);
uint32_t nim_simdjson_value_get_key_string(
  const nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  char **out_data,
  size_t *out_len
);
uint32_t nim_simdjson_value_get_key_bool(
  const nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  bool *out_value
);
uint32_t nim_simdjson_value_get_key_int64(
  const nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  int64_t *out_value
);
uint32_t nim_simdjson_value_get_key_uint64(
  const nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  uint64_t *out_value
);
uint32_t nim_simdjson_value_get_key_object(
  nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  size_t *out_child
);
uint32_t nim_simdjson_value_get_key_array(
  nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  size_t *out_child
);
uint32_t nim_simdjson_value_project(
  nim_simdjson_doc *doc,
  size_t handle,
  nim_simdjson_project_entry *entries,
  size_t count
);
uint32_t nim_simdjson_value_get_index(
  nim_simdjson_doc *doc,
  size_t handle,
  size_t index,
  size_t *out_child
);
uint32_t nim_simdjson_value_get_array_children(
  nim_simdjson_doc *doc,
  size_t handle,
  size_t *out_children,
  size_t count
);
uint32_t nim_simdjson_value_at_pointer(
  nim_simdjson_doc *doc,
  size_t handle,
  const char *pointer,
  size_t pointer_len,
  size_t *out_child
);

uint32_t nim_simdjson_ondemand_capture(
  const char *data,
  size_t len,
  nim_simdjson_ondemand_value *out_value
);
uint32_t nim_simdjson_ondemand_project_object(
  const char *data,
  size_t len,
  nim_simdjson_ondemand_entry *entries,
  size_t count
);
uint32_t nim_simdjson_ondemand_project_array_objects(
  const char *data,
  size_t len,
  nim_simdjson_ondemand_entry *entries,
  size_t item_count,
  size_t fields_per_item
);
uint32_t nim_simdjson_ondemand_array_length(
  const char *data,
  size_t len,
  size_t *out_len
);
uint32_t nim_simdjson_ondemand_capture_array(
  const char *data,
  size_t len,
  nim_simdjson_ondemand_value *items,
  size_t count
);
void nim_simdjson_ondemand_value_release(nim_simdjson_ondemand_value *value);
void nim_simdjson_ondemand_entry_release(nim_simdjson_ondemand_entry *entry);
void nim_simdjson_ondemand_entries_release(nim_simdjson_ondemand_entry *entries, size_t count);
void nim_simdjson_ondemand_values_release(nim_simdjson_ondemand_value *items, size_t count);

uint32_t nim_simdjson_extract_medium_todo_envelope(
  const char *data,
  size_t len,
  nim_simdjson_medium_todo_envelope *out_envelope
);
void nim_simdjson_medium_todo_envelope_release(nim_simdjson_medium_todo_envelope *envelope);
uint32_t nim_simdjson_extract_nested_project_envelope(
  const char *data,
  size_t len,
  nim_simdjson_nested_project_envelope *out_envelope
);
void nim_simdjson_nested_project_envelope_release(nim_simdjson_nested_project_envelope *envelope);
uint32_t nim_simdjson_extract_native_plan(
  const char *data,
  size_t len,
  const nim_simdjson_native_plan_node *plan,
  size_t plan_len,
  nim_simdjson_native_value *out_root
);
void nim_simdjson_native_value_release(nim_simdjson_native_value *value);

const char *nim_simdjson_error_message(uint32_t code);
uint32_t nim_simdjson_success_code(void);
uint32_t nim_simdjson_no_such_field_code(void);
uint32_t nim_simdjson_index_out_of_bounds_code(void);
uint32_t nim_simdjson_incorrect_type_code(void);

#ifdef __cplusplus
}
#endif
