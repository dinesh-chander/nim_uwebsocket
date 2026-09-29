## View layer (V in MVC) for JSON + template binding.

import std/strutils
import ./todo_model
import ../../nim_express/src/nim_express/paged_buffer
import ../../nim_express/src/nim_express/fast_hash
import ../../nim_express/src/nim_express/json_builder

type
  CompiledTemplate = ref object
    parts: seq[string]  # Literal segments around placeholders.
    keys: seq[string]   # Placeholder keys in render order.
  ListTemplateSegments = object
    prefix: string
    middle: string
    suffix: string
  FastTemplateKey = enum
    fkUnknown
    fkId
    fkTitle
    fkChecked
    fkDoneClass
    fkItems
    fkCountOob
    fkRemaining
    fkOob
  FastTemplate* = ref object
    parts: seq[string]
    keys: seq[FastTemplateKey]
  TodoItemRenderPlan* = ref object
    usable*: bool
    segments*: array[7, string]
    segmentsPending*: array[5, string]
    segmentsCompleted*: array[5, string]

var
  cachedCompiledTemplateText {.threadvar.}: string
  cachedCompiledTemplate {.threadvar.}: CompiledTemplate
  cachedListTemplateText {.threadvar.}: string
  cachedListTemplateSegments {.threadvar.}: ListTemplateSegments
  cachedListTemplateReady {.threadvar.}: bool
  cachedFastItemTemplateText {.threadvar.}: string
  cachedFastItemTemplate {.threadvar.}: FastTemplate
  cachedFastCountTemplateText {.threadvar.}: string
  cachedFastCountTemplate {.threadvar.}: FastTemplate

{.push stackTrace: off.}

proc htmlEscape*(s: string): string =
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&#39;")
    else: result.add(c)

proc bindTemplate*(templateText: string, locals: FastMap[string]): string =
  result = templateText
  if locals != nil:
    for key, value in locals:
      result = result.replace("{{" & key & "}}", value)
      result = result.replace("{{ " & key & " }}", value)

proc lookupPairValue(keyVals: openArray[(string, string)], key: string): string {.inline.} =
  for pair in keyVals:
    if pair[0] == key:
      return pair[1]
  ""

proc compileTemplate(templateText: string): CompiledTemplate =
  new(result)
  result.parts = @[]
  result.keys = @[]

  var literalStart = 0
  var i = 0
  let n = templateText.len

  while i + 1 < n:
    if templateText[i] == '{' and templateText[i + 1] == '{':
      var j = i + 2
      while j + 1 < n and not (templateText[j] == '}' and templateText[j + 1] == '}'):
        inc j
      if j + 1 >= n:
        break

      result.parts.add(templateText[literalStart..<i])

      var keyStart = i + 2
      var keyEnd = j
      while keyStart < keyEnd and templateText[keyStart] in {' ', '\t'}:
        inc keyStart
      while keyEnd > keyStart and templateText[keyEnd - 1] in {' ', '\t'}:
        dec keyEnd
      result.keys.add(templateText[keyStart..<keyEnd])

      i = j + 2
      literalStart = i
    else:
      inc i

  if templateText.len == 0:
    result.parts.add("")
  else:
    result.parts.add(templateText[literalStart..^1])

proc getCompiledTemplate(templateText: string): CompiledTemplate =
  if cachedCompiledTemplate == nil or cachedCompiledTemplateText != templateText:
    cachedCompiledTemplate = compileTemplate(templateText)
    cachedCompiledTemplateText = templateText
  cachedCompiledTemplate

proc classifyFastTemplateKey(key: string): FastTemplateKey {.inline.} =
  case key.len
  of 2:
    if key == "id": fkId else: fkUnknown
  of 3:
    if key == "oob": fkOob else: fkUnknown
  of 5:
    if key == "title": fkTitle
    elif key == "items": fkItems
    else: fkUnknown
  of 7:
    if key == "checked": fkChecked else: fkUnknown
  of 9:
    if key == "count_oob": fkCountOob
    elif key == "remaining": fkRemaining
    else: fkUnknown
  of 10:
    if key == "done_class": fkDoneClass else: fkUnknown
  else:
    fkUnknown

proc compileFastTemplate(templateText: string): FastTemplate =
  let generic = compileTemplate(templateText)
  new(result)
  result.parts = generic.parts
  result.keys = newSeqOfCap[FastTemplateKey](generic.keys.len)
  for key in generic.keys:
    result.keys.add(classifyFastTemplateKey(key))

proc getFastItemTemplate*(templateText: string): FastTemplate {.inline.} =
  if cachedFastItemTemplate == nil or cachedFastItemTemplateText != templateText:
    cachedFastItemTemplate = compileFastTemplate(templateText)
    cachedFastItemTemplateText = templateText
  cachedFastItemTemplate

proc getTodoItemRenderPlan*(tpl: FastTemplate): TodoItemRenderPlan {.inline.} =
  new(result)
  if tpl == nil or tpl.parts.len != 7 or tpl.keys.len != 6:
    return
  if tpl.keys[0] != fkId or
      tpl.keys[1] != fkDoneClass or
      tpl.keys[2] != fkId or
      tpl.keys[3] != fkChecked or
      tpl.keys[4] != fkTitle or
      tpl.keys[5] != fkId:
    return
  result.usable = true
  for i in 0..6:
    result.segments[i] = tpl.parts[i]
  result.segmentsPending[0] = tpl.parts[0]
  result.segmentsPending[1] = tpl.parts[1] & tpl.parts[2]
  result.segmentsPending[2] = tpl.parts[3] & tpl.parts[4]
  result.segmentsPending[3] = tpl.parts[5]
  result.segmentsPending[4] = tpl.parts[6]
  result.segmentsCompleted[0] = tpl.parts[0]
  result.segmentsCompleted[1] = tpl.parts[1] & "done" & tpl.parts[2]
  result.segmentsCompleted[2] = tpl.parts[3] & " checked" & tpl.parts[4]
  result.segmentsCompleted[3] = tpl.parts[5]
  result.segmentsCompleted[4] = tpl.parts[6]

proc getFastCountTemplate*(templateText: string): FastTemplate {.inline.} =
  if cachedFastCountTemplate == nil or cachedFastCountTemplateText != templateText:
    cachedFastCountTemplate = compileFastTemplate(templateText)
    cachedFastCountTemplateText = templateText
  cachedFastCountTemplate

proc bindTemplatePairs*(templateText: string, keyVals: openArray[(string, string)]): string =
  let tpl = getCompiledTemplate(templateText)
  result = newStringOfCap(templateText.len + 128)

  for i in 0..<tpl.keys.len:
    result.add(tpl.parts[i])
    result.add(lookupPairValue(keyVals, tpl.keys[i]))
  result.add(tpl.parts[^1])

proc appendTodoJson(builder: var JsonBuilder, todo: Todo) =
  builder.add("""{"id":""")
  builder.addInt(todo.id)
  builder.add(""","title":""")
  builder.addEscaped(todo.title)
  builder.add(""","completed":""")
  builder.addBool(todo.completed)
  builder.add(""","createdAt":""")
  builder.addEscaped(todo.createdAt)
  builder.add("}")

proc todoJson*(todo: Todo): string =
  var builder = initJsonBuilder(64 + todo.title.len + todo.createdAt.len)
  builder.appendTodoJson(todo)
  builder.finish()

proc todosJson*(todos: seq[Todo]): string =
  var builder = initJsonBuilder(16 + todos.len * 96)
  builder.add("""{"todos":[""")
  for i, todo in todos:
    if i > 0:
      builder.add(",")
    builder.appendTodoJson(todo)
  builder.add("]}")
  builder.finish()

proc todoErrorJson*(message: string): string =
  var builder = initJsonBuilder(24 + message.len)
  builder.add("""{"error":""")
  builder.addEscaped(message)
  builder.add("}")
  builder.finish()

proc todoMessageJson*(message: string): string =
  var builder = initJsonBuilder(28 + message.len)
  builder.add("""{"message":""")
  builder.addEscaped(message)
  builder.add("}")
  builder.finish()

proc todoItemLocals*(todo: Todo): FastMap[string] =
  result = newFastMap[string]()
  discard result.put("id", $todo.id)
  discard result.put("title", htmlEscape(todo.title))
  discard result.put("checked", if todo.completed: " checked" else: "")
  discard result.put("done_class", if todo.completed: "done" else: "")

proc renderTodoItemFast*(itemTemplate: string, id: int, titleRaw: string, completed: bool): string =
  let idText = $id
  let title = htmlEscape(titleRaw)
  let checked = if completed: " checked" else: ""
  let doneClass = if completed: "done" else: ""
  bindTemplatePairs(itemTemplate, [
    ("id", idText),
    ("title", title),
    ("checked", checked),
    ("done_class", doneClass)
  ])

proc renderTodoItem*(itemTemplate: string, todo: Todo): string =
  renderTodoItemFast(itemTemplate, todo.id, todo.title, todo.completed)

proc appendTodoItemTemplateFast*(buf: var PageBuffer, tpl: FastTemplate, id: int, titleRaw: string, completed: bool) =
  ## Template-driven hot path: append precompiled item template into paged buffer.
  let checked = if completed: " checked" else: ""
  let doneClass = if completed: "done" else: ""

  for i in 0..<tpl.keys.len:
    buf.add(tpl.parts[i])
    case tpl.keys[i]
    of fkId:
      buf.addInt(id)
    of fkTitle:
      buf.addHtmlEscaped(titleRaw)
    of fkChecked:
      buf.add(checked)
    of fkDoneClass:
      buf.add(doneClass)
    else:
      discard
  buf.add(tpl.parts[^1])

proc appendTodoItemTemplateFast*(
  buf: var PageBuffer,
  tpl: FastTemplate,
  id: int,
  titlePtr: pointer,
  titleLen: int,
  completed: bool
) =
  ## Pointer/len variant avoids per-row sqlite text -> Nim string allocation.
  let checked = if completed: " checked" else: ""
  let doneClass = if completed: "done" else: ""

  for i in 0..<tpl.keys.len:
    buf.add(tpl.parts[i])
    case tpl.keys[i]
    of fkId:
      buf.addInt(id)
    of fkTitle:
      buf.addHtmlEscaped(titlePtr, titleLen)
    of fkChecked:
      buf.add(checked)
    of fkDoneClass:
      buf.add(doneClass)
    else:
      discard
  buf.add(tpl.parts[^1])

proc appendTodoItemTemplateFast*(buf: var PageBuffer, itemTemplate: string, id: int, titleRaw: string, completed: bool) =
  ## Backward-compatible wrapper that still benefits from cached compile.
  buf.appendTodoItemTemplateFast(getFastItemTemplate(itemTemplate), id, titleRaw, completed)

proc appendTodoItemTemplateFast*(dst: var string, tpl: FastTemplate, id: int, titlePtr: pointer, titleLen: int, completed: bool) =
  ## Lower-copy variant that appends rendered item directly into one output string.
  let checked = if completed: " checked" else: ""
  let doneClass = if completed: "done" else: ""

  for i in 0..<tpl.keys.len:
    dst.add(tpl.parts[i])
    case tpl.keys[i]
    of fkId:
      dst.addInt(id)
    of fkTitle:
      dst.addHtmlEscaped(titlePtr, titleLen)
    of fkChecked:
      dst.add(checked)
    of fkDoneClass:
      dst.add(doneClass)
    else:
      discard
  dst.add(tpl.parts[^1])

proc appendTodoItemPlannedFast*(
  dst: var PageBuffer,
  plan: TodoItemRenderPlan,
  tpl: FastTemplate,
  id: int,
  titlePtr: pointer,
  titleLen: int,
  completed: bool
) {.inline.} =
  ## PageBuffer variant of specialized renderer (no hardcoded HTML).
  if plan == nil or not plan.usable:
    dst.appendTodoItemTemplateFast(tpl, id, titlePtr, titleLen, completed)
    return

  var encodedId: array[24, char]
  let idView = encodeIntAscii(id, encodedId)
  let idPtr = addr encodedId[idView.start]
  let segs =
    if completed:
      addr plan.segmentsCompleted
    else:
      addr plan.segmentsPending

  let hasEscapes = hasHtmlEscapes(titlePtr, titleLen)

  if not hasEscapes:
    let safeTitleLen = if titleLen > 0: titleLen else: 0
    let rowBytes =
      segs[][0].len + idView.len +
      segs[][1].len + idView.len +
      segs[][2].len + safeTitleLen +
      segs[][3].len + idView.len +
      segs[][4].len
    let rowDst = dst.reserveContiguousWritable(rowBytes)
    if rowDst != nil:
      var writePtr = cast[uint](rowDst)

      template writeBytes(srcPtr: pointer, srcLen: int) =
        if srcPtr != nil and srcLen > 0:
          copyMem(cast[pointer](writePtr), srcPtr, srcLen)
          writePtr = writePtr + cast[uint](srcLen)

      template writeString(text: string) =
        if text.len > 0:
          writeBytes(unsafeAddr text[0], text.len)

      writeString(segs[][0])
      writeBytes(idPtr, idView.len)
      writeString(segs[][1])
      writeBytes(idPtr, idView.len)
      writeString(segs[][2])
      writeBytes(titlePtr, safeTitleLen)
      writeString(segs[][3])
      writeBytes(idPtr, idView.len)
      writeString(segs[][4])
      return

  dst.add(segs[][0])
  dst.appendRawPtr(idPtr, idView.len)
  dst.add(segs[][1])
  dst.appendRawPtr(idPtr, idView.len)
  dst.add(segs[][2])
  dst.addHtmlEscaped(titlePtr, titleLen)
  dst.add(segs[][3])
  dst.appendRawPtr(idPtr, idView.len)
  dst.add(segs[][4])

proc appendTodoItemPlannedFast*(
  dst: var string,
  plan: TodoItemRenderPlan,
  tpl: FastTemplate,
  id: int,
  titlePtr: pointer,
  titleLen: int,
  completed: bool
) {.inline.} =
  ## Specialized renderer driven by parsed template segments (no hardcoded HTML).
  if plan == nil or not plan.usable:
    dst.appendTodoItemTemplateFast(tpl, id, titlePtr, titleLen, completed)
    return

  dst.add(plan.segments[0])
  dst.addInt(id)
  dst.add(plan.segments[1])
  if completed:
    dst.add("done")
  dst.add(plan.segments[2])
  dst.addInt(id)
  dst.add(plan.segments[3])
  if completed:
    dst.add(" checked")
  dst.add(plan.segments[4])
  dst.addHtmlEscaped(titlePtr, titleLen)
  dst.add(plan.segments[5])
  dst.addInt(id)
  dst.add(plan.segments[6])

proc appendTodoCountFromRemainingFast*(dst: var string, tpl: FastTemplate, remaining: int, oob: bool) =
  let oobAttr = if oob: " hx-swap-oob=\"true\"" else: ""
  for i in 0..<tpl.keys.len:
    dst.add(tpl.parts[i])
    case tpl.keys[i]
    of fkRemaining:
      dst.addInt(remaining)
    of fkOob:
      dst.add(oobAttr)
    else:
      discard
  dst.add(tpl.parts[^1])

proc appendTodoCountFromRemainingFast*(buf: var PageBuffer, tpl: FastTemplate, remaining: int, oob: bool) =
  let oobAttr = if oob: " hx-swap-oob=\"true\"" else: ""
  for i in 0..<tpl.keys.len:
    buf.add(tpl.parts[i])
    case tpl.keys[i]
    of fkRemaining:
      buf.addInt(remaining)
    of fkOob:
      buf.add(oobAttr)
    else:
      discard
  buf.add(tpl.parts[^1])

proc renderTodoCountFromRemaining*(countTemplate: string, remaining: int, oob: bool): string =
  let tpl = getFastCountTemplate(countTemplate)
  let oobAttr = if oob: " hx-swap-oob=\"true\"" else: ""
  let remainingText = $remaining
  result = newStringOfCap(countTemplate.len + 12)
  for i in 0..<tpl.keys.len:
    result.add(tpl.parts[i])
    case tpl.keys[i]
    of fkRemaining:
      result.add(remainingText)
    of fkOob:
      result.add(oobAttr)
    else:
      discard
  result.add(tpl.parts[^1])

proc renderTodoCount*(countTemplate: string, todos: seq[Todo], oob: bool): string =
  var remaining = 0
  for todo in todos:
    if not todo.completed:
      inc remaining
  renderTodoCountFromRemaining(countTemplate, remaining, oob)

{.pop.}

proc renderTodoListFragment*(
  listTemplate: string,
  itemTemplate: string,
  emptyItemTemplate: string,
  countTemplate: string,
  todos: seq[Todo]
): string =
  var items = newStringOfCap(256 + todos.len * 240)
  var remaining = 0
  for todo in todos:
    if not todo.completed:
      inc remaining
    items.add(renderTodoItem(itemTemplate, todo))

  if todos.len == 0:
    items.add(emptyItemTemplate)

  let countOob = renderTodoCountFromRemaining(countTemplate, remaining, true)
  bindTemplatePairs(listTemplate, [
    ("items", items),
    ("count_oob", countOob)
  ])

proc listTemplateSegments*(listTemplate: string): tuple[prefix: string, middle: string, suffix: string] =
  if cachedListTemplateReady and cachedListTemplateText == listTemplate:
    let segs = cachedListTemplateSegments
    return (segs.prefix, segs.middle, segs.suffix)

  let itemsToken = "{{items}}"
  let countToken = "{{count_oob}}"
  let itemsPos = listTemplate.find(itemsToken)
  let countPos = listTemplate.find(countToken)

  if itemsPos >= 0 and countPos >= 0 and countPos >= itemsPos + itemsToken.len:
    let segs = ListTemplateSegments(
      prefix: listTemplate[0..<itemsPos],
      middle: listTemplate[(itemsPos + itemsToken.len)..<countPos],
      suffix: listTemplate[(countPos + countToken.len)..^1]
    )
    cachedListTemplateText = listTemplate
    cachedListTemplateSegments = segs
    cachedListTemplateReady = true
    return (segs.prefix, segs.middle, segs.suffix)

  # Fallback for unexpected list template shapes: keep template-derived content.
  return (listTemplate, "", "")

proc renderErrorFragment*(errorTemplate: string, message: string): string =
  bindTemplatePairs(errorTemplate, [("message", htmlEscape(message))])
