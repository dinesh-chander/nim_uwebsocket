import std/[parseutils, sequtils, streams, strutils, tables, unittest, unicode]
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

  test "borrowed string types decode with zero-copy direct-engine views":
    let payload = """{"todos":[{"id":1,"title":"a","completed":false},{"id":2,"title":"b","completed":true}],"nextCursor":"p2"}"""
    check selectedDeserializeEngine(BorrowedEnvelope) == fjeDirect
    check selectedDeserializePath(BorrowedEnvelope) == fjdpDirect
    let parsed = fj.deserialize(payload, BorrowedEnvelope)
    check parsed.todos.len == 2
    check parsed.todos[1].title.toString() == "b"
    check parsed.nextCursor.toString() == "p2"
    check fj.serialize(parsed) == payload

  test "borrowed views stay valid after the document is dropped":
    var parsed: BorrowedEnvelope
    block:
      let payload = """{"todos":[{"id":1,"title":"first ésc","completed":false},{"id":2,"title":"second \u00e9sc","completed":true}],"nextCursor":"p2"}"""
      parsed = fj.deserialize(payload, BorrowedEnvelope)
    for _ in 0 ..< 4:
      let filler = newString(4096)
      discard filler.len
      GC_fullCollect()
    check parsed.todos[0].title.toString() == "first \u00e9sc"
    check parsed.todos[1].title.toString() == "second ésc"
    check parsed.nextCursor.toString() == "p2"

  test "leaf direct-decode types route to the direct engine":
    let payload = """{"id":11,"title":"x","completed":false}"""
    check directLeafDecodeSupported(Todo)
    check not directNestedDecodeSupported(Todo)
    check not borrowedTypedDecodeSupported(Todo)
    check selectedDeserializePath(Todo) == fjdpDirect
    check selectedDeserializeEngine(Todo) == fjeDirect
    let parsed = fj.deserialize(payload, Todo)
    check parsed == Todo(id: 11, title: "x", completed: false)

  test "nested direct-decode support is exposed without auto-routing":
    check not directLeafDecodeSupported(Envelope)
    check directNestedDecodeSupported(Envelope)
    check selectedDeserializePath(Envelope) == fjdpDirect
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
suite "escaped string regression (nested seq-of-object fields)":
  type
    Mention = object
      screenName*: string
      id*: int64
    Tweet = object
      id*: int64
      text*: string
      mentions*: seq[Mention]
    Envelope = object
      cursor*: string
      statuses*: seq[Tweet]

  # Documents built so the runtime JSON text contains real escape sequences
  # (single backslash). Triple-quoted Nim strings treat backslashes as
  # literal, so the literals below hold exactly one backslash per escape.
  # A self-check asserts the runtime document content before decoding.
  let fj = initFastJson()
  let esc = '\\' & "u0041"

  test "unicode escape in nested item string field":
    let doc = """{"cursor":"abc","statuses":[{"id":1,"text":"hello """ & esc & """ world","mentions":[]}]}"""
    check doc[doc.find("hello ") + 6] == '\\'
    let e = fj.deserialize(doc, Envelope)
    check e.cursor == "abc"
    check e.statuses[0].text == "hello A world"

  test "unicode escape in nested mention string field":
    let doc = """{"cursor":"","statuses":[{"id":1,"text":"x","mentions":[{"screenName":"al""" & '\\' & """u0069ce","id":10}]}]}"""
    let e = fj.deserialize(doc, Envelope)
    check e.statuses[0].mentions[0].screenName == "alice"

  test "backslash and control escapes in nested item string field":
    let doc = """{"cursor":"","statuses":[{"id":7,"text":"tab\there \\ slash \"quoted\"","mentions":[]}]}"""
    let e = fj.deserialize(doc, Envelope)
    check e.statuses[0].text == "tab\there \\ slash \"quoted\""

  test "surrogate pair escape in nested item string field":
    let doc = """{"cursor":"","statuses":[{"id":9,"text":"emoji """ & '\\' & """uD83D""" & '\\' & """uDD12 end","mentions":[]}]}"""
    let e = fj.deserialize(doc, Envelope)
    check e.statuses[0].text == "emoji " & $Rune(0x1F512) & " end"

suite "integer digit-chunk regression (GEN-054 table)":
  type
    IntWrap = object
      v: int64
  test "serialize hits every three-digit chunk including >=642":
    let fj = initFastJson()
    let values = [0'i64, 999, 1000, 1001, 1642, 1643, 1644, 999999, 1000000,
                  1_000_642, 643_642_643, 9_876_543_210, 999_999_999_999_999_999,
                  -1642, -9_876_543_210, high(int64), low(int64), 4_294_967_296]
    for v in values:
      let doc = fj.serialize(IntWrap(v: v))
      check doc == "{\"v\":" & $v & "}"

  test "round-trip int64 values across chunk boundaries":
    let fj = initFastJson()
    for v in [642'i64, 643, 644, 664_200, 664_300, 999_999, 1_642_643, 8_888_642_000]:
      let doc = fj.serialize(IntWrap(v: v))
      check fj.deserialize(doc, IntWrap).v == v

suite "unsigned overflow guard and borrowed utf8 span regression":
  type
    UIntWrap = object
      v: uint64
    StrWrap = object
      s: string

  test "uint64 samples below the max parse":
    let fj = initFastJson()
    let docs = ["0", "9", "18446744073709551615", "1234567890123456789",
                "12345678901234567", "123456789012345678"]
    let want = [0'u64, 9'u64, 18446744073709551615'u64, 1234567890123456789'u64,
                12345678901234567'u64, 123456789012345678'u64]
    for k in 0 ..< docs.len:
      let doc = "{\"v\":" & docs[k] & "}"
      check fj.deserialize(doc, UIntWrap).v == want[k]

  test "uint64 overflow is rejected":
    let fj = initFastJson()
    let over = ["18446744073709551616", "99999999999999999999",
                "1234567890123456789012345",
                "123456789012345678901234567890123456789"]
    for raw in over:
      expect nim_fastjson.JsonError:
        discard fj.deserialize("{\"v\":" & raw & "}", UIntWrap)

  test "multi-byte utf8 string decodes through borrowed span":
    let fj = initFastJson()
    let payload = "caf" & "\xC3\xA9" & " \xE2\x98\x83 \xF0\x9F\x98\x80 end"
    let doc = "{\"s\":\"" & payload & "\"}"
    check fj.deserialize(doc, StrWrap).s == payload

  test "invalid utf8 inside a string is rejected":
    let fj = initFastJson()
    expect nim_fastjson.JsonError:
      discard fj.deserialize("{\"s\":\"bad \xC3\x28 tail\"}", StrWrap)

  # --- Float parse-accuracy regression tests ---

  proc parseF(t: string): float64 =
    var f: float64
    var i = 0
    parseValue(t, i, f)
    f

  test "float parse matches stdlib for trailing-zero decimal (a)":
    # "1.980020" used to double-round via intPart + fracPart/fracScale
    var expected: float64
    discard parseutils.parseFloat("1.980020", expected, 0)
    check parseF("1.980020") == expected

  test "float parse round-trip stability for exponent forms (b)":
    # These values were unstable: parse -> $ -> reparse gave different bits.
    for t in @["65722e-4", "-5565e-3", "14534264322e-10"]:
      let a = parseF(t)
      let b = parseF($a)
      check a == b

  test "float parse round-trip stability for plain decimal forms (b)":
    # Same numbers written without exponent must give identical bits.
    for t in @["6.5722", "-5.565", "1.4534264322"]:
      let a = parseF(t)
      let b = parseF($a)
      check a == b
  test "float fast-path boundaries match dragonbox byte-for-byte":
    # Integral fast path: |x| < 2^53 and x == trunc(x), trailing ".0".
    check serializeDirect(1.0) == "1.0"
    check serializeDirect(-1.0) == "-1.0"
    check serializeDirect(0.0) == "0.0"
    check serializeDirect(-0.0) == "-0.0"      # sign must survive
    check serializeDirect(123456.0) == "123456.0"
    # 2^53-1 is the largest integral in the fast path.
    check serializeDirect(9007199254740991.0) == "9007199254740991.0"
    # 2^53 is just outside the integral fast path -> dragonbox, still exact.
    check serializeDirect(9007199254740992.0) == "9007199254740992.0"
    # Short-decimal exactness gate (float64(m)/10^k == x) picks the shortest form.
    check serializeDirect(0.5) == "0.5"
    check serializeDirect(0.25) == "0.25"
    check serializeDirect(0.1) == "0.1"
    check serializeDirect(1.5) == "1.5"
    check serializeDirect(0.001) == "0.001"
    # Values that fail the exactness gate fall through to dragonbox unchanged.
    check serializeDirect(1.0 / 3.0) == "0.3333333333333333"
    check serializeDirect(0.123456789012345678) == "0.12345678901234568"
