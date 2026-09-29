import std/streams

import ./nim_fastjson/direct_engine
import ./nim_fastjson/simd_backend
import ./nim_fastjson/simdjson as simdjson_backend
import ./nim_fastjson/simdjson/simdjson_ffi

export direct_engine.JsonError
export direct_engine.JsonSafeString
export direct_engine.JsonAsciiSafeString
export direct_engine.JsonSerializeRootShape
export direct_engine.jsonSafe
export direct_engine.selectedSerializeRootShape
export simd_backend.directLeafDecodeSupported
export simd_backend.directNestedDecodeSupported
export simd_backend.borrowedTypedDecodeSupported

type
  FastJsonEngine* = enum
    fjeDirect
    fjeSimdjson

  FastJsonDecodePath* = enum
    fjdpDirect
    fjdpSimdLeaf
    fjdpSimdNested
    fjdpSimdBorrowed

  FastJsonFieldNamingPolicy* = enum
    fjfnpPreserve
    fjfnpCamelCase
    fjfnpSnakeCase

  FastJsonUnknownFieldPolicy* = enum
    fjufpIgnore
    fjufpError

  FastJsonEnumStyle* = enum
    fjesString
    fjesOrdinal

  FastJsonOptions* = object
    indentOutput*: bool
    indentStep*: int
    escapeNonAscii*: bool
    omitNullFields*: bool
    omitDefaultFields*: bool
    fieldNamingPolicy*: FastJsonFieldNamingPolicy
    unknownFieldPolicy*: FastJsonUnknownFieldPolicy
    enumStyle*: FastJsonEnumStyle
    caseInsensitiveFields*: bool
    allowTrailingCommas*: bool
    allowComments*: bool
    allowSingleQuotes*: bool
    allowUnquotedFieldNames*: bool
    allowNumbersFromStrings*: bool
    allowSpecialFloats*: bool
    maxDepth*: int
    maxInputBytes*: int
    maxArrayItems*: int
    useSimdWhenAvailable*: bool
    preferBorrowedStrings*: bool

  FastJson* = ref object
    options*: FastJsonOptions

  JsonStringView* = simd_backend.BorrowedStringAlias

## Returns the default ``FastJsonOptions`` used to build a ``FastJson`` instance.
proc defaultFastJsonOptions*(): FastJsonOptions =
  FastJsonOptions(
    indentOutput: false,
    indentStep: 2,
    escapeNonAscii: false,
    omitNullFields: false,
    omitDefaultFields: false,
    fieldNamingPolicy: fjfnpPreserve,
    unknownFieldPolicy: fjufpIgnore,
    enumStyle: fjesString,
    caseInsensitiveFields: false,
    allowTrailingCommas: false,
    allowComments: false,
    allowSingleQuotes: false,
    allowUnquotedFieldNames: false,
    allowNumbersFromStrings: false,
    allowSpecialFloats: false,
    maxDepth: 256,
    maxInputBytes: 64 * 1024 * 1024,
    maxArrayItems: 1_000_000,
    useSimdWhenAvailable: true,
    preferBorrowedStrings: false
  )

## Creates a new ``FastJson`` instance with the given ``FastJsonOptions``.
proc initFastJson*(options = defaultFastJsonOptions()): FastJson =
  new(result)
  result.options = options

proc unsupportedOption(name: string) {.noinline.} =
  raise newException(direct_engine.JsonError,
    "FastJson option '" & name & "' is not implemented by this backend")

proc validateSerializeOptions(fj: FastJson) =
  let opts = fj.options
  if opts.indentOutput: unsupportedOption("indentOutput")
  if opts.indentStep != 2: unsupportedOption("indentStep")
  if opts.escapeNonAscii: unsupportedOption("escapeNonAscii")
  if opts.omitNullFields: unsupportedOption("omitNullFields")
  if opts.omitDefaultFields: unsupportedOption("omitDefaultFields")
  if opts.fieldNamingPolicy != fjfnpPreserve: unsupportedOption("fieldNamingPolicy")
  if opts.enumStyle != fjesString: unsupportedOption("enumStyle")

proc validateJsonDepth(json: string; maxDepth: int) =
  if maxDepth <= 0:
    raise newException(direct_engine.JsonError, "FastJson option 'maxDepth' must be positive")

  var depth = 0
  var inString = false
  var escaped = false
  for idx, ch in json:
    if inString:
      if escaped:
        escaped = false
      elif ch == '\\':
        escaped = true
      elif ch == '"':
        inString = false
    else:
      case ch
      of '"':
        inString = true
      of '{', '[':
        inc depth
        if depth > maxDepth:
          raise newException(direct_engine.JsonError,
            "JSON nesting depth exceeds " & $maxDepth & " at byte " & $idx)
      of '}', ']':
        if depth > 0:
          dec depth
      else:
        discard

proc validateDeserializeOptions(fj: FastJson; json: string) =
  let opts = fj.options
  if opts.unknownFieldPolicy != fjufpIgnore: unsupportedOption("unknownFieldPolicy")
  if opts.caseInsensitiveFields: unsupportedOption("caseInsensitiveFields")
  if opts.allowTrailingCommas: unsupportedOption("allowTrailingCommas")
  if opts.allowComments: unsupportedOption("allowComments")
  if opts.allowSingleQuotes: unsupportedOption("allowSingleQuotes")
  if opts.allowUnquotedFieldNames: unsupportedOption("allowUnquotedFieldNames")
  if opts.allowNumbersFromStrings: unsupportedOption("allowNumbersFromStrings")
  if opts.allowSpecialFloats: unsupportedOption("allowSpecialFloats")
  if opts.preferBorrowedStrings: unsupportedOption("preferBorrowedStrings")
  if opts.maxInputBytes > 0 and json.len > opts.maxInputBytes:
    raise newException(direct_engine.JsonError,
      "JSON input exceeds maxInputBytes " & $opts.maxInputBytes)
  if opts.maxArrayItems < 0:
    raise newException(direct_engine.JsonError,
      "FastJson option 'maxArrayItems' must be non-negative")
  validateJsonDepth(json, opts.maxDepth)

proc readStreamLimited(stream: Stream; maxInputBytes: int): string =
  if maxInputBytes <= 0:
    return stream.readAll()
  result = newStringOfCap(min(maxInputBytes, 8192))
  while not stream.atEnd:
    let remaining = maxInputBytes - result.len
    if remaining <= 0:
      let extra = stream.readStr(1)
      if extra.len > 0:
        raise newException(direct_engine.JsonError,
          "JSON input exceeds maxInputBytes " & $maxInputBytes)
      break
    let chunk = stream.readStr(min(8192, remaining))
    if chunk.len == 0:
      break
    result.add(chunk)

## Converts a borrowed ``JsonStringView`` into an owned Nim string.
proc toString*(value: JsonStringView): string {.inline.} =
  simd_backend.toString(value)

## Returns the length in bytes of a borrowed ``JsonStringView``.
proc len*(value: JsonStringView): int {.inline.} =
  simd_backend.len(value)

## Returns the ``FastJsonDecodePath`` used to decode values of a given type.
proc selectedDeserializePath*[T](_: typedesc[T]): FastJsonDecodePath {.inline.} =
  when simd_backend.borrowedTypedDecodeSupported(T):
    fjdpSimdBorrowed
  elif simd_backend.directLeafDecodeSupported(T):
    fjdpSimdLeaf
  elif simd_backend.directNestedDecodeSupported(T):
    fjdpSimdNested
  else:
    fjdpDirect

## Returns the ``FastJsonEngine`` used to decode values of a given type.
proc selectedDeserializeEngine*[T](_: typedesc[T]): FastJsonEngine {.inline.} =
  when simd_backend.borrowedTypedDecodeSupported(T) or simd_backend.directLeafDecodeSupported(T):
    fjeSimdjson
  else:
    fjeDirect

proc stringToBytesMove(encoded: sink string): seq[byte] {.inline.} =
  result = cast[seq[byte]](encoded)
  wasMoved(encoded)

## Serializes a value into a JSON string after validating ``FastJson`` options.
proc serialize*[T](fj: FastJson; value: T): string =
  fj.validateSerializeOptions()
  direct_engine.serializeDirect(value)

## Serializes a value directly into an existing string buffer.
proc serializeInto*[T](fj: FastJson; buf: var string; value: T) =
  fj.validateSerializeOptions()
  direct_engine.serializeDirectInto(buf, value)

## Serializes a value into a byte sequence.
proc serializeToBytes*[T](fj: FastJson; value: T): seq[byte] =
  var encoded = fj.serialize(value)
  if encoded.len == 0:
    return @[]
  stringToBytesMove(move(encoded))

## Serializes the value as JSON and writes the encoded string to the stream.
proc serializeToStream*[T](fj: FastJson; stream: Stream; value: T) =
  stream.write(fj.serialize(value))

## Serializes the value as JSON into the in-memory string stream, replacing its buffer when empty.
proc serializeToStream*[T](fj: FastJson; stream: StringStream; value: T) =
  if stream.getPosition() == 0 and stream.data.len == 0:
    var encoded = fj.serialize(value)
    stream.data = move(encoded)
    stream.setPosition(stream.data.len)
  else:
    Stream(stream).write(fj.serialize(value))

## Deserializes JSON text into a value of type T, using the simdjson backend when supported.
proc deserialize*[T](fj: FastJson; json: string; _: typedesc[T]): T =
  fj.validateDeserializeOptions(json)
  let previousArrayLimit = direct_engine.setJsonArrayItemLimit(fj.options.maxArrayItems)
  defer:
    discard direct_engine.setJsonArrayItemLimit(previousArrayLimit)
  when simd_backend.borrowedTypedDecodeSupported(T) or simd_backend.directLeafDecodeSupported(T):
    try:
      if fj.options.useSimdWhenAvailable:
        if not simdjson_backend.isValidJson(json):
          raise newException(direct_engine.JsonError, "invalid JSON input")
        return simd_backend.deserializeViaSimd(json, T)
      else:
        when simd_backend.borrowedTypedDecodeSupported(T):
          unsupportedOption("useSimdWhenAvailable")
        else:
          return direct_engine.deserializeDirect(json, T)
    except CatchableError as exc:
      raise newException(direct_engine.JsonError, exc.msg)
  else:
    direct_engine.deserializeDirect(json, T)

## Deserializes a JSON byte sequence into a value of type T.
proc deserialize*[T](fj: FastJson; bytes: openArray[byte]; _: typedesc[T]): T =
  if bytes.len == 0:
    return fj.deserialize("", T)
  var json = newString(bytes.len)
  copyMem(addr json[0], unsafeAddr bytes[0], bytes.len)
  fj.deserialize(json, T)

## Reads the stream contents subject to the size limit and deserializes them into a value of type T.
proc deserialize*[T](fj: FastJson; stream: Stream; _: typedesc[T]): T =
  if stream of StringStream:
    let ss = StringStream(stream)
    if stream.getPosition() == 0:
      stream.setPosition(ss.data.len)
      return fj.deserialize(ss.data, T)
  fj.deserialize(readStreamLimited(stream, fj.options.maxInputBytes), T)

## Returns true if the JSON text is syntactically valid and within the input size limit.
proc isValidJson*(fj: FastJson; json: string): bool {.inline.} =
  if fj.options.maxInputBytes > 0 and json.len > fj.options.maxInputBytes:
    return false
  simdjson_backend.isValidJson(json)

## Returns true if the byte sequence is syntactically valid JSON within the input size limit.
proc isValidJson*(fj: FastJson; bytes: openArray[byte]): bool =
  if bytes.len == 0:
    return false
  if fj.options.maxInputBytes > 0 and bytes.len > fj.options.maxInputBytes:
    return false
  simdjsonIsValid(cast[cstring](unsafeAddr bytes[0]), bytes.len.csize_t)

## Returns true if the stream contents form valid JSON within the input size limit.
proc isValidJson*(fj: FastJson; stream: Stream): bool =
  if stream of StringStream:
    let ss = StringStream(stream)
    if stream.getPosition() == 0:
      stream.setPosition(ss.data.len)
      return fj.isValidJson(ss.data)
  try:
    fj.isValidJson(readStreamLimited(stream, fj.options.maxInputBytes))
  except direct_engine.JsonError:
    false
