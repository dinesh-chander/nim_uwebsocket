## Pure-Nim zero-copy string views for JSON decoding.
##
## A ``BorrowedString`` points into the input document (or into an owned
## buffer when the source string contained JSON escapes) instead of copying
## the decoded text. A private owner field (shared document reference for
## escape-free views, owned buffer for escaped ones) keeps the bytes alive
## for as long as any view is used, so views stay valid even after the
## caller drops its own copy of the document. No buffer is ever copied to
## build an escape-free view.

type
  ## Shared owner for every view borrowed out of one document. Holding the
  ## document through a ``ref`` keeps view construction free of string
  ## refcount churn: views copy the (small) reference, never the buffer,
  ## and Nim's sink analysis cannot touch the document string per view.
  BorrowedDocRef* = ref object
    doc: string

  ## A view over decoded JSON string bytes. Either ``docOwner`` (shared
  ## document) or ``strOwner`` (escaped-decoded buffer) keeps the bytes
  ## alive; ``data`` points at the first byte (nil for a JSON null) and
  ## ``size`` is the byte length. The buffer is not NUL-terminated.
  BorrowedString* = object
    docOwner: BorrowedDocRef
    strOwner: string
    data: cstring
    size: int

  ## Alias for ``BorrowedString`` kept for API compatibility.
  JsonStringView* = BorrowedString

## Builds a ``BorrowedString`` view over the bytes held by ``owner`` starting
## at ``data`` with the given byte length.
# NOTE: this may move ``owner`` into the view (Nim's sink analysis). The
# decoder therefore builds escape-free views through ``setBorrowedDocView``
# instead, which shares one ``BorrowedDocRef`` per document.
proc borrowString*(owner: string, data: cstring, len: int): BorrowedString {.inline.} =
  result.strOwner = owner
  result.data = data
  result.size = len

## Creates a fresh shared owner for ``doc``. All views of one document share
## exactly one of these; the buffer itself is referenced, never copied.
proc newBorrowedDocRef*(doc: string): BorrowedDocRef {.inline.} =
  result = BorrowedDocRef()
  result.doc = doc

# Syntactic document-view construction for the decoder hot path. The only
# per-view write is the ``ref`` field: a raw pointer store that sink
# analysis cannot turn into a buffer copy.
template setBorrowedDocView*(v: var BorrowedString; holder; ptrValue; lenValue) =
  v.docOwner = holder
  v.data = ptrValue
  v.size = lenValue

## Moves a freshly decoded buffer into a new ``BorrowedString`` view whose
## ``owner`` is that buffer; the data pointer targets the moved bytes.
proc borrowOwned*(decoded: var string): BorrowedString {.inline.} =
  result.strOwner = move(decoded)
  result.size = result.strOwner.len
  result.data =
    if result.size > 0: cast[cstring](unsafeAddr result.strOwner[0])
    else: nil

## Returns the byte length of ``value``.
proc len*(value: BorrowedString): int {.inline.} =
  value.size

## Returns true if ``value`` points at no data (decoded from JSON null).
proc isNil*(value: BorrowedString): bool {.inline.} =
  value.data == nil

## Returns the raw data pointer of ``value``; the buffer is not NUL-terminated.
proc dataPtr*(value: BorrowedString): cstring {.inline.} =
  value.data

## Copies ``value`` into an owned string.
proc toString*(value: BorrowedString): string =
  if value.data == nil:
    return ""
  result = newString(value.size)
  copyMem(addr result[0], value.data, value.size)

## Returns ``value`` as an owned string.
proc `$`*(value: BorrowedString): string =
  value.toString()

## Returns ``value`` with leading and trailing ASCII whitespace removed.
proc stripAscii*(value: BorrowedString): BorrowedString {.inline.} =
  result = value
  if result.data == nil or result.size == 0:
    return
  var start = 0
  var finish = result.size
  while start < finish and result.data[start] in {' ', '\t', '\r', '\n'}:
    inc start
  while finish > start and result.data[finish - 1] in {' ', '\t', '\r', '\n'}:
    dec finish
  result.data = cast[cstring](cast[uint](result.data) + uint(start))
  result.size = finish - start

## Returns true if ``value`` equals ``literal`` using a fast ASCII comparison.
proc equalsAscii*(value: BorrowedString, literal: string): bool {.inline.} =
  if value.size != literal.len:
    return false
  if value.data == nil:
    return literal.len == 0
  for i in 0 ..< literal.len:
    if value.data[i] != literal[i]:
      return false
  true

## Returns true if ``value`` equals ``literal`` ignoring case using a fast ASCII comparison.
proc equalsIgnoreCaseAscii*(value: BorrowedString, literal: string): bool {.inline.} =
  if value.size != literal.len:
    return false
  if value.data == nil:
    return literal.len == 0
  for i in 0 ..< literal.len:
    var left = value.data[i]
    var right = literal[i]
    if left in {'A' .. 'Z'}:
      left = chr(ord(left) + 32)
    if right in {'A' .. 'Z'}:
      right = chr(ord(right) + 32)
    if left != right:
      return false
  true

## Parses ``value`` as 1, 0, true, false, yes, no, on, or off into ``outValue``; returns false if unparseable.
proc parseBoolLikeAscii*(value: BorrowedString, outValue: var bool): bool {.inline.} =
  let trimmed = value.stripAscii()
  if trimmed.equalsAscii("1") or trimmed.equalsIgnoreCaseAscii("true") or
      trimmed.equalsIgnoreCaseAscii("yes") or trimmed.equalsIgnoreCaseAscii("on"):
    outValue = true
    return true
  if trimmed.equalsAscii("0") or trimmed.equalsIgnoreCaseAscii("false") or
      trimmed.equalsIgnoreCaseAscii("no") or trimmed.equalsIgnoreCaseAscii("off"):
    outValue = false
    return true
  false

## Returns true if both views point at the same bytes.
proc `==`*(left, right: BorrowedString): bool {.inline.} =
  if left.size != right.size:
    return false
  if left.size == 0:
    return true
  for i in 0 ..< left.size:
    if left.data[i] != right.data[i]:
      return false
  true
