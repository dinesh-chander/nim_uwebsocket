#include "simdjson_shim.h"

#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <string_view>
#include <utility>
#include <vector>

#include "vendor/simdjson.h"

struct nim_simdjson_doc {
  simdjson::dom::parser parser{};
  simdjson::dom::element root{};
  std::vector<simdjson::dom::element> values{};
};

struct nim_simdjson_arena;

// Reused per-call ondemand parser (amortizes internal tape allocation) and the
// caller-configured depth cap applied to fresh ondemand parses.
thread_local simdjson::ondemand::parser g_ondemand_scratch_parser{};
thread_local size_t g_ondemand_max_depth = static_cast<size_t>(simdjson::DEFAULT_MAX_DEPTH);

extern "C" uint32_t nim_simdjson_set_ondemand_max_depth(size_t limit) {
  g_ondemand_max_depth =
      limit == 0 ? static_cast<size_t>(simdjson::DEFAULT_MAX_DEPTH) : limit;
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

namespace {
// Force consumption of every token so lazy syntax errors surface. Cheaper than a
// DOM parse (no element materialization) and runs on the warm thread-local parser.
uint32_t validate_ondemand_value(simdjson::ondemand::value v);

uint32_t validate_ondemand_object(simdjson::ondemand::object object) {
  for (auto pair_result : object) {
    if (pair_result.error()) {
      return static_cast<uint32_t>(pair_result.error());
    }
    auto pair = pair_result.value_unsafe();
    (void)pair.key(); // consuming the key advances and validates the key token
    uint32_t error = validate_ondemand_value(pair.value());
    if (error != simdjson::SUCCESS) {
      return error;
    }
  }
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

uint32_t validate_ondemand_array(simdjson::ondemand::array array) {
  for (auto item_result : array) {
    if (item_result.error()) {
      return static_cast<uint32_t>(item_result.error());
    }
    uint32_t error = validate_ondemand_value(item_result.value_unsafe());
    if (error != simdjson::SUCCESS) {
      return error;
    }
  }
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

uint32_t validate_ondemand_value(simdjson::ondemand::value v) {
  auto type_result = v.type();
  if (type_result.error()) {
    return static_cast<uint32_t>(type_result.error());
  }
  auto type = type_result.value_unsafe();
  switch (type) {
    case simdjson::ondemand::json_type::object: {
      auto object_result = v.get_object();
      if (object_result.error()) {
        return static_cast<uint32_t>(object_result.error());
      }
      return validate_ondemand_object(object_result.value_unsafe());
    }
    case simdjson::ondemand::json_type::array: {
      auto array_result = v.get_array();
      if (array_result.error()) {
        return static_cast<uint32_t>(array_result.error());
      }
      return validate_ondemand_array(array_result.value_unsafe());
    }
    default: {
      // Scalar: `type()` above already validated the token; consume it.
      (void)v.raw_json_token();
      return static_cast<uint32_t>(simdjson::SUCCESS);
    }
  }
}
} // namespace

extern "C" uint32_t nim_simdjson_ondemand_validate(const char *data, size_t len) {
  if (data == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  simdjson::padded_string json(data, len);
  auto &parser = g_ondemand_scratch_parser;
  parser.set_max_depth(g_ondemand_max_depth);
  auto doc_result = parser.iterate(json);
  if (doc_result.error()) {
    return static_cast<uint32_t>(doc_result.error());
  }
  auto doc = std::move(doc_result.value_unsafe());
  auto object_result = doc.get_object();
  if (!object_result.error()) {
    return validate_ondemand_object(object_result.value_unsafe());
  }
  auto array_result = doc.get_array();
  if (!array_result.error()) {
    return validate_ondemand_array(array_result.value_unsafe());
  }
  // Scalar root: force token consumption so syntax errors surface.
  (void)doc.raw_json();
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

namespace {
constexpr size_t kDocPoolLimit = 32;

thread_local std::vector<nim_simdjson_doc *> g_doc_pool{};
thread_local simdjson::dom::parser g_validator_parser{};
thread_local simdjson::ondemand::parser g_typed_decode_parser{};
thread_local size_t g_ondemand_max_array_items = 0; // 0 = no limit

inline simdjson::ondemand::parser &typed_decode_parser() {
  g_typed_decode_parser.set_max_depth(g_ondemand_max_depth);
  return g_typed_decode_parser;
}

extern "C" uint32_t nim_simdjson_set_ondemand_max_array_items(size_t limit) {
  g_ondemand_max_array_items = limit;
  return static_cast<uint32_t>(simdjson::SUCCESS);
}
struct nim_simdjson_retained_ondemand_state {
  simdjson::padded_string padded;
  nim_simdjson_arena *native_arena;

  explicit nim_simdjson_retained_ondemand_state(const char *data, size_t len) noexcept;
  ~nim_simdjson_retained_ondemand_state();
};

void reset_doc(nim_simdjson_doc *doc) {
  if (doc == nullptr) {
    return;
  }
  doc->root = simdjson::dom::element{};
  doc->values.clear();
}

nim_simdjson_doc *acquire_doc() {
  if (!g_doc_pool.empty()) {
    auto *doc = g_doc_pool.back();
    g_doc_pool.pop_back();
    reset_doc(doc);
    return doc;
  }

  auto *doc = new (std::nothrow) nim_simdjson_doc();
  if (doc != nullptr) {
    try {
      doc->values.reserve(16);
    } catch (const std::bad_alloc &) {
    }
  }
  return doc;
}

void release_doc(nim_simdjson_doc *doc) {
  if (doc == nullptr) {
    return;
  }
  reset_doc(doc);
  if (g_doc_pool.size() < kDocPoolLimit) {
    g_doc_pool.push_back(doc);
  } else {
    delete doc;
  }
}

bool checked_size_mul(size_t left, size_t right, size_t *out) {
  if (out == nullptr) {
    return false;
  }
  if (right != 0 && left > std::numeric_limits<size_t>::max() / right) {
    return false;
  }
  *out = left * right;
  return true;
}

bool checked_size_add(size_t left, size_t right, size_t *out) {
  if (out == nullptr) {
    return false;
  }
  if (left > std::numeric_limits<size_t>::max() - right) {
    return false;
  }
  *out = left + right;
  return true;
}

bool next_capacity(size_t current, size_t initial, size_t item_size, size_t *out_capacity) {
  size_t candidate = current == 0 ? initial : current;
  if (current != 0) {
    if (candidate > std::numeric_limits<size_t>::max() / 2) {
      return false;
    }
    candidate *= 2;
  }
  size_t bytes = 0;
  if (!checked_size_mul(candidate, item_size, &bytes)) {
    return false;
  }
  *out_capacity = candidate;
  return true;
}
} // namespace

template <typename T>
static uint32_t append_dynamic_item(
  T **items,
  size_t *len,
  size_t *capacity,
  T **out_item
) {
  if (items == nullptr || len == nullptr || capacity == nullptr || out_item == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  if (*len == *capacity) {
    size_t grown_capacity = 0;
    if (!next_capacity(*capacity, 4, sizeof(T), &grown_capacity)) {
      return static_cast<uint32_t>(simdjson::MEMALLOC);
    }
    void *grown = std::realloc(*items, sizeof(T) * grown_capacity);
    if (grown == nullptr) {
      return static_cast<uint32_t>(simdjson::MEMALLOC);
    }
    *items = static_cast<T *>(grown);
    *capacity = grown_capacity;
  }
  *out_item = &(*items)[*len];
  **out_item = T{};
  ++(*len);
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

static uint32_t kind_for_element(simdjson::dom::element element, int *out_kind) {
  if (out_kind == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  switch (element.type()) {
  case simdjson::dom::element_type::NULL_VALUE:
    *out_kind = NIM_SIMDJSON_NULL;
    return static_cast<uint32_t>(simdjson::SUCCESS);
  case simdjson::dom::element_type::BOOL:
    *out_kind = NIM_SIMDJSON_BOOL;
    return static_cast<uint32_t>(simdjson::SUCCESS);
  case simdjson::dom::element_type::INT64:
    *out_kind = NIM_SIMDJSON_INT64;
    return static_cast<uint32_t>(simdjson::SUCCESS);
  case simdjson::dom::element_type::UINT64:
    *out_kind = NIM_SIMDJSON_UINT64;
    return static_cast<uint32_t>(simdjson::SUCCESS);
  case simdjson::dom::element_type::DOUBLE:
    *out_kind = NIM_SIMDJSON_DOUBLE;
    return static_cast<uint32_t>(simdjson::SUCCESS);
  case simdjson::dom::element_type::STRING:
    *out_kind = NIM_SIMDJSON_STRING;
    return static_cast<uint32_t>(simdjson::SUCCESS);
  case simdjson::dom::element_type::ARRAY:
    *out_kind = NIM_SIMDJSON_ARRAY;
    return static_cast<uint32_t>(simdjson::SUCCESS);
  case simdjson::dom::element_type::OBJECT:
    *out_kind = NIM_SIMDJSON_OBJECT;
    return static_cast<uint32_t>(simdjson::SUCCESS);
  default:
    return static_cast<uint32_t>(simdjson::INCORRECT_TYPE);
  }
}

static uint32_t get_element(
  const nim_simdjson_doc *doc,
  size_t handle,
  simdjson::dom::element *out_element
) {
  if (doc == nullptr || out_element == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  if (handle >= doc->values.size()) {
    return static_cast<uint32_t>(simdjson::INDEX_OUT_OF_BOUNDS);
  }
  *out_element = doc->values[handle];
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

static uint32_t store_element(
  nim_simdjson_doc *doc,
  simdjson::dom::element element,
  size_t *out_handle
) {
  if (doc == nullptr || out_handle == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  try {
    doc->values.push_back(element);
  } catch (const std::bad_alloc &) {
    return static_cast<uint32_t>(simdjson::MEMALLOC);
  }
  *out_handle = doc->values.size() - 1;
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

static uint32_t lookup_key(
  const nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  simdjson::dom::element *out_child
) {
  if (key == nullptr || out_child == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  simdjson::dom::element element;
  auto error = get_element(doc, handle, &element);
  if (error != simdjson::SUCCESS) {
    return error;
  }

  simdjson::dom::object object;
  auto object_error = element.get_object().get(object);
  if (object_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(object_error);
  }

  return static_cast<uint32_t>(object[std::string_view(key, key_len)].get(*out_child));
}

static void reset_project_entry(nim_simdjson_project_entry *entry) {
  entry->status = static_cast<uint32_t>(simdjson::SUCCESS);
  entry->found_kind = -1;
  entry->str_data = nullptr;
  entry->str_len = 0;
  entry->bool_value = false;
  entry->int64_value = 0;
  entry->uint64_value = 0;
  entry->double_value = 0.0;
  entry->child_handle = 0;
}

template <typename Entry>
static void populate_lookup_entry(
  nim_simdjson_doc *doc,
  const simdjson::dom::element &child,
  Entry *entry
) {
  auto kind_error = kind_for_element(child, &entry->found_kind);
  if (kind_error != simdjson::SUCCESS) {
    entry->status = kind_error;
    return;
  }

  switch (child.type()) {
  case simdjson::dom::element_type::NULL_VALUE:
    break;
  case simdjson::dom::element_type::BOOL: {
    auto value_error = child.get_bool().get(entry->bool_value);
    if (value_error != simdjson::SUCCESS) {
      entry->status = static_cast<uint32_t>(value_error);
    }
    break;
  }
  case simdjson::dom::element_type::INT64: {
    auto value_error = child.get_int64().get(entry->int64_value);
    if (value_error != simdjson::SUCCESS) {
      entry->status = static_cast<uint32_t>(value_error);
    }
    break;
  }
  case simdjson::dom::element_type::UINT64: {
    auto value_error = child.get_uint64().get(entry->uint64_value);
    if (value_error != simdjson::SUCCESS) {
      entry->status = static_cast<uint32_t>(value_error);
    }
    break;
  }
  case simdjson::dom::element_type::DOUBLE: {
    auto value_error = child.get_double().get(entry->double_value);
    if (value_error != simdjson::SUCCESS) {
      entry->status = static_cast<uint32_t>(value_error);
    }
    break;
  }
  case simdjson::dom::element_type::STRING: {
    std::string_view raw;
    auto value_error = child.get_string().get(raw);
    if (value_error != simdjson::SUCCESS) {
      entry->status = static_cast<uint32_t>(value_error);
    } else {
      entry->str_data = raw.data();
      entry->str_len = raw.size();
    }
    break;
  }
  case simdjson::dom::element_type::ARRAY:
  case simdjson::dom::element_type::OBJECT: {
    auto store_error = store_element(doc, child, &entry->child_handle);
    if (store_error != simdjson::SUCCESS) {
      entry->status = store_error;
    }
    break;
  }
  default:
    entry->status = static_cast<uint32_t>(simdjson::INCORRECT_TYPE);
    break;
  }
}

uint32_t nim_simdjson_parse(const char *data, size_t len, nim_simdjson_doc **out_doc) {
  if (out_doc == nullptr || data == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  *out_doc = nullptr;

  auto *doc = acquire_doc();
  if (doc == nullptr) {
    return static_cast<uint32_t>(simdjson::MEMALLOC);
  }

  auto error = doc->parser.parse(data, len, true).get(doc->root);
  if (error != simdjson::SUCCESS) {
    release_doc(doc);
    return static_cast<uint32_t>(error);
  }

  try {
    doc->values.clear();
    doc->values.push_back(doc->root);
  } catch (const std::bad_alloc &) {
    release_doc(doc);
    return static_cast<uint32_t>(simdjson::MEMALLOC);
  }

  *out_doc = doc;
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

bool nim_simdjson_is_valid(const char *data, size_t len) {
  if (data == nullptr) {
    return false;
  }
  simdjson::dom::element root;
  return g_validator_parser.parse(data, len, true).get(root) == simdjson::SUCCESS;
}

void nim_simdjson_doc_free(nim_simdjson_doc *doc) {
  release_doc(doc);
}

uint32_t nim_simdjson_doc_root(const nim_simdjson_doc *doc, size_t *out_handle) {
  if (doc == nullptr || out_handle == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  if (doc->values.empty()) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  *out_handle = 0;
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

uint32_t nim_simdjson_value_kind(const nim_simdjson_doc *doc, size_t handle, int *out_kind) {
  simdjson::dom::element element;
  auto error = get_element(doc, handle, &element);
  if (error != simdjson::SUCCESS) {
    return error;
  }
  return kind_for_element(element, out_kind);
}

uint32_t nim_simdjson_value_len(const nim_simdjson_doc *doc, size_t handle, size_t *out_len) {
  if (out_len == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  simdjson::dom::element element;
  auto error = get_element(doc, handle, &element);
  if (error != simdjson::SUCCESS) {
    return error;
  }

  switch (element.type()) {
  case simdjson::dom::element_type::ARRAY: {
    simdjson::dom::array array;
    auto array_error = element.get_array().get(array);
    if (array_error != simdjson::SUCCESS) {
      return static_cast<uint32_t>(array_error);
    }
    *out_len = array.size();
    return static_cast<uint32_t>(simdjson::SUCCESS);
  }
  case simdjson::dom::element_type::OBJECT: {
    simdjson::dom::object object;
    auto object_error = element.get_object().get(object);
    if (object_error != simdjson::SUCCESS) {
      return static_cast<uint32_t>(object_error);
    }
    *out_len = object.size();
    return static_cast<uint32_t>(simdjson::SUCCESS);
  }
  case simdjson::dom::element_type::STRING: {
    std::string_view raw;
    auto string_error = element.get_string().get(raw);
    if (string_error != simdjson::SUCCESS) {
      return static_cast<uint32_t>(string_error);
    }
    *out_len = raw.size();
    return static_cast<uint32_t>(simdjson::SUCCESS);
  }
  default:
    return static_cast<uint32_t>(simdjson::INCORRECT_TYPE);
  }
}

uint32_t nim_simdjson_value_get_string(
  const nim_simdjson_doc *doc,
  size_t handle,
  char **out_data,
  size_t *out_len
) {
  if (out_data == nullptr || out_len == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  simdjson::dom::element element;
  auto error = get_element(doc, handle, &element);
  if (error != simdjson::SUCCESS) {
    return error;
  }

  std::string_view raw;
  auto string_error = element.get_string().get(raw);
  if (string_error != simdjson::SUCCESS) {
    *out_data = nullptr;
    *out_len = 0;
    return static_cast<uint32_t>(string_error);
  }
  *out_data = const_cast<char*>(raw.data());
  *out_len = raw.size();
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

uint32_t nim_simdjson_value_get_bool(const nim_simdjson_doc *doc, size_t handle, bool *out_value) {
  if (out_value == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  simdjson::dom::element element;
  auto error = get_element(doc, handle, &element);
  if (error != simdjson::SUCCESS) {
    return error;
  }
  return static_cast<uint32_t>(element.get_bool().get(*out_value));
}

uint32_t nim_simdjson_value_get_int64(const nim_simdjson_doc *doc, size_t handle, int64_t *out_value) {
  if (out_value == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  simdjson::dom::element element;
  auto error = get_element(doc, handle, &element);
  if (error != simdjson::SUCCESS) {
    return error;
  }
  return static_cast<uint32_t>(element.get_int64().get(*out_value));
}

uint32_t nim_simdjson_value_get_uint64(const nim_simdjson_doc *doc, size_t handle, uint64_t *out_value) {
  if (out_value == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  simdjson::dom::element element;
  auto error = get_element(doc, handle, &element);
  if (error != simdjson::SUCCESS) {
    return error;
  }
  return static_cast<uint32_t>(element.get_uint64().get(*out_value));
}

uint32_t nim_simdjson_value_get_double(const nim_simdjson_doc *doc, size_t handle, double *out_value) {
  if (out_value == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  simdjson::dom::element element;
  auto error = get_element(doc, handle, &element);
  if (error != simdjson::SUCCESS) {
    return error;
  }
  return static_cast<uint32_t>(element.get_double().get(*out_value));
}

uint32_t nim_simdjson_value_contains_key(
  const nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  bool *out_present
) {
  if (out_present == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  simdjson::dom::element element;
  auto error = get_element(doc, handle, &element);
  if (error != simdjson::SUCCESS) {
    return error;
  }

  simdjson::dom::object object;
  auto object_error = element.get_object().get(object);
  if (object_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(object_error);
  }

  simdjson::dom::element child;
  auto lookup_error = object[std::string_view(key, key_len)].get(child);
  if (lookup_error == simdjson::NO_SUCH_FIELD) {
    *out_present = false;
    return static_cast<uint32_t>(simdjson::SUCCESS);
  }
  if (lookup_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(lookup_error);
  }

  *out_present = true;
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

uint32_t nim_simdjson_value_key_kind(
  const nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  int *out_kind
) {
  simdjson::dom::element child;
  auto error = lookup_key(doc, handle, key, key_len, &child);
  if (error != simdjson::SUCCESS) {
    return error;
  }
  return kind_for_element(child, out_kind);
}

uint32_t nim_simdjson_value_get_key(
  nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  size_t *out_child
) {
  simdjson::dom::element child;
  auto error = lookup_key(doc, handle, key, key_len, &child);
  if (error != simdjson::SUCCESS) {
    return error;
  }
  return store_element(doc, child, out_child);
}

uint32_t nim_simdjson_value_get_key_string(
  const nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  char **out_data,
  size_t *out_len
) {
  if (out_data == nullptr || out_len == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  simdjson::dom::element child;
  auto error = lookup_key(doc, handle, key, key_len, &child);
  if (error != simdjson::SUCCESS) {
    *out_data = nullptr;
    *out_len = 0;
    return error;
  }

  std::string_view raw;
  auto string_error = child.get_string().get(raw);
  if (string_error != simdjson::SUCCESS) {
    *out_data = nullptr;
    *out_len = 0;
    return static_cast<uint32_t>(string_error);
  }
  *out_data = const_cast<char*>(raw.data());
  *out_len = raw.size();
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

uint32_t nim_simdjson_value_get_key_bool(
  const nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  bool *out_value
) {
  if (out_value == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  simdjson::dom::element child;
  auto error = lookup_key(doc, handle, key, key_len, &child);
  if (error != simdjson::SUCCESS) {
    return error;
  }
  return static_cast<uint32_t>(child.get_bool().get(*out_value));
}

uint32_t nim_simdjson_value_get_key_int64(
  const nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  int64_t *out_value
) {
  if (out_value == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  simdjson::dom::element child;
  auto error = lookup_key(doc, handle, key, key_len, &child);
  if (error != simdjson::SUCCESS) {
    return error;
  }
  return static_cast<uint32_t>(child.get_int64().get(*out_value));
}

uint32_t nim_simdjson_value_get_key_uint64(
  const nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  uint64_t *out_value
) {
  if (out_value == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  simdjson::dom::element child;
  auto error = lookup_key(doc, handle, key, key_len, &child);
  if (error != simdjson::SUCCESS) {
    return error;
  }
  return static_cast<uint32_t>(child.get_uint64().get(*out_value));
}

uint32_t nim_simdjson_value_get_key_object(
  nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  size_t *out_child
) {
  if (out_child == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  simdjson::dom::element child;
  auto error = lookup_key(doc, handle, key, key_len, &child);
  if (error != simdjson::SUCCESS) {
    return error;
  }
  simdjson::dom::object object;
  auto object_error = child.get_object().get(object);
  if (object_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(object_error);
  }
  return store_element(doc, child, out_child);
}

uint32_t nim_simdjson_value_get_key_array(
  nim_simdjson_doc *doc,
  size_t handle,
  const char *key,
  size_t key_len,
  size_t *out_child
) {
  if (out_child == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  simdjson::dom::element child;
  auto error = lookup_key(doc, handle, key, key_len, &child);
  if (error != simdjson::SUCCESS) {
    return error;
  }
  simdjson::dom::array array;
  auto array_error = child.get_array().get(array);
  if (array_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(array_error);
  }
  return store_element(doc, child, out_child);
}

uint32_t nim_simdjson_value_project(
  nim_simdjson_doc *doc,
  size_t handle,
  nim_simdjson_project_entry *entries,
  size_t count
) {
  if (doc == nullptr || (count > 0 && entries == nullptr)) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  simdjson::dom::element element;
  auto error = get_element(doc, handle, &element);
  if (error != simdjson::SUCCESS) {
    return error;
  }

  simdjson::dom::object object;
  auto object_error = element.get_object().get(object);
  if (object_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(object_error);
  }

  for (size_t i = 0; i < count; ++i) {
    auto *entry = &entries[i];
    reset_project_entry(entry);
    entry->status = entry->key == nullptr
      ? static_cast<uint32_t>(simdjson::TAPE_ERROR)
      : static_cast<uint32_t>(simdjson::NO_SUCH_FIELD);
  }

  size_t remaining = count;
  for (auto it = object.begin(); it != object.end() && remaining > 0; ++it) {
    std::string_view key = it.key();
    simdjson::dom::element child = it.value();

    for (size_t i = 0; i < count; ++i) {
      auto *entry = &entries[i];
      if (entry->status != static_cast<uint32_t>(simdjson::NO_SUCH_FIELD)) {
        continue;
      }
      if (entry->key_len != key.size()) {
        continue;
      }
      if (std::memcmp(entry->key, key.data(), key.size()) != 0) {
        continue;
      }

      entry->status = static_cast<uint32_t>(simdjson::SUCCESS);
      populate_lookup_entry(doc, child, entry);
      --remaining;
      break;
    }
  }

  return static_cast<uint32_t>(simdjson::SUCCESS);
}

uint32_t nim_simdjson_value_get_index(
  nim_simdjson_doc *doc,
  size_t handle,
  size_t index,
  size_t *out_child
) {
  simdjson::dom::element element;
  auto error = get_element(doc, handle, &element);
  if (error != simdjson::SUCCESS) {
    return error;
  }

  simdjson::dom::element child;
  error = element.at(index).get(child);
  if (error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(error);
  }
  return store_element(doc, child, out_child);
}

uint32_t nim_simdjson_value_get_array_children(
  nim_simdjson_doc *doc,
  size_t handle,
  size_t *out_children,
  size_t count
) {
  if (doc == nullptr || out_children == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  simdjson::dom::element element;
  auto error = get_element(doc, handle, &element);
  if (error != simdjson::SUCCESS) {
    return error;
  }

  simdjson::dom::array array;
  auto array_error = element.get_array().get(array);
  if (array_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(array_error);
  }

  try {
    doc->values.reserve(doc->values.size() + count);
  } catch (const std::bad_alloc &) {
    return static_cast<uint32_t>(simdjson::MEMALLOC);
  }

  size_t i = 0;
  for (simdjson::dom::element child : array) {
    if (i >= count) {
      return static_cast<uint32_t>(simdjson::INDEX_OUT_OF_BOUNDS);
    }
    error = store_element(doc, child, &out_children[i]);
    if (error != simdjson::SUCCESS) {
      return error;
    }
    ++i;
  }

  if (i != count) {
    return static_cast<uint32_t>(simdjson::INDEX_OUT_OF_BOUNDS);
  }
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

uint32_t nim_simdjson_value_at_pointer(
  nim_simdjson_doc *doc,
  size_t handle,
  const char *pointer,
  size_t pointer_len,
  size_t *out_child
) {
  if (pointer == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  simdjson::dom::element element;
  auto error = get_element(doc, handle, &element);
  if (error != simdjson::SUCCESS) {
    return error;
  }

  simdjson::dom::element child;
  error = element.at_pointer(std::string_view(pointer, pointer_len)).get(child);
  if (error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(error);
  }
  return store_element(doc, child, out_child);
}

static void reset_ondemand_value(nim_simdjson_ondemand_value *value) {
  if (value == nullptr) {
    return;
  }
  value->status = static_cast<uint32_t>(simdjson::SUCCESS);
  value->found_kind = -1;
  value->data = nullptr;
  value->data_len = 0;
  value->bool_value = false;
  value->int64_value = 0;
  value->uint64_value = 0;
  value->double_value = 0.0;
}

static void reset_ondemand_entry(nim_simdjson_ondemand_entry *entry) {
  if (entry == nullptr) {
    return;
  }
  entry->status = static_cast<uint32_t>(simdjson::NO_SUCH_FIELD);
  entry->found_kind = -1;
  entry->data = nullptr;
  entry->data_len = 0;
  entry->bool_value = false;
  entry->int64_value = 0;
  entry->uint64_value = 0;
  entry->double_value = 0.0;
}

static const char *copy_owned_bytes(std::string_view raw, size_t *out_len) {
  if (out_len == nullptr) {
    return nullptr;
  }
  *out_len = raw.size();
  if (raw.empty()) {
    return nullptr;
  }
  auto *buffer = static_cast<char *>(std::malloc(raw.size()));
  if (buffer == nullptr) {
    *out_len = 0;
    return nullptr;
  }
  std::memcpy(buffer, raw.data(), raw.size());
  return buffer;
}

struct nim_simdjson_arena_block {
  nim_simdjson_arena_block *next;
  size_t capacity;
  size_t used;
  char data[1];
};

struct nim_simdjson_arena {
  nim_simdjson_arena_block *head;
  nim_simdjson_arena_block *tail;
};

static void arena_init(nim_simdjson_arena *arena) {
  if (arena == nullptr) {
    return;
  }
  arena->head = nullptr;
  arena->tail = nullptr;
}

static void arena_release(nim_simdjson_arena *arena) {
  if (arena == nullptr) {
    return;
  }
  auto *block = arena->head;
  while (block != nullptr) {
    auto *next = block->next;
    std::free(block);
    block = next;
  }
  arena->head = nullptr;
  arena->tail = nullptr;
}

static char *arena_alloc(nim_simdjson_arena *arena, size_t len) {
  if (arena == nullptr || len == 0) {
    return nullptr;
  }
  auto *tail = arena->tail;
  size_t required = 0;
  bool needs_block = tail == nullptr ||
    !checked_size_add(tail->used, len, &required) ||
    required > tail->capacity;
  if (needs_block) {
    size_t capacity = len < 4096 ? 4096 : len;
    size_t alloc_size = 0;
    if (!checked_size_add(sizeof(nim_simdjson_arena_block), capacity - 1, &alloc_size)) {
      return nullptr;
    }
    auto *block = static_cast<nim_simdjson_arena_block *>(
      std::malloc(alloc_size)
    );
    if (block == nullptr) {
      return nullptr;
    }
    block->next = nullptr;
    block->capacity = capacity;
    block->used = 0;
    if (arena->tail != nullptr) {
      arena->tail->next = block;
    } else {
      arena->head = block;
    }
    arena->tail = block;
    tail = block;
  }
  char *buffer = tail->data + tail->used;
  if (!checked_size_add(tail->used, len, &tail->used)) {
    return nullptr;
  }
  return buffer;
}

nim_simdjson_retained_ondemand_state::nim_simdjson_retained_ondemand_state(
  const char *data,
  size_t len
) noexcept
  : padded(data, len), native_arena(new (std::nothrow) nim_simdjson_arena()) {
  if (native_arena != nullptr) {
    arena_init(native_arena);
  }
}

nim_simdjson_retained_ondemand_state::~nim_simdjson_retained_ondemand_state() {
  if (native_arena != nullptr) {
    arena_release(native_arena);
    delete native_arena;
    native_arena = nullptr;
  }
}

static const char *copy_arena_bytes(nim_simdjson_arena *arena, std::string_view raw, size_t *out_len) {
  if (out_len == nullptr) {
    return nullptr;
  }
  *out_len = raw.size();
  if (raw.empty()) {
    return nullptr;
  }
  char *buffer = arena_alloc(arena, raw.size());
  if (buffer == nullptr) {
    *out_len = 0;
    return nullptr;
  }
  std::memcpy(buffer, raw.data(), raw.size());
  return buffer;
}

static void assign_view_bytes(std::string_view raw, const char **out_data, size_t *out_len) {
  if (out_data == nullptr || out_len == nullptr) {
    return;
  }
  *out_data = raw.empty() ? nullptr : raw.data();
  *out_len = raw.size();
}

static void reset_medium_todo_envelope(nim_simdjson_medium_todo_envelope *envelope) {
  if (envelope == nullptr) {
    return;
  }
  envelope->status = static_cast<uint32_t>(simdjson::SUCCESS);
  envelope->owned_json = nullptr;
  envelope->owned_json_len = 0;
  envelope->todos = nullptr;
  envelope->todos_len = 0;
  envelope->page = 0;
  envelope->count = 0;
  envelope->arena_state = nullptr;
}

static void release_medium_todo_envelope(nim_simdjson_medium_todo_envelope *envelope) {
  if (envelope == nullptr) {
    return;
  }
  if (envelope->todos != nullptr) {
    std::free(envelope->todos);
  }
  if (envelope->arena_state != nullptr) {
    auto *state = static_cast<nim_simdjson_retained_ondemand_state *>(envelope->arena_state);
    delete state;
  }
  std::free(envelope->owned_json);
  reset_medium_todo_envelope(envelope);
}

static void reset_nested_project_envelope(nim_simdjson_nested_project_envelope *envelope) {
  if (envelope == nullptr) {
    return;
  }
  envelope->status = static_cast<uint32_t>(simdjson::SUCCESS);
  envelope->projects = nullptr;
  envelope->projects_len = 0;
  envelope->page = 0;
  envelope->count = 0;
  envelope->arena_state = nullptr;
}

static void release_nested_string_item(nim_simdjson_nested_string_item *item) {
  if (item == nullptr) {
    return;
  }
  item->data = nullptr;
  item->len = 0;
}

static void release_nested_permission_item(nim_simdjson_nested_permission_item *item) {
  if (item == nullptr) {
    return;
  }
  item->scope_data = nullptr;
  item->scope_len = 0;
  item->allowed = false;
}

static void release_nested_owner_item(nim_simdjson_nested_owner_item *item) {
  if (item == nullptr) {
    return;
  }
  item->name_data = nullptr;
  item->name_len = 0;
  if (item->permissions != nullptr) {
    for (size_t i = 0; i < item->permissions_len; ++i) {
      release_nested_permission_item(&item->permissions[i]);
    }
    std::free(item->permissions);
  }
  item->permissions = nullptr;
  item->permissions_len = 0;
  item->id = 0;
}

static void release_nested_comment_item(nim_simdjson_nested_comment_item *item) {
  if (item == nullptr) {
    return;
  }
  item->author_data = nullptr;
  item->author_len = 0;
  item->message_data = nullptr;
  item->message_len = 0;
  item->score = 0;
}

static void release_nested_task_item(nim_simdjson_nested_task_item *item) {
  if (item == nullptr) {
    return;
  }
  item->title_data = nullptr;
  item->title_len = 0;
  if (item->tags != nullptr) {
    for (size_t i = 0; i < item->tags_len; ++i) {
      release_nested_string_item(&item->tags[i]);
    }
    std::free(item->tags);
  }
  if (item->comments != nullptr) {
    for (size_t i = 0; i < item->comments_len; ++i) {
      release_nested_comment_item(&item->comments[i]);
    }
    std::free(item->comments);
  }
  item->tags = nullptr;
  item->tags_len = 0;
  item->comments = nullptr;
  item->comments_len = 0;
  item->id = 0;
  item->completed = false;
}

static void release_nested_project_item(nim_simdjson_nested_project_item *item) {
  if (item == nullptr) {
    return;
  }
  item->name_data = nullptr;
  item->name_len = 0;
  if (item->owners != nullptr) {
    for (size_t i = 0; i < item->owners_len; ++i) {
      release_nested_owner_item(&item->owners[i]);
    }
    std::free(item->owners);
  }
  if (item->tasks != nullptr) {
    for (size_t i = 0; i < item->tasks_len; ++i) {
      release_nested_task_item(&item->tasks[i]);
    }
    std::free(item->tasks);
  }
  item->owners = nullptr;
  item->owners_len = 0;
  item->tasks = nullptr;
  item->tasks_len = 0;
  item->project_id = 0;
  item->active = false;
  item->stats.open_count = 0;
  item->stats.closed_count = 0;
  item->stats.velocity = 0.0;
}

static void release_nested_project_envelope(nim_simdjson_nested_project_envelope *envelope) {
  if (envelope == nullptr) {
    return;
  }
  if (envelope->projects != nullptr) {
    for (size_t i = 0; i < envelope->projects_len; ++i) {
      release_nested_project_item(&envelope->projects[i]);
    }
    std::free(envelope->projects);
  }
  if (envelope->arena_state != nullptr) {
    auto *state = static_cast<nim_simdjson_retained_ondemand_state *>(envelope->arena_state);
    delete state;
  }
  reset_nested_project_envelope(envelope);
}

static uint32_t extract_nested_permission(
  simdjson::ondemand::object permission,
  nim_simdjson_nested_permission_item *out_item
) {
  if (out_item == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  out_item->scope_data = nullptr;
  out_item->scope_len = 0;
  out_item->allowed = false;
  std::string_view scope;
  auto scope_error = permission["scope"].get_string().get(scope);
  if (scope_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(scope_error);
  }
  auto allowed_error = permission["allowed"].get_bool().get(out_item->allowed);
  if (allowed_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(allowed_error);
  }
  assign_view_bytes(scope, &out_item->scope_data, &out_item->scope_len);
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

static uint32_t extract_nested_comment(
  simdjson::ondemand::object comment,
  nim_simdjson_nested_comment_item *out_item
) {
  if (out_item == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  out_item->author_data = nullptr;
  out_item->author_len = 0;
  out_item->message_data = nullptr;
  out_item->message_len = 0;
  out_item->score = 0;
  std::string_view author;
  std::string_view message;
  auto author_error = comment["author"].get_string().get(author);
  if (author_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(author_error);
  }
  auto message_error = comment["message"].get_string().get(message);
  if (message_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(message_error);
  }
  auto score_error = comment["score"].get_int64().get(out_item->score);
  if (score_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(score_error);
  }
  assign_view_bytes(author, &out_item->author_data, &out_item->author_len);
  assign_view_bytes(message, &out_item->message_data, &out_item->message_len);
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

static uint32_t extract_nested_owner(
  simdjson::ondemand::object owner,
  nim_simdjson_nested_owner_item *out_item
) {
  if (out_item == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  out_item->id = 0;
  out_item->name_data = nullptr;
  out_item->name_len = 0;
  out_item->permissions = nullptr;
  out_item->permissions_len = 0;

  std::string_view name;
  auto id_error = owner["id"].get_int64().get(out_item->id);
  if (id_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(id_error);
  }
  auto name_error = owner["name"].get_string().get(name);
  if (name_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(name_error);
  }
  assign_view_bytes(name, &out_item->name_data, &out_item->name_len);

  simdjson::ondemand::array permissions;
  auto permissions_error = owner["permissions"].get_array().get(permissions);
  if (permissions_error != simdjson::SUCCESS) {
    release_nested_owner_item(out_item);
    return static_cast<uint32_t>(permissions_error);
  }

  size_t permissions_capacity = 0;
  for (auto permission_value : permissions) {
    simdjson::ondemand::object permission;
    auto permission_error = permission_value.get_object().get(permission);
    if (permission_error != simdjson::SUCCESS) {
      release_nested_owner_item(out_item);
      return static_cast<uint32_t>(permission_error);
    }
    nim_simdjson_nested_permission_item *slot = nullptr;
    auto append_error = append_dynamic_item(
      &out_item->permissions,
      &out_item->permissions_len,
      &permissions_capacity,
      &slot
    );
    if (append_error != simdjson::SUCCESS) {
      release_nested_owner_item(out_item);
      return append_error;
    }
    auto error = extract_nested_permission(permission, slot);
    if (error != simdjson::SUCCESS) {
      release_nested_owner_item(out_item);
      return error;
    }
  }
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

static uint32_t extract_nested_task(
  simdjson::ondemand::object task,
  nim_simdjson_nested_task_item *out_item
) {
  if (out_item == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  out_item->id = 0;
  out_item->title_data = nullptr;
  out_item->title_len = 0;
  out_item->completed = false;
  out_item->tags = nullptr;
  out_item->tags_len = 0;
  out_item->comments = nullptr;
  out_item->comments_len = 0;

  std::string_view title;
  auto id_error = task["id"].get_int64().get(out_item->id);
  if (id_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(id_error);
  }
  auto title_error = task["title"].get_string().get(title);
  if (title_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(title_error);
  }
  auto completed_error = task["completed"].get_bool().get(out_item->completed);
  if (completed_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(completed_error);
  }
  assign_view_bytes(title, &out_item->title_data, &out_item->title_len);

  simdjson::ondemand::array tags;
  auto tags_error = task["tags"].get_array().get(tags);
  if (tags_error != simdjson::SUCCESS) {
    release_nested_task_item(out_item);
    return static_cast<uint32_t>(tags_error);
  }
  size_t tags_capacity = 0;
  for (auto tag_value : tags) {
    std::string_view raw_tag;
    auto tag_error = tag_value.get_string().get(raw_tag);
    if (tag_error != simdjson::SUCCESS) {
      release_nested_task_item(out_item);
      return static_cast<uint32_t>(tag_error);
    }
    nim_simdjson_nested_string_item *slot = nullptr;
    auto append_error = append_dynamic_item(
      &out_item->tags,
      &out_item->tags_len,
      &tags_capacity,
      &slot
    );
    if (append_error != simdjson::SUCCESS) {
      release_nested_task_item(out_item);
      return append_error;
    }
    assign_view_bytes(raw_tag, &slot->data, &slot->len);
  }

  simdjson::ondemand::array comments;
  auto comments_error = task["comments"].get_array().get(comments);
  if (comments_error != simdjson::SUCCESS) {
    release_nested_task_item(out_item);
    return static_cast<uint32_t>(comments_error);
  }
  size_t comments_capacity = 0;
  for (auto comment_value : comments) {
    simdjson::ondemand::object comment;
    auto comment_error = comment_value.get_object().get(comment);
    if (comment_error != simdjson::SUCCESS) {
      release_nested_task_item(out_item);
      return static_cast<uint32_t>(comment_error);
    }
    nim_simdjson_nested_comment_item *slot = nullptr;
    auto append_error = append_dynamic_item(
      &out_item->comments,
      &out_item->comments_len,
      &comments_capacity,
      &slot
    );
    if (append_error != simdjson::SUCCESS) {
      release_nested_task_item(out_item);
      return append_error;
    }
    auto error = extract_nested_comment(comment, slot);
    if (error != simdjson::SUCCESS) {
      release_nested_task_item(out_item);
      return error;
    }
  }

  return static_cast<uint32_t>(simdjson::SUCCESS);
}

static uint32_t extract_nested_project(
  simdjson::ondemand::object project,
  nim_simdjson_nested_project_item *out_item,
  size_t *max_depth_out
) {
  if (out_item == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  out_item->project_id = 0;
  out_item->name_data = nullptr;
  out_item->name_len = 0;
  out_item->active = false;
  out_item->owners = nullptr;
  out_item->owners_len = 0;
  out_item->tasks = nullptr;
  out_item->tasks_len = 0;
  out_item->stats.open_count = 0;
  out_item->stats.closed_count = 0;
  out_item->stats.velocity = 0.0;

  std::string_view name;
  auto id_error = project["projectId"].get_int64().get(out_item->project_id);
  if (id_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(id_error);
  }
  auto name_error = project["name"].get_string().get(name);
  if (name_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(name_error);
  }
  auto active_error = project["active"].get_bool().get(out_item->active);
  if (active_error != simdjson::SUCCESS) {
    return static_cast<uint32_t>(active_error);
  }
  assign_view_bytes(name, &out_item->name_data, &out_item->name_len);

  simdjson::ondemand::array owners;
  auto owners_error = project["owners"].get_array().get(owners);
  if (owners_error != simdjson::SUCCESS) {
    release_nested_project_item(out_item);
    return static_cast<uint32_t>(owners_error);
  }
  size_t owners_capacity = 0;
  if (max_depth_out != nullptr) { *max_depth_out = 4; }
  for (auto owner_value : owners) {
    if (max_depth_out != nullptr) { *max_depth_out = 5; }
    simdjson::ondemand::object owner;
    auto owner_error = owner_value.get_object().get(owner);
    if (owner_error != simdjson::SUCCESS) {
      release_nested_project_item(out_item);
      return static_cast<uint32_t>(owner_error);
    }
    nim_simdjson_nested_owner_item *slot = nullptr;
    auto append_error = append_dynamic_item(
      &out_item->owners,
      &out_item->owners_len,
      &owners_capacity,
      &slot
    );
    if (append_error != simdjson::SUCCESS) {
      release_nested_project_item(out_item);
      return append_error;
    }
    auto error = extract_nested_owner(owner, slot);
    if (error != simdjson::SUCCESS) {
      release_nested_project_item(out_item);
      return error;
    }
  }

  simdjson::ondemand::array tasks;
  auto tasks_error = project["tasks"].get_array().get(tasks);
  if (tasks_error != simdjson::SUCCESS) {
    release_nested_project_item(out_item);
    return static_cast<uint32_t>(tasks_error);
  }
  size_t tasks_capacity = 0;
  for (auto task_value : tasks) {
    simdjson::ondemand::object task;
    auto task_error = task_value.get_object().get(task);
    if (task_error != simdjson::SUCCESS) {
      release_nested_project_item(out_item);
      return static_cast<uint32_t>(task_error);
    }
    nim_simdjson_nested_task_item *slot = nullptr;
    auto append_error = append_dynamic_item(
      &out_item->tasks,
      &out_item->tasks_len,
      &tasks_capacity,
      &slot
    );
    if (append_error != simdjson::SUCCESS) {
      release_nested_project_item(out_item);
      return append_error;
    }
    auto error = extract_nested_task(task, slot);
    if (error != simdjson::SUCCESS) {
      release_nested_project_item(out_item);
      return error;
    }
  }

  simdjson::ondemand::object stats;
  auto stats_error = project["stats"].get_object().get(stats);
  if (stats_error != simdjson::SUCCESS) {
    release_nested_project_item(out_item);
    return static_cast<uint32_t>(stats_error);
  }
  auto open_error = stats["openCount"].get_int64().get(out_item->stats.open_count);
  auto closed_error = stats["closedCount"].get_int64().get(out_item->stats.closed_count);
  auto velocity_error = stats["velocity"].get_double().get(out_item->stats.velocity);
  if (open_error != simdjson::SUCCESS) {
    release_nested_project_item(out_item);
    return static_cast<uint32_t>(open_error);
  }
  if (closed_error != simdjson::SUCCESS) {
    release_nested_project_item(out_item);
    return static_cast<uint32_t>(closed_error);
  }
  if (velocity_error != simdjson::SUCCESS) {
    release_nested_project_item(out_item);
    return static_cast<uint32_t>(velocity_error);
  }

  return static_cast<uint32_t>(simdjson::SUCCESS);
}

static void reset_native_value(nim_simdjson_native_value *value) {
  if (value == nullptr) {
    return;
  }
  value->status = static_cast<uint32_t>(simdjson::NO_SUCH_FIELD);
  value->found_kind = -1;
  value->data = nullptr;
  value->data_len = 0;
  value->bool_value = false;
  value->int64_value = 0;
  value->uint64_value = 0;
  value->double_value = 0.0;
  value->children = nullptr;
  value->children_len = 0;
  value->arena_state = nullptr;
}

static void release_native_value(nim_simdjson_native_value *value, bool free_string_data = true) {
  if (value == nullptr) {
    return;
  }
  auto *state = static_cast<nim_simdjson_retained_ondemand_state *>(value->arena_state);
  bool owns_heap = free_string_data && state == nullptr;
  if (value->children != nullptr) {
    for (size_t i = 0; i < value->children_len; ++i) {
      release_native_value(&value->children[i], owns_heap);
    }
    if (owns_heap) {
      std::free(value->children);
    }
  }
  if (owns_heap) {
    std::free(const_cast<char *>(value->data));
  }
  if (state != nullptr) {
    delete state;
  }
  reset_native_value(value);
}

static uint64_t native_key_hash(std::string_view key) {
  uint64_t result = 1469598103934665603ULL;
  for (unsigned char ch : key) {
    result ^= static_cast<uint64_t>(ch);
    result *= 1099511628211ULL;
  }
  return result;
}

static bool native_key_matches(
  const nim_simdjson_native_plan_node &node,
  std::string_view key
) {
  if (node.name == nullptr || node.name_len != key.size()) {
    return false;
  }
  if (node.name_len > 0 && static_cast<unsigned char>(node.first_char) != static_cast<unsigned char>(key.front())) {
    return false;
  }
  if (node.name_hash != native_key_hash(key)) {
    return false;
  }
  return std::memcmp(node.name, key.data(), key.size()) == 0;
}

static uint32_t capture_native_number(
  simdjson::ondemand::value value,
  int plan_kind,
  nim_simdjson_native_value *out_value
) {
  int64_t raw_int;
  uint64_t raw_uint;
  double raw_double;
  switch (plan_kind) {
    case NIM_SIMDJSON_NATIVE_PLAN_SIGNED_INT:
      if (value.get_int64().get(raw_int) == simdjson::SUCCESS) {
        out_value->found_kind = NIM_SIMDJSON_INT64;
        out_value->int64_value = raw_int;
        out_value->status = static_cast<uint32_t>(simdjson::SUCCESS);
        return static_cast<uint32_t>(simdjson::SUCCESS);
      }
      if (value.get_uint64().get(raw_uint) == simdjson::SUCCESS) {
        out_value->found_kind = NIM_SIMDJSON_UINT64;
        out_value->uint64_value = raw_uint;
        out_value->status = static_cast<uint32_t>(simdjson::SUCCESS);
        return static_cast<uint32_t>(simdjson::SUCCESS);
      }
      break;
    case NIM_SIMDJSON_NATIVE_PLAN_UNSIGNED_INT:
      if (value.get_uint64().get(raw_uint) == simdjson::SUCCESS) {
        out_value->found_kind = NIM_SIMDJSON_UINT64;
        out_value->uint64_value = raw_uint;
        out_value->status = static_cast<uint32_t>(simdjson::SUCCESS);
        return static_cast<uint32_t>(simdjson::SUCCESS);
      }
      if (value.get_int64().get(raw_int) == simdjson::SUCCESS) {
        out_value->found_kind = NIM_SIMDJSON_INT64;
        out_value->int64_value = raw_int;
        out_value->status = static_cast<uint32_t>(simdjson::SUCCESS);
        return static_cast<uint32_t>(simdjson::SUCCESS);
      }
      break;
    case NIM_SIMDJSON_NATIVE_PLAN_FLOAT:
      if (value.get_double().get(raw_double) == simdjson::SUCCESS) {
        out_value->found_kind = NIM_SIMDJSON_DOUBLE;
        out_value->double_value = raw_double;
        out_value->status = static_cast<uint32_t>(simdjson::SUCCESS);
        return static_cast<uint32_t>(simdjson::SUCCESS);
      }
      if (value.get_int64().get(raw_int) == simdjson::SUCCESS) {
        out_value->found_kind = NIM_SIMDJSON_INT64;
        out_value->int64_value = raw_int;
        out_value->status = static_cast<uint32_t>(simdjson::SUCCESS);
        return static_cast<uint32_t>(simdjson::SUCCESS);
      }
      if (value.get_uint64().get(raw_uint) == simdjson::SUCCESS) {
        out_value->found_kind = NIM_SIMDJSON_UINT64;
        out_value->uint64_value = raw_uint;
        out_value->status = static_cast<uint32_t>(simdjson::SUCCESS);
        return static_cast<uint32_t>(simdjson::SUCCESS);
      }
      break;
    default:
      break;
  }
  out_value->status = static_cast<uint32_t>(simdjson::INCORRECT_TYPE);
  return static_cast<uint32_t>(simdjson::INCORRECT_TYPE);
}

static uint32_t extract_native_node(
  simdjson::ondemand::value value,
  nim_simdjson_arena *arena,
  const nim_simdjson_native_plan_node *plan,
  size_t plan_len,
  size_t node_index,
  nim_simdjson_native_value *out_value,
  size_t depth
);

static uint32_t extract_native_object(
  simdjson::ondemand::object object,
  nim_simdjson_arena *arena,
  const nim_simdjson_native_plan_node *plan,
  size_t plan_len,
  size_t node_index,
  nim_simdjson_native_value *out_value,
  size_t depth
) {
  if (g_ondemand_max_depth != 0 && depth > g_ondemand_max_depth) {
    out_value->status = static_cast<uint32_t>(simdjson::DEPTH_ERROR);
    return static_cast<uint32_t>(simdjson::DEPTH_ERROR);
  }
  if (out_value == nullptr || plan == nullptr || node_index >= plan_len) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  const auto &node = plan[node_index];
  reset_native_value(out_value);
  out_value->status = static_cast<uint32_t>(simdjson::SUCCESS);
  out_value->found_kind = NIM_SIMDJSON_OBJECT;

  if (node.child_count == 0) {
    return static_cast<uint32_t>(simdjson::SUCCESS);
  }

  size_t children_bytes = 0;
  if (!checked_size_mul(sizeof(nim_simdjson_native_value), node.child_count, &children_bytes)) {
    out_value->status = static_cast<uint32_t>(simdjson::MEMALLOC);
    return static_cast<uint32_t>(simdjson::MEMALLOC);
  }
  auto *children = arena != nullptr
    ? reinterpret_cast<nim_simdjson_native_value *>(
        arena_alloc(arena, children_bytes)
      )
    : static_cast<nim_simdjson_native_value *>(
        std::calloc(node.child_count, sizeof(nim_simdjson_native_value))
      );
  if (children == nullptr) {
    out_value->status = static_cast<uint32_t>(simdjson::MEMALLOC);
    return static_cast<uint32_t>(simdjson::MEMALLOC);
  }
  out_value->children = children;
  out_value->children_len = node.child_count;
  for (size_t i = 0; i < node.child_count; ++i) {
    reset_native_value(&children[i]);
  }
  auto scan_object = [&](simdjson::ondemand::object scan) -> uint32_t {
    auto advance_next_unmatched = [&](size_t &next_ordinal, size_t &next_child_plan_index) {
      while (next_ordinal < node.child_count) {
        if (next_child_plan_index >= plan_len) {
          break;
        }
        if (children[next_ordinal].status != static_cast<uint32_t>(simdjson::SUCCESS)) {
          break;
        }
        next_child_plan_index += plan[next_child_plan_index].subtree_size;
        ++next_ordinal;
      }
    };
    size_t next_ordinal = 0;
    size_t next_child_plan_index = node_index + 1;

    for (auto field_result : scan) {
      if (field_result.error()) {
        return static_cast<uint32_t>(field_result.error());
      }
      auto field = field_result.value_unsafe();
      auto key_result = field.unescaped_key(false);
      if (key_result.error()) {
        return static_cast<uint32_t>(key_result.error());
      }
      std::string_view key = key_result.value_unsafe();
      advance_next_unmatched(next_ordinal, next_child_plan_index);
      if (next_ordinal < node.child_count && next_child_plan_index < plan_len &&
          native_key_matches(plan[next_child_plan_index], key)) {
        auto error = extract_native_node(
          field.value(),
          arena,
          plan,
          plan_len,
          next_child_plan_index,
          &children[next_ordinal],
          depth + 1
        );
        if (error != simdjson::SUCCESS) {
          return error;
        }
        advance_next_unmatched(next_ordinal, next_child_plan_index);
        continue;
      }

      size_t child_plan_index = node_index + 1;
      for (size_t ordinal = 0; ordinal < node.child_count; ++ordinal) {
        if (child_plan_index >= plan_len) {
          return static_cast<uint32_t>(simdjson::TAPE_ERROR);
        }
        if (children[ordinal].status == static_cast<uint32_t>(simdjson::SUCCESS)) {
          child_plan_index += plan[child_plan_index].subtree_size;
          continue;
        }
        if (native_key_matches(plan[child_plan_index], key)) {
          auto error = extract_native_node(
            field.value(),
            arena,
            plan,
            plan_len,
            child_plan_index,
            &children[ordinal],
            depth + 1
          );
          if (error != simdjson::SUCCESS) {
            return error;
          }
          if (ordinal == next_ordinal) {
            advance_next_unmatched(next_ordinal, next_child_plan_index);
          }
          break;
        }
        child_plan_index += plan[child_plan_index].subtree_size;
      }
    }
    return static_cast<uint32_t>(simdjson::SUCCESS);
  };

  auto error = scan_object(object);
  if (error != simdjson::SUCCESS) {
    out_value->status = error;
    if (arena == nullptr) {
      std::free(children);
    }
    out_value->children = nullptr;
    out_value->children_len = 0;
    return error;
  }

  return static_cast<uint32_t>(simdjson::SUCCESS);
}

static uint32_t extract_native_seq_object(
  simdjson::ondemand::array array,
  nim_simdjson_arena *arena,
  const nim_simdjson_native_plan_node *plan,
  size_t plan_len,
  size_t node_index,
  nim_simdjson_native_value *out_value,
  size_t depth
) {
  if (g_ondemand_max_depth != 0 && depth > g_ondemand_max_depth) {
    out_value->status = static_cast<uint32_t>(simdjson::DEPTH_ERROR);
    return static_cast<uint32_t>(simdjson::DEPTH_ERROR);
  }
  if (out_value == nullptr || plan == nullptr || node_index >= plan_len) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  const auto &node = plan[node_index];
  if (node.child_count != 1 || node_index + 1 >= plan_len) {
    out_value->status = static_cast<uint32_t>(simdjson::TAPE_ERROR);
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  reset_native_value(out_value);
  out_value->status = static_cast<uint32_t>(simdjson::SUCCESS);
  out_value->found_kind = NIM_SIMDJSON_ARRAY;

  nim_simdjson_native_value *children = nullptr;
  size_t count = 0;
  if (arena != nullptr) {
    std::vector<nim_simdjson_native_value> temp_children{};
    temp_children.reserve(8);
    for (auto value_result : array) {
      if (g_ondemand_max_array_items != 0 && temp_children.size() >= g_ondemand_max_array_items) {
        out_value->status = NIM_SIMDJSON_ERR_ARRAY_TOO_LARGE;
        for (auto &child : temp_children) {
          release_native_value(&child, false);
        }
        return NIM_SIMDJSON_ERR_ARRAY_TOO_LARGE;
      }
      if (value_result.error()) {
        out_value->status = static_cast<uint32_t>(value_result.error());
        for (auto &child : temp_children) {
          release_native_value(&child, false);
        }
        return static_cast<uint32_t>(value_result.error());
      }

      temp_children.emplace_back();
      reset_native_value(&temp_children.back());
      auto error = extract_native_node(
        value_result.value_unsafe(),
        arena,
        plan,
        plan_len,
        node_index + 1,
        &temp_children.back(),
        depth + 1
      );
      if (error != simdjson::SUCCESS) {
        out_value->status = error;
        for (auto &child : temp_children) {
          release_native_value(&child, false);
        }
        return error;
      }
    }

    count = temp_children.size();
    if (count > 0) {
      size_t children_bytes = 0;
      if (!checked_size_mul(sizeof(nim_simdjson_native_value), count, &children_bytes)) {
        out_value->status = static_cast<uint32_t>(simdjson::MEMALLOC);
        for (auto &child : temp_children) {
          release_native_value(&child, false);
        }
        return static_cast<uint32_t>(simdjson::MEMALLOC);
      }
      children = reinterpret_cast<nim_simdjson_native_value *>(
        arena_alloc(arena, children_bytes)
      );
      if (children == nullptr) {
        out_value->status = static_cast<uint32_t>(simdjson::MEMALLOC);
        for (auto &child : temp_children) {
          release_native_value(&child, false);
        }
        return static_cast<uint32_t>(simdjson::MEMALLOC);
      }
      std::memcpy(children, temp_children.data(), children_bytes);
      out_value->children = children;
      out_value->children_len = count;
    }
  } else {
    size_t capacity = 0;
    for (auto value_result : array) {
      if (g_ondemand_max_array_items != 0 && count >= g_ondemand_max_array_items) {
        out_value->status = NIM_SIMDJSON_ERR_ARRAY_TOO_LARGE;
        for (size_t i = 0; i < count; ++i) {
          release_native_value(&children[i], true);
        }
        std::free(children);
        return NIM_SIMDJSON_ERR_ARRAY_TOO_LARGE;
      }
      if (value_result.error()) {
        out_value->status = static_cast<uint32_t>(value_result.error());
        for (size_t i = 0; i < count; ++i) {
          release_native_value(&children[i], true);
        }
        std::free(children);
        return static_cast<uint32_t>(value_result.error());
      }

      if (count == capacity) {
        size_t new_capacity = 0;
        if (!next_capacity(capacity, 4, sizeof(nim_simdjson_native_value), &new_capacity)) {
          out_value->status = static_cast<uint32_t>(simdjson::MEMALLOC);
          for (size_t i = 0; i < count; ++i) {
            release_native_value(&children[i], true);
          }
          std::free(children);
          return static_cast<uint32_t>(simdjson::MEMALLOC);
        }
        auto *resized = static_cast<nim_simdjson_native_value *>(
          std::realloc(children, sizeof(nim_simdjson_native_value) * new_capacity)
        );
        if (resized == nullptr) {
          out_value->status = static_cast<uint32_t>(simdjson::MEMALLOC);
          for (size_t i = 0; i < count; ++i) {
            release_native_value(&children[i], true);
          }
          std::free(children);
          return static_cast<uint32_t>(simdjson::MEMALLOC);
        }
        children = resized;
        capacity = new_capacity;
      }

      reset_native_value(&children[count]);
      auto error = extract_native_node(
        value_result.value_unsafe(),
        nullptr,
        plan,
        plan_len,
        node_index + 1,
        &children[count],
        depth + 1
      );
      if (error != simdjson::SUCCESS) {
        out_value->status = error;
        for (size_t i = 0; i <= count; ++i) {
          release_native_value(&children[i], true);
        }
        std::free(children);
        return error;
      }
      ++count;
    }

    if (count > 0) {
      out_value->children = children;
      out_value->children_len = count;
    }
  }

  return static_cast<uint32_t>(simdjson::SUCCESS);
}

static uint32_t extract_native_node(
  simdjson::ondemand::value value,
  nim_simdjson_arena *arena,
  const nim_simdjson_native_plan_node *plan,
  size_t plan_len,
  size_t node_index,
  nim_simdjson_native_value *out_value,
  size_t depth
) {
  if (out_value == nullptr || plan == nullptr || node_index >= plan_len) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  const auto &node = plan[node_index];
  switch (node.kind) {
    case NIM_SIMDJSON_NATIVE_PLAN_OBJECT: {
      auto object_result = value.get_object();
      if (object_result.error()) {
        reset_native_value(out_value);
        out_value->status = static_cast<uint32_t>(object_result.error());
        return static_cast<uint32_t>(object_result.error());
      }
      return extract_native_object(
        object_result.value_unsafe(),
        arena,
        plan,
        plan_len,
        node_index,
        out_value,
        depth
      );
    }
    case NIM_SIMDJSON_NATIVE_PLAN_SEQ_OBJECT: {
      auto array_result = value.get_array();
      if (array_result.error()) {
        reset_native_value(out_value);
        out_value->status = static_cast<uint32_t>(array_result.error());
        return static_cast<uint32_t>(array_result.error());
      }
      return extract_native_seq_object(array_result.value_unsafe(), arena, plan, plan_len, node_index, out_value, depth);
    }
    case NIM_SIMDJSON_NATIVE_PLAN_STRING: {
      reset_native_value(out_value);
      std::string_view raw;
      auto error = value.get_string().get(raw);
      if (error != simdjson::SUCCESS) {
        out_value->status = static_cast<uint32_t>(error);
        return static_cast<uint32_t>(error);
      }
      assign_view_bytes(raw, &out_value->data, &out_value->data_len);
      out_value->status = static_cast<uint32_t>(simdjson::SUCCESS);
      out_value->found_kind = NIM_SIMDJSON_STRING;
      return static_cast<uint32_t>(simdjson::SUCCESS);
    }
    case NIM_SIMDJSON_NATIVE_PLAN_BOOL: {
      reset_native_value(out_value);
      auto error = value.get_bool().get(out_value->bool_value);
      out_value->status = static_cast<uint32_t>(error);
      if (error == simdjson::SUCCESS) {
        out_value->found_kind = NIM_SIMDJSON_BOOL;
      }
      return static_cast<uint32_t>(error);
    }
    case NIM_SIMDJSON_NATIVE_PLAN_SIGNED_INT:
    case NIM_SIMDJSON_NATIVE_PLAN_UNSIGNED_INT:
    case NIM_SIMDJSON_NATIVE_PLAN_FLOAT:
      reset_native_value(out_value);
      return capture_native_number(value, node.kind, out_value);
    default:
      reset_native_value(out_value);
      out_value->status = static_cast<uint32_t>(simdjson::TAPE_ERROR);
      return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
}

static uint32_t capture_ondemand_value(
  simdjson::ondemand::value value,
  nim_simdjson_ondemand_value *out_value
) {
  if (out_value == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  reset_ondemand_value(out_value);

  simdjson::ondemand::json_type kind;
  auto kind_error = value.type().get(kind);
  if (kind_error != simdjson::SUCCESS) {
    out_value->status = static_cast<uint32_t>(kind_error);
    return static_cast<uint32_t>(kind_error);
  }

  switch (kind) {
    case simdjson::ondemand::json_type::null:
      out_value->found_kind = NIM_SIMDJSON_NULL;
      return static_cast<uint32_t>(simdjson::SUCCESS);
    case simdjson::ondemand::json_type::boolean: {
      out_value->found_kind = NIM_SIMDJSON_BOOL;
      auto error = value.get_bool().get(out_value->bool_value);
      out_value->status = static_cast<uint32_t>(error);
      return static_cast<uint32_t>(error);
    }
    case simdjson::ondemand::json_type::number: {
      double raw_double{};
      if (value.get_double().get(raw_double) == simdjson::SUCCESS) {
        int64_t raw_int{};
        if (value.get_int64().get(raw_int) == simdjson::SUCCESS) {
          out_value->found_kind = NIM_SIMDJSON_INT64;
          out_value->int64_value = raw_int;
          return static_cast<uint32_t>(simdjson::SUCCESS);
        }
        uint64_t raw_uint{};
        if (value.get_uint64().get(raw_uint) == simdjson::SUCCESS) {
          out_value->found_kind = NIM_SIMDJSON_UINT64;
          out_value->uint64_value = raw_uint;
          return static_cast<uint32_t>(simdjson::SUCCESS);
        }
        out_value->found_kind = NIM_SIMDJSON_DOUBLE;
        out_value->double_value = raw_double;
        return static_cast<uint32_t>(simdjson::SUCCESS);
      }
      out_value->status = static_cast<uint32_t>(simdjson::NUMBER_ERROR);
      return static_cast<uint32_t>(simdjson::NUMBER_ERROR);
    }
    case simdjson::ondemand::json_type::string: {
      std::string_view raw;
      auto error = value.get_string().get(raw);
      if (error != simdjson::SUCCESS) {
        out_value->status = static_cast<uint32_t>(error);
        return static_cast<uint32_t>(error);
      }
      out_value->found_kind = NIM_SIMDJSON_STRING;
      out_value->data = copy_owned_bytes(raw, &out_value->data_len);
      if (!raw.empty() && out_value->data == nullptr) {
        out_value->status = static_cast<uint32_t>(simdjson::MEMALLOC);
        return static_cast<uint32_t>(simdjson::MEMALLOC);
      }
      return static_cast<uint32_t>(simdjson::SUCCESS);
    }
    case simdjson::ondemand::json_type::array: {
      auto array_result = value.get_array();
      if (array_result.error()) {
        out_value->status = static_cast<uint32_t>(array_result.error());
        return static_cast<uint32_t>(array_result.error());
      }
      auto raw_result = array_result.value_unsafe().raw_json();
      if (raw_result.error()) {
        out_value->status = static_cast<uint32_t>(raw_result.error());
        return static_cast<uint32_t>(raw_result.error());
      }
      auto raw = raw_result.value_unsafe();
      out_value->found_kind = NIM_SIMDJSON_ARRAY;
      out_value->data = copy_owned_bytes(raw, &out_value->data_len);
      if (!raw.empty() && out_value->data == nullptr) {
        out_value->status = static_cast<uint32_t>(simdjson::MEMALLOC);
        return static_cast<uint32_t>(simdjson::MEMALLOC);
      }
      return static_cast<uint32_t>(simdjson::SUCCESS);
    }
    case simdjson::ondemand::json_type::object: {
      auto object_result = value.get_object();
      if (object_result.error()) {
        out_value->status = static_cast<uint32_t>(object_result.error());
        return static_cast<uint32_t>(object_result.error());
      }
      auto raw_result = object_result.value_unsafe().raw_json();
      if (raw_result.error()) {
        out_value->status = static_cast<uint32_t>(raw_result.error());
        return static_cast<uint32_t>(raw_result.error());
      }
      auto raw = raw_result.value_unsafe();
      out_value->found_kind = NIM_SIMDJSON_OBJECT;
      out_value->data = copy_owned_bytes(raw, &out_value->data_len);
      if (!raw.empty() && out_value->data == nullptr) {
        out_value->status = static_cast<uint32_t>(simdjson::MEMALLOC);
        return static_cast<uint32_t>(simdjson::MEMALLOC);
      }
      return static_cast<uint32_t>(simdjson::SUCCESS);
    }
  }

  out_value->status = static_cast<uint32_t>(simdjson::TAPE_ERROR);
  return static_cast<uint32_t>(simdjson::TAPE_ERROR);
}

static uint32_t capture_ondemand_entry(
  simdjson::ondemand::value value,
  nim_simdjson_ondemand_entry *entry
) {
  nim_simdjson_ondemand_value captured{};
  auto error = capture_ondemand_value(value, &captured);
  entry->status = captured.status;
  entry->found_kind = captured.found_kind;
  entry->data = captured.data;
  entry->data_len = captured.data_len;
  entry->bool_value = captured.bool_value;
  entry->int64_value = captured.int64_value;
  entry->uint64_value = captured.uint64_value;
  entry->double_value = captured.double_value;
  return error;
}

uint32_t nim_simdjson_ondemand_capture(
  const char *data,
  size_t len,
  nim_simdjson_ondemand_value *out_value
) {
  if (data == nullptr || out_value == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  reset_ondemand_value(out_value);

  simdjson::padded_string json(data, len);
  auto &parser = g_ondemand_scratch_parser;
  parser.set_max_depth(g_ondemand_max_depth);
  auto doc_result = parser.iterate(json);
  if (doc_result.error()) {
    out_value->status = static_cast<uint32_t>(doc_result.error());
    return static_cast<uint32_t>(doc_result.error());
  }

  auto kind_result = doc_result.type();
  if (kind_result.error()) {
    out_value->status = static_cast<uint32_t>(kind_result.error());
    return static_cast<uint32_t>(kind_result.error());
  }

  switch (kind_result.value_unsafe()) {
    case simdjson::ondemand::json_type::null:
      out_value->found_kind = NIM_SIMDJSON_NULL;
      return static_cast<uint32_t>(simdjson::SUCCESS);
    case simdjson::ondemand::json_type::boolean: {
      out_value->found_kind = NIM_SIMDJSON_BOOL;
      auto bool_result = doc_result.get_bool();
      out_value->status = static_cast<uint32_t>(bool_result.error());
      if (bool_result.error() != simdjson::SUCCESS) {
        return static_cast<uint32_t>(bool_result.error());
      }
      out_value->bool_value = bool_result.value_unsafe();
      return static_cast<uint32_t>(simdjson::SUCCESS);
    }
    case simdjson::ondemand::json_type::number: {
      auto int_result = doc_result.get_int64();
      if (int_result.error() == simdjson::SUCCESS) {
        out_value->found_kind = NIM_SIMDJSON_INT64;
        out_value->int64_value = int_result.value_unsafe();
        return static_cast<uint32_t>(simdjson::SUCCESS);
      }
      auto uint_result = doc_result.get_uint64();
      if (uint_result.error() == simdjson::SUCCESS) {
        out_value->found_kind = NIM_SIMDJSON_UINT64;
        out_value->uint64_value = uint_result.value_unsafe();
        return static_cast<uint32_t>(simdjson::SUCCESS);
      }
      auto double_result = doc_result.get_double();
      out_value->status = static_cast<uint32_t>(double_result.error());
      if (double_result.error() != simdjson::SUCCESS) {
        return static_cast<uint32_t>(double_result.error());
      }
      out_value->found_kind = NIM_SIMDJSON_DOUBLE;
      out_value->double_value = double_result.value_unsafe();
      return static_cast<uint32_t>(simdjson::SUCCESS);
    }
    case simdjson::ondemand::json_type::string: {
      auto string_result = doc_result.get_string(false);
      out_value->status = static_cast<uint32_t>(string_result.error());
      if (string_result.error() != simdjson::SUCCESS) {
        return static_cast<uint32_t>(string_result.error());
      }
      auto raw = string_result.value_unsafe();
      out_value->found_kind = NIM_SIMDJSON_STRING;
      out_value->data = copy_owned_bytes(raw, &out_value->data_len);
      if (!raw.empty() && out_value->data == nullptr) {
        out_value->status = static_cast<uint32_t>(simdjson::MEMALLOC);
        return static_cast<uint32_t>(simdjson::MEMALLOC);
      }
      return static_cast<uint32_t>(simdjson::SUCCESS);
    }
    case simdjson::ondemand::json_type::array: {
      auto doc = std::move(doc_result.value_unsafe());
      auto array_result = doc.get_array();
      if (array_result.error()) {
        out_value->status = static_cast<uint32_t>(array_result.error());
        return static_cast<uint32_t>(array_result.error());
      }
      auto raw_result = array_result.value_unsafe().raw_json();
      if (raw_result.error()) {
        out_value->status = static_cast<uint32_t>(raw_result.error());
        return static_cast<uint32_t>(raw_result.error());
      }
      auto raw = raw_result.value_unsafe();
      out_value->found_kind = NIM_SIMDJSON_ARRAY;
      out_value->data = copy_owned_bytes(raw, &out_value->data_len);
      if (!raw.empty() && out_value->data == nullptr) {
        out_value->status = static_cast<uint32_t>(simdjson::MEMALLOC);
        return static_cast<uint32_t>(simdjson::MEMALLOC);
      }
      return static_cast<uint32_t>(simdjson::SUCCESS);
    }
    case simdjson::ondemand::json_type::object: {
      auto doc = std::move(doc_result.value_unsafe());
      auto object_result = doc.get_object();
      if (object_result.error()) {
        out_value->status = static_cast<uint32_t>(object_result.error());
        return static_cast<uint32_t>(object_result.error());
      }
      auto raw_result = object_result.value_unsafe().raw_json();
      if (raw_result.error()) {
        out_value->status = static_cast<uint32_t>(raw_result.error());
        return static_cast<uint32_t>(raw_result.error());
      }
      auto raw = raw_result.value_unsafe();
      out_value->found_kind = NIM_SIMDJSON_OBJECT;
      out_value->data = copy_owned_bytes(raw, &out_value->data_len);
      if (!raw.empty() && out_value->data == nullptr) {
        out_value->status = static_cast<uint32_t>(simdjson::MEMALLOC);
        return static_cast<uint32_t>(simdjson::MEMALLOC);
      }
      return static_cast<uint32_t>(simdjson::SUCCESS);
    }
  }

  out_value->status = static_cast<uint32_t>(simdjson::TAPE_ERROR);
  return static_cast<uint32_t>(simdjson::TAPE_ERROR);
}

uint32_t nim_simdjson_ondemand_project_object(
  const char *data,
  size_t len,
  nim_simdjson_ondemand_entry *entries,
  size_t count
) {
  if (data == nullptr || entries == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  for (size_t i = 0; i < count; ++i) {
    reset_ondemand_entry(&entries[i]);
  }

  simdjson::padded_string json(data, len);
  auto &parser = g_ondemand_scratch_parser;
  parser.set_max_depth(g_ondemand_max_depth);
  auto doc_result = parser.iterate(json);
  if (doc_result.error()) {
    return static_cast<uint32_t>(doc_result.error());
  }

  auto doc = std::move(doc_result.value_unsafe());
  auto object_result = doc.get_object();
  if (object_result.error()) {
    return static_cast<uint32_t>(object_result.error());
  }

  auto object = object_result.value_unsafe();
  for (auto field_result : object) {
    if (field_result.error()) {
      return static_cast<uint32_t>(field_result.error());
    }
    auto field = field_result.value_unsafe();
    auto key_result = field.unescaped_key(false);
    if (key_result.error()) {
      return static_cast<uint32_t>(key_result.error());
    }
    std::string_view key = key_result.value_unsafe();
    for (size_t i = 0; i < count; ++i) {
      auto &entry = entries[i];
      if (entry.found_kind >= 0 || entry.key == nullptr) {
        continue;
      }
      if (key == std::string_view(entry.key, entry.key_len)) {
        auto error = capture_ondemand_entry(field.value(), &entry);
        if (error != simdjson::SUCCESS) {
          entry.status = error;
        }
        break;
      }
    }
  }

  return static_cast<uint32_t>(simdjson::SUCCESS);
}

uint32_t nim_simdjson_ondemand_project_array_objects(
  const char *data,
  size_t len,
  nim_simdjson_ondemand_entry *entries,
  size_t item_count,
  size_t fields_per_item
) {
  if (data == nullptr || entries == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  if (fields_per_item == 0) {
    return static_cast<uint32_t>(simdjson::SUCCESS);
  }

  size_t total_entries = 0;
  if (!checked_size_mul(item_count, fields_per_item, &total_entries)) {
    return static_cast<uint32_t>(simdjson::MEMALLOC);
  }
  for (size_t i = 0; i < total_entries; ++i) {
    reset_ondemand_entry(&entries[i]);
  }

  simdjson::padded_string json(data, len);
  auto &parser = g_ondemand_scratch_parser;
  parser.set_max_depth(g_ondemand_max_depth);
  auto doc_result = parser.iterate(json);
  if (doc_result.error()) {
    return static_cast<uint32_t>(doc_result.error());
  }

  auto doc = std::move(doc_result.value_unsafe());
  auto array_result = doc.get_array();
  if (array_result.error()) {
    return static_cast<uint32_t>(array_result.error());
  }

  auto array = array_result.value_unsafe();
  size_t item_index = 0;
  for (auto value_result : array) {
    if (item_index >= item_count) {
      break;
    }
    if (value_result.error()) {
      return static_cast<uint32_t>(value_result.error());
    }
    auto object_result = value_result.value_unsafe().get_object();
    if (object_result.error()) {
      return static_cast<uint32_t>(object_result.error());
    }

    auto object = object_result.value_unsafe();
    auto *item_entries = entries + (item_index * fields_per_item);
    for (auto field_result : object) {
      if (field_result.error()) {
        return static_cast<uint32_t>(field_result.error());
      }
      auto field = field_result.value_unsafe();
      auto key_result = field.unescaped_key(false);
      if (key_result.error()) {
        return static_cast<uint32_t>(key_result.error());
      }
      std::string_view key = key_result.value_unsafe();
      for (size_t field_index = 0; field_index < fields_per_item; ++field_index) {
        auto &entry = item_entries[field_index];
        if (entry.found_kind >= 0 || entry.key == nullptr) {
          continue;
        }
        if (key == std::string_view(entry.key, entry.key_len)) {
          auto error = capture_ondemand_entry(field.value(), &entry);
          if (error != simdjson::SUCCESS) {
            entry.status = error;
          }
          break;
        }
      }
    }
    ++item_index;
  }

  return static_cast<uint32_t>(simdjson::SUCCESS);
}

uint32_t nim_simdjson_ondemand_array_length(
  const char *data,
  size_t len,
  size_t *out_len
) {
  if (data == nullptr || out_len == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  simdjson::padded_string json(data, len);
  auto &parser = g_ondemand_scratch_parser;
  parser.set_max_depth(g_ondemand_max_depth);
  auto doc_result = parser.iterate(json);
  if (doc_result.error()) {
    return static_cast<uint32_t>(doc_result.error());
  }

  auto doc = std::move(doc_result.value_unsafe());
  auto array_result = doc.get_array();
  if (array_result.error()) {
    return static_cast<uint32_t>(array_result.error());
  }

  auto count_result = array_result.value_unsafe().count_elements();
  if (count_result.error()) {
    return static_cast<uint32_t>(count_result.error());
  }
  *out_len = count_result.value_unsafe();
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

uint32_t nim_simdjson_ondemand_capture_array(
  const char *data,
  size_t len,
  nim_simdjson_ondemand_value *items,
  size_t count
) {
  if (data == nullptr || items == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }
  for (size_t i = 0; i < count; ++i) {
    reset_ondemand_value(&items[i]);
  }

  simdjson::padded_string json(data, len);
  auto &parser = g_ondemand_scratch_parser;
  parser.set_max_depth(g_ondemand_max_depth);
  auto doc_result = parser.iterate(json);
  if (doc_result.error()) {
    return static_cast<uint32_t>(doc_result.error());
  }

  auto doc = std::move(doc_result.value_unsafe());
  auto array_result = doc.get_array();
  if (array_result.error()) {
    return static_cast<uint32_t>(array_result.error());
  }

  size_t index = 0;
  for (auto value_result : array_result.value_unsafe()) {
    if (value_result.error()) {
      return static_cast<uint32_t>(value_result.error());
    }
    if (index >= count) {
      return static_cast<uint32_t>(simdjson::INDEX_OUT_OF_BOUNDS);
    }
    auto error = capture_ondemand_value(value_result.value_unsafe(), &items[index]);
    if (error != simdjson::SUCCESS) {
      return error;
    }
    ++index;
  }

  if (index != count) {
    return static_cast<uint32_t>(simdjson::INDEX_OUT_OF_BOUNDS);
  }
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

void nim_simdjson_ondemand_value_release(nim_simdjson_ondemand_value *value) {
  if (value == nullptr || value->data == nullptr) {
    return;
  }
  std::free(const_cast<char *>(value->data));
  value->data = nullptr;
  value->data_len = 0;
}

void nim_simdjson_ondemand_entry_release(nim_simdjson_ondemand_entry *entry) {
  if (entry == nullptr || entry->data == nullptr) {
    return;
  }
  std::free(const_cast<char *>(entry->data));
  entry->data = nullptr;
  entry->data_len = 0;
}

void nim_simdjson_ondemand_entries_release(nim_simdjson_ondemand_entry *entries, size_t count) {
  if (entries == nullptr) {
    return;
  }
  for (size_t i = 0; i < count; ++i) {
    nim_simdjson_ondemand_entry_release(&entries[i]);
  }
}

void nim_simdjson_ondemand_values_release(nim_simdjson_ondemand_value *items, size_t count) {
  if (items == nullptr) {
    return;
  }
  for (size_t i = 0; i < count; ++i) {
    nim_simdjson_ondemand_value_release(&items[i]);
  }
}

uint32_t nim_simdjson_extract_medium_todo_envelope(
  const char *data,
  size_t len,
  nim_simdjson_medium_todo_envelope *out_envelope
) {
  if (data == nullptr || out_envelope == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  reset_medium_todo_envelope(out_envelope);

  auto *state = new (std::nothrow) nim_simdjson_retained_ondemand_state(data, len);
  if (state == nullptr) {
    out_envelope->status = static_cast<uint32_t>(simdjson::MEMALLOC);
    return static_cast<uint32_t>(simdjson::MEMALLOC);
  }
  out_envelope->arena_state = state;
  simdjson::ondemand::document doc;
  auto parse_error = typed_decode_parser().iterate(state->padded).get(doc);
  if (parse_error != simdjson::SUCCESS) {
    release_medium_todo_envelope(out_envelope);
    out_envelope->status = static_cast<uint32_t>(parse_error);
    return static_cast<uint32_t>(parse_error);
  }

  simdjson::ondemand::object root;
  auto root_error = doc.get_object().get(root);
  if (root_error != simdjson::SUCCESS) {
    release_medium_todo_envelope(out_envelope);
    out_envelope->status = static_cast<uint32_t>(root_error);
    return static_cast<uint32_t>(root_error);
  }

  nim_simdjson_medium_todo_item *todos = nullptr;
  size_t todo_count = 0;
  size_t todo_capacity = len / 32;
  if (todo_capacity < 16) {
    todo_capacity = 16;
  } else if (todo_capacity > 4096) {
    todo_capacity = 4096;
  }
  if (todo_capacity > 0) {
    size_t todo_bytes = 0;
    if (!checked_size_mul(sizeof(nim_simdjson_medium_todo_item), todo_capacity, &todo_bytes)) {
      out_envelope->status = static_cast<uint32_t>(simdjson::MEMALLOC);
      return static_cast<uint32_t>(simdjson::MEMALLOC);
    }
    todos = static_cast<nim_simdjson_medium_todo_item *>(
      std::malloc(todo_bytes)
    );
    if (todos == nullptr) {
      out_envelope->status = static_cast<uint32_t>(simdjson::MEMALLOC);
      return static_cast<uint32_t>(simdjson::MEMALLOC);
    }
  }
  auto release_temp = [&]() {
    if (todos != nullptr) {
      std::free(todos);
      todos = nullptr;
    }
    todo_count = 0;
    todo_capacity = 0;
  };

  simdjson::ondemand::array todo_array;
  auto todos_error = root["todos"].get_array().get(todo_array);
  if (todos_error != simdjson::SUCCESS) {
    release_temp();
    out_envelope->status = static_cast<uint32_t>(todos_error);
    return static_cast<uint32_t>(todos_error);
  }

  size_t medium_max_depth = 2;
  for (auto todo_value : todo_array) {
    medium_max_depth = 3;
    simdjson::ondemand::object todo;
    auto todo_error = todo_value.get_object().get(todo);
    if (todo_error != simdjson::SUCCESS) {
      release_temp();
      out_envelope->status = static_cast<uint32_t>(todo_error);
      return static_cast<uint32_t>(todo_error);
    }

    int64_t id = 0;
    std::string_view title;
    bool completed = false;
    if (todo["id"].get_int64().get(id) != simdjson::SUCCESS ||
        todo["title"].get_string().get(title) != simdjson::SUCCESS ||
        todo["completed"].get_bool().get(completed) != simdjson::SUCCESS) {
      release_temp();
      out_envelope->status = static_cast<uint32_t>(simdjson::INCORRECT_TYPE);
      return static_cast<uint32_t>(simdjson::INCORRECT_TYPE);
    }

    if (todo_count == todo_capacity) {
      size_t new_capacity = 0;
      if (!next_capacity(todo_capacity, 16, sizeof(nim_simdjson_medium_todo_item), &new_capacity)) {
        release_temp();
        out_envelope->status = static_cast<uint32_t>(simdjson::MEMALLOC);
        return static_cast<uint32_t>(simdjson::MEMALLOC);
      }
      auto *resized = static_cast<nim_simdjson_medium_todo_item *>(
        std::realloc(todos, sizeof(nim_simdjson_medium_todo_item) * new_capacity)
      );
      if (resized == nullptr) {
        release_temp();
        out_envelope->status = static_cast<uint32_t>(simdjson::MEMALLOC);
        return static_cast<uint32_t>(simdjson::MEMALLOC);
      }
      todos = resized;
      todo_capacity = new_capacity;
    }

    nim_simdjson_medium_todo_item item{};
    item.id = id;
    item.completed = completed;
    assign_view_bytes(title, &item.title_data, &item.title_len);
    todos[todo_count] = item;
    ++todo_count;
  }

  simdjson::ondemand::object meta;
  auto meta_error = root["meta"].get_object().get(meta);
  if (meta_error != simdjson::SUCCESS ||
      meta["page"].get_int64().get(out_envelope->page) != simdjson::SUCCESS ||
      meta["count"].get_int64().get(out_envelope->count) != simdjson::SUCCESS) {
    release_temp();
    out_envelope->status = static_cast<uint32_t>(meta_error == simdjson::SUCCESS ? simdjson::INCORRECT_TYPE : meta_error);
    return out_envelope->status;
  }

  out_envelope->todos = todos;
  if (g_ondemand_max_depth != 0 && medium_max_depth > g_ondemand_max_depth) {
    release_medium_todo_envelope(out_envelope);
    out_envelope->status = static_cast<uint32_t>(simdjson::DEPTH_ERROR);
    return static_cast<uint32_t>(simdjson::DEPTH_ERROR);
  }
  out_envelope->todos_len = todo_count;

  out_envelope->status = static_cast<uint32_t>(simdjson::SUCCESS);
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

void nim_simdjson_medium_todo_envelope_release(nim_simdjson_medium_todo_envelope *envelope) {
  release_medium_todo_envelope(envelope);
}

uint32_t nim_simdjson_extract_nested_project_envelope(
  const char *data,
  size_t len,
  nim_simdjson_nested_project_envelope *out_envelope
) {
  if (data == nullptr || out_envelope == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  reset_nested_project_envelope(out_envelope);
  auto *state = new (std::nothrow) nim_simdjson_retained_ondemand_state(data, len);
  if (state == nullptr) {
    out_envelope->status = static_cast<uint32_t>(simdjson::MEMALLOC);
    return static_cast<uint32_t>(simdjson::MEMALLOC);
  }
  out_envelope->arena_state = state;

  simdjson::ondemand::document doc;
  auto parse_error = typed_decode_parser().iterate(state->padded).get(doc);
  if (parse_error != simdjson::SUCCESS) {
    release_nested_project_envelope(out_envelope);
    out_envelope->status = static_cast<uint32_t>(parse_error);
    return static_cast<uint32_t>(parse_error);
  }

  simdjson::ondemand::object root;
  auto root_error = doc.get_object().get(root);
  if (root_error != simdjson::SUCCESS) {
    release_nested_project_envelope(out_envelope);
    out_envelope->status = static_cast<uint32_t>(root_error);
    return static_cast<uint32_t>(root_error);
  }

  simdjson::ondemand::object meta;
  auto meta_error = root["meta"].get_object().get(meta);
  if (meta_error != simdjson::SUCCESS) {
    release_nested_project_envelope(out_envelope);
    out_envelope->status = static_cast<uint32_t>(meta_error);
    return static_cast<uint32_t>(meta_error);
  }
  auto page_error = meta["page"].get_int64().get(out_envelope->page);
  if (page_error != simdjson::SUCCESS) {
    release_nested_project_envelope(out_envelope);
    out_envelope->status = static_cast<uint32_t>(page_error);
    return static_cast<uint32_t>(page_error);
  }
  auto count_error = meta["count"].get_int64().get(out_envelope->count);
  if (count_error != simdjson::SUCCESS) {
    release_nested_project_envelope(out_envelope);
    out_envelope->status = static_cast<uint32_t>(count_error);
    return static_cast<uint32_t>(count_error);
  }

  simdjson::ondemand::array projects;
  auto projects_error = root["projects"].get_array().get(projects);
  if (projects_error != simdjson::SUCCESS) {
    release_nested_project_envelope(out_envelope);
    out_envelope->status = static_cast<uint32_t>(projects_error);
    return static_cast<uint32_t>(projects_error);
  }

  size_t projects_capacity = 0;

  size_t nested_max_depth = 2;
  for (auto project_value : projects) {
    nested_max_depth = 3;
    simdjson::ondemand::object project;
    auto project_error = project_value.get_object().get(project);
    if (project_error != simdjson::SUCCESS) {
      release_nested_project_envelope(out_envelope);
      out_envelope->status = static_cast<uint32_t>(project_error);
      return static_cast<uint32_t>(project_error);
    }
    nim_simdjson_nested_project_item *slot = nullptr;
    auto append_error = append_dynamic_item(
      &out_envelope->projects,
      &out_envelope->projects_len,
      &projects_capacity,
      &slot
    );
    if (append_error != simdjson::SUCCESS) {
      release_nested_project_envelope(out_envelope);
      out_envelope->status = append_error;
      return append_error;
    }
    auto error = extract_nested_project(project, slot, &nested_max_depth);
    if (error != simdjson::SUCCESS) {
      release_nested_project_envelope(out_envelope);
      out_envelope->status = error;
      return error;
    }
  }

  if (g_ondemand_max_depth != 0 && nested_max_depth > g_ondemand_max_depth) {
    release_nested_project_envelope(out_envelope);
    out_envelope->status = static_cast<uint32_t>(simdjson::DEPTH_ERROR);
    return static_cast<uint32_t>(simdjson::DEPTH_ERROR);
  }
  out_envelope->status = static_cast<uint32_t>(simdjson::SUCCESS);
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

void nim_simdjson_nested_project_envelope_release(nim_simdjson_nested_project_envelope *envelope) {
  release_nested_project_envelope(envelope);
}

uint32_t nim_simdjson_extract_native_plan(
  const char *data,
  size_t len,
  const nim_simdjson_native_plan_node *plan,
  size_t plan_len,
  nim_simdjson_native_value *out_root
) {
  if (data == nullptr || plan == nullptr || plan_len == 0 || out_root == nullptr) {
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  reset_native_value(out_root);
  if (plan[0].kind != NIM_SIMDJSON_NATIVE_PLAN_OBJECT) {
    out_root->status = static_cast<uint32_t>(simdjson::TAPE_ERROR);
    return static_cast<uint32_t>(simdjson::TAPE_ERROR);
  }

  auto *state = new (std::nothrow) nim_simdjson_retained_ondemand_state(data, len);
  if (state == nullptr) {
    out_root->status = static_cast<uint32_t>(simdjson::MEMALLOC);
    return static_cast<uint32_t>(simdjson::MEMALLOC);
  }
  simdjson::ondemand::document doc;
  auto parse_error = typed_decode_parser().iterate(state->padded).get(doc);
  if (parse_error != simdjson::SUCCESS) {
    delete state;
    out_root->status = static_cast<uint32_t>(parse_error);
    return static_cast<uint32_t>(parse_error);
  }

  auto object_result = doc.get_object();
  if (object_result.error()) {
    delete state;
    out_root->status = static_cast<uint32_t>(object_result.error());
    return static_cast<uint32_t>(object_result.error());
  }

  auto error = extract_native_object(
    object_result.value_unsafe(),
    state->native_arena,
    plan,
    plan_len,
    0,
    out_root,
    1
  );
  if (error != simdjson::SUCCESS) {
    release_native_value(out_root, false);
    delete state;
    out_root->status = error;
    return error;
  }
  out_root->arena_state = state;
  out_root->status = error;
  return error;
}

void nim_simdjson_native_value_release(nim_simdjson_native_value *value) {
  release_native_value(value);
}

const char *nim_simdjson_error_message(uint32_t code) {
  if (code == NIM_SIMDJSON_ERR_ARRAY_TOO_LARGE) {
    return "JSON array item limit exceeded";
  }
  if (code >= static_cast<uint32_t>(simdjson::NUM_ERROR_CODES)) {
    return "unknown simdjson error";
  }
  return simdjson::error_message(static_cast<simdjson::error_code>(code));
}

uint32_t nim_simdjson_success_code(void) {
  return static_cast<uint32_t>(simdjson::SUCCESS);
}

uint32_t nim_simdjson_no_such_field_code(void) {
  return static_cast<uint32_t>(simdjson::NO_SUCH_FIELD);
}

uint32_t nim_simdjson_index_out_of_bounds_code(void) {
  return static_cast<uint32_t>(simdjson::INDEX_OUT_OF_BOUNDS);
}

uint32_t nim_simdjson_incorrect_type_code(void) {
  return static_cast<uint32_t>(simdjson::INCORRECT_TYPE);
}
