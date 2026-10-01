import std/[sequtils, streams, strutils, tables, unittest]
import jsony

import ../../nim_fastjson
import ../direct_engine

type
  Todo = object
    id: int
    title: string
    completed: bool

  Envelope = object
    todos: seq[Todo]
    nextCursor: string

  BorrowedTodo = object
    id: int
    title: JsonStringView
    completed: bool

  BorrowedEnvelope = object
    todos: seq[BorrowedTodo]
    nextCursor: JsonStringView

  HistoricalLike = object
    date: string
    description: string
    lang: string

  TableValue = object
    name: string
    count: int

  SafeRecord = object
    title: JsonSafeString
    tag: JsonAsciiSafeString

  ControlStringPayload = object
    s: string

  ItemsOnly = object
    items: seq[int]

  WideIntRow = object
    i64: int64
    u64: uint64

suite "nim_fastjson core":
  let fj = initFastJson()

  test "explicit options object can be passed to constructor":
    var options = defaultFastJsonOptions()
    options.indentOutput = true
    options.indentStep = 4
    let configured = initFastJson(options)
    check configured.options.indentOutput
    check configured.options.indentStep == 4

  test "unsupported output options fail instead of being silently ignored":
    var options = defaultFastJsonOptions()
    options.indentOutput = true
    let configured = initFastJson(options)
    expect nim_fastjson.JsonError:
      discard configured.serialize(Todo(id: 1, title: "cfg", completed: false))

  test "unsupported decode policy options fail instead of being silently ignored":
    var options = defaultFastJsonOptions()
    options.unknownFieldPolicy = fjufpError
    let configured = initFastJson(options)
    expect nim_fastjson.JsonError:
      discard configured.deserialize("""{"id":1,"title":"cfg","completed":false,"extra":1}""", Todo)

  test "maxDepth option is enforced before decode backend selection":
    var options = defaultFastJsonOptions()
    options.maxDepth = 1
    let configured = initFastJson(options)
    expect nim_fastjson.JsonError:
      discard configured.deserialize("""{"todos":[{"id":1,"title":"a","completed":false}],"nextCursor":"p2"}""", Envelope)

  test "serialize matches expected flat object":
    let todo = Todo(id: 7, title: "ship", completed: true)
    let encoded = fj.serialize(todo)
    check encoded == """{"id":7,"title":"ship","completed":true}"""

  test "seq object integer batch handles full 64-bit width":
    let rows = @[
      WideIntRow(i64: low(int64), u64: high(uint64)),
      WideIntRow(i64: high(int64), u64: 0'u64)
    ]
    check fj.serialize(rows) ==
      """[{"i64":-9223372036854775808,"u64":18446744073709551615},{"i64":9223372036854775807,"u64":0}]"""

  test "deserialize roundtrip handles objects and arrays":
    let payload = """{"todos":[{"id":1,"title":"a","completed":false},{"id":2,"title":"b","completed":true}],"nextCursor":"p2"}"""
    let parsed = fj.deserialize(payload, Envelope)
    check parsed.todos.len == 2
    check parsed.todos[0].id == 1
    check parsed.todos[1].title == "b"
    check parsed.todos[1].completed
    check parsed.nextCursor == "p2"

  test "deserialize skips unknown fields":
    let payload = """{"id":11,"title":"x","completed":false,"extra":{"nested":[1,2,3]}}"""
    let parsed = fj.deserialize(payload, Todo)
    check parsed.id == 11
    check parsed.title == "x"
    check parsed.completed == false

  test "deserialize from bytes works":
    let payload = cast[seq[byte]](@[byte('{'), byte('"'), byte('i'), byte('d'), byte('"'), byte(':'), byte('3'), byte(','), byte('"'), byte('t'), byte('i'), byte('t'), byte('l'), byte('e'), byte('"'), byte(':'), byte('"'), byte('o'), byte('k'), byte('"'), byte(','), byte('"'), byte('c'), byte('o'), byte('m'), byte('p'), byte('l'), byte('e'), byte('t'), byte('e'), byte('d'), byte('"'), byte(':'), byte('t'), byte('r'), byte('u'), byte('e'), byte('}')])
    let parsed = fj.deserialize(payload, Todo)
    check parsed.id == 3
    check parsed.title == "ok"
    check parsed.completed

  test "escape handling matches jsony on representative payload":
    let todo = Todo(id: 5, title: "line\n\"quoted\"", completed: false)
    check fj.serialize(todo) == jsony.toJson(todo)

  test "serialize control-heavy object string without buffer overrun":
    let raw = repeat("\x01", 20_000)
    let encoded = fj.serialize(ControlStringPayload(s: raw))
    check encoded.len == "{\"s\":\"".len + raw.len * "\\u0001".len + "\"}".len
    check encoded.startsWith("""{"s":"\u0001\u0001""")
    check encoded.endsWith("""\u0001"}""")

  test "deserialize rejects invalid UTF-8 hidden in unknown fields":
    let bad = "{\"bad\":\"" & "\xC3\x28" & "\",\"items\":[1]}"
    expect nim_fastjson.JsonError:
      discard fj.deserialize(bad, ItemsOnly)

  test "invalid json raises JsonError":
    var raised = false
    try:
      discard fj.deserialize("""{"id":1,"title":"oops","completed":}""", Todo)
    except nim_fastjson.JsonError:
      raised = true
    check raised

  test "simd-backed object rejects malformed known and unknown field values":
    expect nim_fastjson.JsonError:
      discard fj.deserialize("""{"id":abc}""", Todo)
    expect nim_fastjson.JsonError:
      discard fj.deserialize("""{"unknown":abc,"id":1,"title":"ok"}""", Todo)

  test "simd-backed object rejects invalid UTF-8 before typed decode":
    let bad = "{\"id\":1,\"title\":\"bad\xC3\x28\",\"completed\":false}"
    expect nim_fastjson.JsonError:
      discard fj.deserialize(bad, Todo)

  test "jsonSafe pragma skips escape scanning":
    type
      SafeTodo = object
        id: int
        name {.jsonSafe.}: string
        tag {.jsonSafe.}: string
        completed: bool
    let safe = SafeTodo(id: 1, name: "hello", tag: "abc", completed: true)
    check fj.serialize(safe) == """{"id":1,"name":"hello","tag":"abc","completed":true}"""
    # Round-trip with normal deserialization
    let parsed = fj.deserialize(fj.serialize(safe), SafeTodo)
    check parsed.name == "hello"
    check parsed.tag == "abc"

  test "safe string wrapper types route through unescaped serializer path":
    type
      WrappedSafeTodo = object
        id: int
        name: JsonSafeString
        tag: JsonAsciiSafeString
        completed: bool
    let wrapped = WrappedSafeTodo(
      id: 1,
      name: JsonSafeString("hello"),
      tag: JsonAsciiSafeString("abc"),
      completed: true
    )
    check fj.serialize(wrapped) == """{"id":1,"name":"hello","tag":"abc","completed":true}"""

  test "top-level safe string wrapper values serialize as JSON strings":
    check fj.serialize(JsonSafeString("hello")) == "\"hello\""
    check fj.serialize(JsonAsciiSafeString("abc")) == "\"abc\""

  test "safe string wrappers serialize in seq and table containers":
    let safeSeq = @[JsonSafeString("a"), JsonSafeString("b")]
    check fj.serialize(safeSeq) == """["a","b"]"""

    var safeTable = initTable[string, JsonSafeString]()
    safeTable["x"] = JsonSafeString("one")
    safeTable["y"] = JsonSafeString("two")
    let encoded = fj.serialize(safeTable)
    check encoded.contains("\"x\":\"one\"")
    check encoded.contains("\"y\":\"two\"")

  test "safe-string-only seq object roots use the routed root writer correctly":
    let rows = @[
      SafeRecord(title: JsonSafeString("hello"), tag: JsonAsciiSafeString("x")),
      SafeRecord(title: JsonSafeString("world"), tag: JsonAsciiSafeString("y"))
    ]
    check fj.serialize(rows) == """[{"title":"hello","tag":"x"},{"title":"world","tag":"y"}]"""

  test "safe-string-only object maps use the routed root writer correctly":
    var safeTable = initTable[string, SafeRecord]()
    safeTable["first"] = SafeRecord(title: JsonSafeString("hello"), tag: JsonAsciiSafeString("x"))
    safeTable["second"] = SafeRecord(title: JsonSafeString("world"), tag: JsonAsciiSafeString("y"))
    let tableEncoded = fj.serialize(safeTable)
    check tableEncoded.contains("\"first\":{\"title\":\"hello\",\"tag\":\"x\"}")
    check tableEncoded.contains("\"second\":{\"title\":\"world\",\"tag\":\"y\"}")

    var orderedSafeTable = initOrderedTable[string, SafeRecord]()
    orderedSafeTable["first"] = SafeRecord(title: JsonSafeString("hello"), tag: JsonAsciiSafeString("x"))
    orderedSafeTable["second"] = SafeRecord(title: JsonSafeString("world"), tag: JsonAsciiSafeString("y"))
    check fj.serialize(orderedSafeTable) ==
      """{"first":{"title":"hello","tag":"x"},"second":{"title":"world","tag":"y"}}"""

  test "serialize root shape classification exposes generic shape families":
    check selectedSerializeRootShape(seq[Todo]) == jsrsSeqObject
    check selectedSerializeRootShape(Table[string, TableValue]) == jsrsTableObject
    check selectedSerializeRootShape(OrderedTable[string, TableValue]) == jsrsTableObject
    check selectedSerializeRootShape(seq[seq[seq[float64]]]) == jsrsNumericTree
    check selectedSerializeRootShape(Todo) == jsrsGeneric

  test "numeric-tree root writer preserves nested float json output":
    let coords3 = @[
      @[
        @[1.25, 2.5, 0.0],
        @[3.75, 4.5, 0.0]
      ]
    ]
    check fj.serialize(coords3) == jsony.toJson(coords3)

    let coords4 = @[
      @[
        @[
          @[1.25, 2.5, 0.0],
          @[3.75, 4.5, 0.0]
        ]
      ]
    ]
    check fj.serialize(coords4) == jsony.toJson(coords4)

  test "skewed nested integer seq grows cursor buffer safely":
    let payload = @[@[], @[], (0..<2000).toSeq, @[], @[]]
    let encoded = fj.serialize(payload)
    check encoded == jsony.toJson(payload)
    check encoded.startsWith("[[],[],[0,1,2")
    check encoded.contains("1998,1999")
    check encoded.endsWith("],[],[]]")
    check fj.deserialize(encoded, seq[seq[int]]) == payload

  test "stream and bytes instance APIs roundtrip":
    let todo = Todo(id: 9, title: "stream", completed: false)
    let bytes = fj.serializeToBytes(todo)
    check fj.deserialize(bytes, Todo) == todo

    var stream = newStringStream()
    fj.serializeToStream(stream, todo)
    stream.setPosition(0)
    check fj.deserialize(stream, Todo) == todo

  test "borrowed string types route through simd backend":
    let payload = """{"todos":[{"id":1,"title":"a","completed":false},{"id":2,"title":"b","completed":true}],"nextCursor":"p2"}"""
    check selectedDeserializeEngine(BorrowedEnvelope) == fjeSimdjson
    check selectedDeserializePath(BorrowedEnvelope) == fjdpSimdBorrowed
    let parsed = fj.deserialize(payload, BorrowedEnvelope)
    check parsed.todos.len == 2
    check parsed.todos[1].title.toString() == "b"
    check parsed.nextCursor.toString() == "p2"
    check fj.serialize(parsed) == payload

  test "leaf direct-decode types use bounded simd fast path":
    let payload = """{"id":11,"title":"x","completed":false}"""
    check directLeafDecodeSupported(Todo)
    check not directNestedDecodeSupported(Todo)
    check not borrowedTypedDecodeSupported(Todo)
    check selectedDeserializePath(Todo) == fjdpSimdLeaf
    check selectedDeserializeEngine(Todo) == fjeSimdjson
    let parsed = fj.deserialize(payload, Todo)
    check parsed == Todo(id: 11, title: "x", completed: false)

  test "nested direct-decode support is exposed without auto-routing":
    check not directLeafDecodeSupported(Envelope)
    check directNestedDecodeSupported(Envelope)
    check selectedDeserializePath(Envelope) == fjdpSimdNested
    check selectedDeserializeEngine(Envelope) == fjeDirect

  test "decode plan groundwork exposes field kinds":
    let todoPlan = jsonDecodePlan(Todo)
    check todoPlan.fields.len == 3
    check todoPlan.fields[0].name == "id"
    check todoPlan.fields[0].keyLen == 2
    check todoPlan.fields[0].kind == jdfkSignedInt
    check todoPlan.fields[1].kind == jdfkString
    check todoPlan.fields[2].kind == jdfkBool

    let envelopePlan = jsonDecodePlan(Envelope)
    check envelopePlan.fields.len == 2
    check envelopePlan.fields[0].kind == jdfkSeq
    check envelopePlan.fields[1].kind == jdfkString

  test "string field metadata groundwork collects row-order scan data":
    check stringFieldCount(HistoricalLike) == 3
    let rows = @[
      HistoricalLike(date: "2024-01-01", description: "safe text", lang: "en"),
      HistoricalLike(date: "2024-01-02", description: "line\nbreak", lang: "")
    ]
    let batch = debugCollectStringScanBatch(rows)
    check batch.len == 6
    check batch[0] == (10, 10)      # date fully safe
    check batch[1] == (9, 9)        # description fully safe
    check batch[2] == (2, 2)        # lang fully safe
    check batch[3] == (10, 10)      # second date fully safe
    check batch[4] == (10, 4)       # newline detected at index 4
    check batch[5] == (0, 0)        # empty string

  test "escaped string staging groundwork materializes row-order bodies":
    let rows = @[
      HistoricalLike(date: "2024-01-01", description: "safe text", lang: "en"),
      HistoricalLike(date: "2024-01-02", description: "line\nbreak", lang: "")
    ]
    let staged = debugStageStringBodies(rows)
    check staged.len == 6
    check staged[0] == "2024-01-01\""
    check staged[1] == "safe text\""
    check staged[2] == "en\""
    check staged[3] == "2024-01-02\""
    check staged[4] == "line\\nbreak\""
    check staged[5] == "\""

  test "string-only seq object path preserves json output":
    let rows = @[
      HistoricalLike(date: "2024-01-01", description: "safe text", lang: "en"),
      HistoricalLike(date: "2024-01-02", description: "line\nbreak", lang: "")
    ]
    check fj.serialize(rows) == jsony.toJson(rows)
    check debugSerializeStringOnlySeqDirect(rows) == jsony.toJson(rows)

suite "simd native plan security limits":
  type
    Inner3 = object
      c*: int
    Inner2 = object
      b*: seq[Inner3]
    DeepEnv = object
      a*: seq[Inner2]

  test "maxDepth is enforced on the native plan decode path":
    var options = defaultFastJsonOptions()
    options.maxDepth = 2
    let configured = initFastJson(options)
    let doc = """{"a":[{"b":[{"c":1}]}]}"""
    expect nim_fastjson.JsonError:
      discard configured.deserialize(doc, DeepEnv)

  test "maxArrayItems is enforced on the native plan decode path":
    var options = defaultFastJsonOptions()
    options.maxArrayItems = 2
    let configured = initFastJson(options)
    let doc = """{"a":[{"b":[{"c":1}]},{"b":[{"c":2}]},{"b":[{"c":3}]}]}"""
    expect nim_fastjson.JsonError:
      discard configured.deserialize(doc, DeepEnv)
