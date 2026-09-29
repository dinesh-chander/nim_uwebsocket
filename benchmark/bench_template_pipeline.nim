## Template pipeline micro-benchmark for todo view rendering.

import std/[times, monotimes]
import ../examples/todo_sqlite_mvc/[todo_model, todo_view]

const
  Iterations = 200_000
  TemplateText = """
<li id=\"todo-{{id}}\"><label class=\"{{done_class}}\"><input type=\"checkbox\" {{checked}}><span>{{title}}</span></label></li>
"""

proc runFastTemplateBench() =
  let start = getMonoTime()
  var bytes = 0
  for i in 0..<Iterations:
    let html = renderTodoItemFast(TemplateText, i + 1, "Task " & $(i + 1), (i and 1) == 0)
    bytes += html.len
  let elapsedNs = inNanoseconds(getMonoTime() - start)
  let seconds = float(elapsedNs) / 1_000_000_000.0
  echo "renderTodoItemFast ops/s: ", float(Iterations) / seconds
  echo "renderTodoItemFast MB/s: ", (float(bytes) / (1024 * 1024)) / seconds

proc runInlineBench() =
  let start = getMonoTime()
  var bytes = 0
  for i in 0..<Iterations:
    let todo = Todo(id: i + 1, title: "Task " & $(i + 1), completed: (i and 1) == 0, createdAt: "")
    let html = renderTodoItem(TemplateText, todo)
    bytes += html.len
  let elapsedNs = inNanoseconds(getMonoTime() - start)
  let seconds = float(elapsedNs) / 1_000_000_000.0
  echo "renderTodoItem ops/s: ", float(Iterations) / seconds
  echo "renderTodoItem MB/s: ", (float(bytes) / (1024 * 1024)) / seconds

when isMainModule:
  runFastTemplateBench()
  runInlineBench()
