import std/os

const
  ThisDir = currentSourcePath.parentDir
  VendorDir = ThisDir / "vendor"
  BuildMode = when defined(release): "release" else: "debug"
  CpuMode = when defined(nimFastJsonNativeCpu): "nativecpu" else: "genericcpu"
  TargetCpu = when defined(amd64) or defined(x86_64):
    "amd64"
  elif defined(arm64) or defined(aarch64):
    "arm64"
  else:
    hostCPU
  TargetOs = when defined(linux):
    "linux"
  elif defined(macosx):
    "macosx"
  elif defined(windows):
    "windows"
  else:
    hostOS
  BuildRoot = "/tmp/nim_fastjson_simdjson"
  BuildDir = BuildRoot / (TargetOs & "-" & TargetCpu & "-" & BuildMode & "-" & CpuMode)
  VendorObj = BuildDir / "simdjson.o"
  ShimObj = BuildDir / "simdjson_shim.o"
  StaticLib = BuildDir / "libnimsimdjson.a"
  BuildStamp = BuildDir / "build.stamp"
  NativeCpuFlags = when defined(nimFastJsonNativeCpu) and (defined(amd64) or defined(x86_64)):
    "-march=native -mtune=native"
  elif defined(nimFastJsonNativeCpu) and (defined(arm64) or defined(aarch64)):
    "-mcpu=native"
  else:
    ""

{.passc: "-I" & quoteShell(ThisDir) & " -I" & quoteShell(VendorDir).}
when defined(release) and NativeCpuFlags.len > 0:
  {.passc: NativeCpuFlags.}
  {.passl: NativeCpuFlags.}

static:
  proc needsRebuild(target, stamp, expectedStamp: string; inputs: openArray[string]): bool =
    if not fileExists(target):
      return true
    if not fileExists(stamp):
      return true
    if readFile(stamp) != expectedStamp:
      return true
    for input in inputs:
      if not fileExists(input):
        return true
      when defined(windows):
        discard
      else:
        let newer = gorgeEx("test " & quoteShell(input) & " -nt " & quoteShell(target))
        if newer.exitCode == 0:
          return true
        if newer.exitCode > 1:
          return true
    when defined(windows):
      if inputs.len > 0:
        return true
    false

  let lockDir = BuildDir & ".lock"
  var locked = false
  for _ in 0 ..< 200:
    let lockResult = gorgeEx("mkdir -p " & quoteShell(parentDir(BuildDir)) & " && mkdir " & quoteShell(lockDir))
    if lockResult.exitCode == 0:
      locked = true
      break
    sleep(50)
  doAssert locked, "timed out waiting for simdjson build lock: " & lockDir

  try:
    if not dirExists(BuildDir):
      createDir(BuildDir)

    let inputs = [
      VendorDir / "simdjson.cpp",
      VendorDir / "simdjson.h",
      ThisDir / "simdjson_shim.cpp",
      ThisDir / "simdjson_shim.h"
    ]

    let cxx = getEnv("CXX", "c++")
    let expectedStamp = ThisDir & "\n" & TargetOs & "\n" & TargetCpu & "\n" &
      BuildMode & "\n" & CpuMode & "\n" & cxx & "\n" & NativeCpuFlags & "\n"

    if needsRebuild(StaticLib, BuildStamp, expectedStamp, inputs):
      var commonArgs = @["-std=c++20", "-DSIMDJSON_DISABLE_DEPRECATED_API"]
      when defined(release):
        commonArgs.add("-O3")
        commonArgs.add("-DNDEBUG")
        when defined(nimFastJsonNativeCpu) and (defined(amd64) or defined(x86_64)):
          commonArgs.add("-march=native")
          commonArgs.add("-mtune=native")
        elif defined(nimFastJsonNativeCpu) and (defined(arm64) or defined(aarch64)):
          commonArgs.add("-mcpu=native")
      else:
        commonArgs.add("-O0")
      let includeArgs = @["-I" & ThisDir, "-I" & VendorDir]
      let compileVendor = quoteShellCommand(@[cxx] & commonArgs & @[
        "-c", VendorDir / "simdjson.cpp"
      ] & includeArgs & @["-o", VendorObj])
      let compileShim = quoteShellCommand(@[cxx] & commonArgs & @[
        "-c", ThisDir / "simdjson_shim.cpp"
      ] & includeArgs & @["-o", ShimObj])
      let archive = quoteShellCommand(@["ar", "rcs", StaticLib, VendorObj, ShimObj])

      let vendorResult = gorgeEx(compileVendor)
      doAssert vendorResult.exitCode == 0, vendorResult.output

      let shimResult = gorgeEx(compileShim)
      doAssert shimResult.exitCode == 0, shimResult.output

      let archiveResult = gorgeEx(archive)
      doAssert archiveResult.exitCode == 0, archiveResult.output
      writeFile(BuildStamp, expectedStamp)
  finally:
    discard gorgeEx("rmdir " & quoteShell(lockDir))

when defined(macosx):
  {.passl: quoteShell(StaticLib) & " -lc++".}
else:
  {.passl: quoteShell(StaticLib) & " -lstdc++".}

type
  CDoc* {.importc: "nim_simdjson_doc", header: "simdjson_shim.h", incompleteStruct.} = object
  CValueHandle* = csize_t
  CProjectEntry* {.importc: "nim_simdjson_project_entry", header: "simdjson_shim.h", bycopy.} = object
    key*: cstring
    key_len*: csize_t
    status*: uint32
    found_kind*: cint
    str_data*: cstring
    str_len*: csize_t
    bool_value*: bool
    int64_value*: int64
    uint64_value*: uint64
    double_value*: cdouble
    child_handle*: CValueHandle
  COndemandValue* {.importc: "nim_simdjson_ondemand_value", header: "simdjson_shim.h", bycopy.} = object
    status*: uint32
    found_kind*: cint
    data*: cstring
    data_len*: csize_t
    bool_value*: bool
    int64_value*: int64
    uint64_value*: uint64
    double_value*: cdouble
  COndemandEntry* {.importc: "nim_simdjson_ondemand_entry", header: "simdjson_shim.h", bycopy.} = object
    key*: cstring
    key_len*: csize_t
    status*: uint32
    found_kind*: cint
    data*: cstring
    data_len*: csize_t
    bool_value*: bool
    int64_value*: int64
    uint64_value*: uint64
    double_value*: cdouble
  CMediumTodoItem* {.importc: "nim_simdjson_medium_todo_item", header: "simdjson_shim.h", bycopy.} = object
    id*: int64
    title_data*: cstring
    title_len*: csize_t
    completed*: bool
  CMediumTodoEnvelope* {.importc: "nim_simdjson_medium_todo_envelope", header: "simdjson_shim.h", bycopy.} = object
    status*: uint32
    owned_json*: cstring
    owned_json_len*: csize_t
    todos*: ptr CMediumTodoItem
    todos_len*: csize_t
    page*: int64
    count*: int64
    arena_state*: pointer
  CNestedStringItem* {.importc: "nim_simdjson_nested_string_item", header: "simdjson_shim.h", bycopy.} = object
    data*: cstring
    len*: csize_t
  CNestedPermissionItem* {.importc: "nim_simdjson_nested_permission_item", header: "simdjson_shim.h", bycopy.} = object
    scope_data*: cstring
    scope_len*: csize_t
    allowed*: bool
  CNestedOwnerItem* {.importc: "nim_simdjson_nested_owner_item", header: "simdjson_shim.h", bycopy.} = object
    id*: int64
    name_data*: cstring
    name_len*: csize_t
    permissions*: ptr CNestedPermissionItem
    permissions_len*: csize_t
  CNestedCommentItem* {.importc: "nim_simdjson_nested_comment_item", header: "simdjson_shim.h", bycopy.} = object
    author_data*: cstring
    author_len*: csize_t
    message_data*: cstring
    message_len*: csize_t
    score*: int64
  CNestedTaskItem* {.importc: "nim_simdjson_nested_task_item", header: "simdjson_shim.h", bycopy.} = object
    id*: int64
    title_data*: cstring
    title_len*: csize_t
    completed*: bool
    tags*: ptr CNestedStringItem
    tags_len*: csize_t
    comments*: ptr CNestedCommentItem
    comments_len*: csize_t
  CNestedProjectStats* {.importc: "nim_simdjson_nested_project_stats", header: "simdjson_shim.h", bycopy.} = object
    open_count*: int64
    closed_count*: int64
    velocity*: cdouble
  CNestedProjectItem* {.importc: "nim_simdjson_nested_project_item", header: "simdjson_shim.h", bycopy.} = object
    project_id*: int64
    name_data*: cstring
    name_len*: csize_t
    active*: bool
    owners*: ptr CNestedOwnerItem
    owners_len*: csize_t
    tasks*: ptr CNestedTaskItem
    tasks_len*: csize_t
    stats*: CNestedProjectStats
  CNestedProjectEnvelope* {.importc: "nim_simdjson_nested_project_envelope", header: "simdjson_shim.h", bycopy.} = object
    status*: uint32
    projects*: ptr CNestedProjectItem
    projects_len*: csize_t
    page*: int64
    count*: int64
    arena_state*: pointer
  CNativePlanNode* {.importc: "nim_simdjson_native_plan_node", header: "simdjson_shim.h", bycopy.} = object
    name*: cstring
    name_len*: csize_t
    name_hash*: uint64
    first_char*: uint8
    kind*: cint
    child_count*: csize_t
    subtree_size*: csize_t
  CNativeValue* {.importc: "nim_simdjson_native_value", header: "simdjson_shim.h", bycopy.} = object
    status*: uint32
    found_kind*: cint
    data*: cstring
    data_len*: csize_t
    bool_value*: bool
    int64_value*: int64
    uint64_value*: uint64
    double_value*: cdouble
    children*: ptr CNativeValue
    children_len*: csize_t
    arena_state*: pointer

## Parses the JSON in `data` and stores the resulting `CDoc` in `outDoc`.
proc simdjsonParse*(data: cstring, len: csize_t, outDoc: ptr ptr CDoc): uint32 {.
  importc: "nim_simdjson_parse",
  header: "simdjson_shim.h"
.}
## Returns true when the bytes in `data` are valid JSON.
proc simdjsonIsValid*(data: cstring, len: csize_t): bool {.
  importc: "nim_simdjson_is_valid",
  header: "simdjson_shim.h"
.}
## Sets the per-thread nesting depth limit for ondemand parses; zero restores the library default.
proc simdjsonSetOndemandMaxDepth*(limit: csize_t): uint32 {.
  importc: "nim_simdjson_set_ondemand_max_depth",
  header: "simdjson_shim.h"
.}
## Sets the per-thread maximum number of items allowed in any decoded array; zero removes the limit.
proc simdjsonSetOndemandMaxArrayItems*(limit: csize_t): uint32 {.
  importc: "nim_simdjson_set_ondemand_max_array_items",
  header: "simdjson_shim.h"
.}
## Validates the entire document via a full ondemand token walk (no DOM materialization).
## Returns the success code when valid, or the first simdjson error encountered.
proc simdjsonOndemandValidate*(data: cstring, len: csize_t): uint32 {.
  importc: "nim_simdjson_ondemand_validate",
  header: "simdjson_shim.h"
.}
## Releases a `CDoc` previously returned by `simdjsonParse`.
proc simdjsonDocFree*(doc: ptr CDoc) {.
  importc: "nim_simdjson_doc_free",
  header: "simdjson_shim.h"
.}
## Retrieves the root value handle of `doc` into `outHandle`.
proc simdjsonDocRoot*(doc: ptr CDoc, outHandle: ptr CValueHandle): uint32 {.
  importc: "nim_simdjson_doc_root",
  header: "simdjson_shim.h"
.}
## Retrieves the JSON kind of the value at `handle` into `outKind`.
proc simdjsonValueKind*(doc: ptr CDoc, handle: CValueHandle, outKind: ptr cint): uint32 {.
  importc: "nim_simdjson_value_kind",
  header: "simdjson_shim.h"
.}
## Retrieves the element count of the value at `handle` into `outLen`.
proc simdjsonValueLen*(doc: ptr CDoc, handle: CValueHandle, outLen: ptr csize_t): uint32 {.
  importc: "nim_simdjson_value_len",
  header: "simdjson_shim.h"
.}
## Retrieves the string data of the value at `handle`.
proc simdjsonValueGetString*(
  doc: ptr CDoc,
  handle: CValueHandle,
  outData: ptr cstring,
  outLen: ptr csize_t
): uint32 {.
  importc: "nim_simdjson_value_get_string",
  header: "simdjson_shim.h"
.}
## Retrieves the boolean of the value at `handle` into `outValue`.
proc simdjsonValueGetBool*(doc: ptr CDoc, handle: CValueHandle, outValue: ptr bool): uint32 {.
  importc: "nim_simdjson_value_get_bool",
  header: "simdjson_shim.h"
.}
## Retrieves the int64 of the value at `handle` into `outValue`.
proc simdjsonValueGetInt64*(doc: ptr CDoc, handle: CValueHandle, outValue: ptr int64): uint32 {.
  importc: "nim_simdjson_value_get_int64",
  header: "simdjson_shim.h"
.}
## Retrieves the uint64 of the value at `handle` into `outValue`.
proc simdjsonValueGetUint64*(doc: ptr CDoc, handle: CValueHandle, outValue: ptr uint64): uint32 {.
  importc: "nim_simdjson_value_get_uint64",
  header: "simdjson_shim.h"
.}
## Retrieves the double of the value at `handle` into `outValue`.
proc simdjsonValueGetDouble*(doc: ptr CDoc, handle: CValueHandle, outValue: ptr cdouble): uint32 {.
  importc: "nim_simdjson_value_get_double",
  header: "simdjson_shim.h"
.}
## Checks whether the object at `handle` contains the key `key`.
proc simdjsonValueContainsKey*(
  doc: ptr CDoc,
  handle: CValueHandle,
  key: cstring,
  keyLen: csize_t,
  outPresent: ptr bool
): uint32 {.
  importc: "nim_simdjson_value_contains_key",
  header: "simdjson_shim.h"
.}
## Retrieves the kind of the child value for `key` in the object at `handle`.
proc simdjsonValueKeyKind*(
  doc: ptr CDoc,
  handle: CValueHandle,
  key: cstring,
  keyLen: csize_t,
  outKind: ptr cint
): uint32 {.
  importc: "nim_simdjson_value_key_kind",
  header: "simdjson_shim.h"
.}
## Retrieves the child value handle for `key` in the object at `handle`.
proc simdjsonValueGetKey*(
  doc: ptr CDoc,
  handle: CValueHandle,
  key: cstring,
  keyLen: csize_t,
  outChild: ptr CValueHandle
): uint32 {.
  importc: "nim_simdjson_value_get_key",
  header: "simdjson_shim.h"
.}
## Retrieves the string child value for `key` in the object at `handle`.
proc simdjsonValueGetKeyString*(
  doc: ptr CDoc,
  handle: CValueHandle,
  key: cstring,
  keyLen: csize_t,
  outData: ptr cstring,
  outLen: ptr csize_t
): uint32 {.
  importc: "nim_simdjson_value_get_key_string",
  header: "simdjson_shim.h"
.}
## Retrieves the boolean child value for `key` in the object at `handle`.
proc simdjsonValueGetKeyBool*(
  doc: ptr CDoc,
  handle: CValueHandle,
  key: cstring,
  keyLen: csize_t,
  outValue: ptr bool
): uint32 {.
  importc: "nim_simdjson_value_get_key_bool",
  header: "simdjson_shim.h"
.}
## Retrieves the int64 child value for `key` in the object at `handle`.
proc simdjsonValueGetKeyInt64*(
  doc: ptr CDoc,
  handle: CValueHandle,
  key: cstring,
  keyLen: csize_t,
  outValue: ptr int64
): uint32 {.
  importc: "nim_simdjson_value_get_key_int64",
  header: "simdjson_shim.h"
.}
## Retrieves the uint64 child value for `key` in the object at `handle`.
proc simdjsonValueGetKeyUint64*(
  doc: ptr CDoc,
  handle: CValueHandle,
  key: cstring,
  keyLen: csize_t,
  outValue: ptr uint64
): uint32 {.
  importc: "nim_simdjson_value_get_key_uint64",
  header: "simdjson_shim.h"
.}
## Retrieves the object child handle for `key` in the object at `handle`.
proc simdjsonValueGetKeyObject*(
  doc: ptr CDoc,
  handle: CValueHandle,
  key: cstring,
  keyLen: csize_t,
  outChild: ptr CValueHandle
): uint32 {.
  importc: "nim_simdjson_value_get_key_object",
  header: "simdjson_shim.h"
.}
## Retrieves the array child handle for `key` in the object at `handle`.
proc simdjsonValueGetKeyArray*(
  doc: ptr CDoc,
  handle: CValueHandle,
  key: cstring,
  keyLen: csize_t,
  outChild: ptr CValueHandle
): uint32 {.
  importc: "nim_simdjson_value_get_key_array",
  header: "simdjson_shim.h"
.}
## Reads the fields described by `entries` from the object at `handle` in one pass.
proc simdjsonValueProject*(
  doc: ptr CDoc,
  handle: CValueHandle,
  entries: ptr CProjectEntry,
  count: csize_t
): uint32 {.
  importc: "nim_simdjson_value_project",
  header: "simdjson_shim.h"
.}
## Retrieves the handle of array element `index` of the array at `handle`.
proc simdjsonValueGetIndex*(
  doc: ptr CDoc,
  handle: CValueHandle,
  index: csize_t,
  outChild: ptr CValueHandle
): uint32 {.
  importc: "nim_simdjson_value_get_index",
  header: "simdjson_shim.h"
.}
## Writes the handles of up to `count` elements of the array at `handle` into `outChildren`.
proc simdjsonValueGetArrayChildren*(
  doc: ptr CDoc,
  handle: CValueHandle,
  outChildren: ptr CValueHandle,
  count: csize_t
): uint32 {.
  importc: "nim_simdjson_value_get_array_children",
  header: "simdjson_shim.h"
.}
## Resolves the JSON pointer `pointer` from `handle` into `outChild`.
proc simdjsonValueAtPointer*(
  doc: ptr CDoc,
  handle: CValueHandle,
  pointer: cstring,
  pointerLen: csize_t,
  outChild: ptr CValueHandle
): uint32 {.
  importc: "nim_simdjson_value_at_pointer",
  header: "simdjson_shim.h"
.}
## Captures the top-level JSON value in `data` as an on-demand value.
proc simdjsonOndemandCapture*(data: cstring, len: csize_t, outValue: ptr COndemandValue): uint32 {.
  importc: "nim_simdjson_ondemand_capture",
  header: "simdjson_shim.h"
.}
## Reads the top-level object fields described by `entries` in one pass.
proc simdjsonOndemandProjectObject*(
  data: cstring,
  len: csize_t,
  entries: ptr COndemandEntry,
  count: csize_t
): uint32 {.
  importc: "nim_simdjson_ondemand_project_object",
  header: "simdjson_shim.h"
.}
## Reads `fieldsPerItem` fields from each of the top-level array objects into `entries`.
proc simdjsonOndemandProjectArrayObjects*(
  data: cstring,
  len: csize_t,
  entries: ptr COndemandEntry,
  itemCount: csize_t,
  fieldsPerItem: csize_t
): uint32 {.
  importc: "nim_simdjson_ondemand_project_array_objects",
  header: "simdjson_shim.h"
.}
## Retrieves the element count of the top-level array in `data` into `outLen`.
proc simdjsonOndemandArrayLength*(data: cstring, len: csize_t, outLen: ptr csize_t): uint32 {.
  importc: "nim_simdjson_ondemand_array_length",
  header: "simdjson_shim.h"
.}
## Captures up to `count` elements of the top-level array into `items`.
proc simdjsonOndemandCaptureArray*(
  data: cstring,
  len: csize_t,
  items: ptr COndemandValue,
  count: csize_t
): uint32 {.
  importc: "nim_simdjson_ondemand_capture_array",
  header: "simdjson_shim.h"
.}
## Releases the resources held by the on-demand `value`.
proc simdjsonOndemandValueRelease*(value: ptr COndemandValue) {.
  importc: "nim_simdjson_ondemand_value_release",
  header: "simdjson_shim.h"
.}
## Releases the resources held by the on-demand `entry`.
proc simdjsonOndemandEntryRelease*(entry: ptr COndemandEntry) {.
  importc: "nim_simdjson_ondemand_entry_release",
  header: "simdjson_shim.h"
.}
## Releases `count` on-demand entries starting at `entries`.
proc simdjsonOndemandEntriesRelease*(entries: ptr COndemandEntry, count: csize_t) {.
  importc: "nim_simdjson_ondemand_entries_release",
  header: "simdjson_shim.h"
.}
## Releases `count` on-demand values starting at `items`.
proc simdjsonOndemandValuesRelease*(items: ptr COndemandValue, count: csize_t) {.
  importc: "nim_simdjson_ondemand_values_release",
  header: "simdjson_shim.h"
.}
## Extracts the medium-sized todo list envelope from `data` in one pass.
proc simdjsonExtractMediumTodoEnvelope*(data: cstring, len: csize_t, outEnvelope: ptr CMediumTodoEnvelope): uint32 {.
  importc: "nim_simdjson_extract_medium_todo_envelope",
  header: "simdjson_shim.h"
.}
## Releases the memory owned by the extracted `envelope`.
proc simdjsonMediumTodoEnvelopeRelease*(envelope: ptr CMediumTodoEnvelope) {.
  importc: "nim_simdjson_medium_todo_envelope_release",
  header: "simdjson_shim.h"
.}
## Extracts the nested project envelope from `data` in one pass.
proc simdjsonExtractNestedProjectEnvelope*(data: cstring, len: csize_t, outEnvelope: ptr CNestedProjectEnvelope): uint32 {.
  importc: "nim_simdjson_extract_nested_project_envelope",
  header: "simdjson_shim.h"
.}
## Releases the memory owned by the extracted `envelope`.
proc simdjsonNestedProjectEnvelopeRelease*(envelope: ptr CNestedProjectEnvelope) {.
  importc: "nim_simdjson_nested_project_envelope_release",
  header: "simdjson_shim.h"
.}
## Extracts a native parse plan of up to `planLen` nodes from `data` in one pass.
proc simdjsonExtractNativePlan*(
  data: cstring,
  len: csize_t,
  plan: ptr CNativePlanNode,
  planLen: csize_t,
  outRoot: ptr CNativeValue
): uint32 {.
  importc: "nim_simdjson_extract_native_plan",
  header: "simdjson_shim.h"
.}
## Releases the arena memory owned by the extracted `value`.
proc simdjsonNativeValueRelease*(value: ptr CNativeValue) {.
  importc: "nim_simdjson_native_value_release",
  header: "simdjson_shim.h"
.}
## Returns the static error message for the simdjson status `code`.
proc simdjsonErrorMessage*(code: uint32): cstring {.
  importc: "nim_simdjson_error_message",
  header: "simdjson_shim.h"
.}
## Returns the status code that indicates a successful operation.
proc simdjsonSuccessCode*(): uint32 {.
  importc: "nim_simdjson_success_code",
  header: "simdjson_shim.h"
.}
## Returns the status code for a missing object field.
proc simdjsonNoSuchFieldCode*(): uint32 {.
  importc: "nim_simdjson_no_such_field_code",
  header: "simdjson_shim.h"
.}
## Returns the status code for an array index out of bounds.
proc simdjsonIndexOutOfBoundsCode*(): uint32 {.
  importc: "nim_simdjson_index_out_of_bounds_code",
  header: "simdjson_shim.h"
.}
## Returns the status code for a value with an unexpected JSON type.
proc simdjsonIncorrectTypeCode*(): uint32 {.
  importc: "nim_simdjson_incorrect_type_code",
  header: "simdjson_shim.h"
.}
