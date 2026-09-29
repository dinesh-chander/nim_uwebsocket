## Embedded HTML templates for Todo MVC.
## These are compiled into the binary via staticRead.

import std/os

const
  ThisDir = currentSourcePath().parentDir()
  ViewsDir = ThisDir / ".." / "views" / "todo"

  TodoIndexTemplate* = staticRead(ViewsDir / "index.html")
  TodoListTemplate* = staticRead(ViewsDir / "list.html")
  TodoItemTemplate* = staticRead(ViewsDir / "item.html")
  TodoEmptyItemTemplate* = staticRead(ViewsDir / "empty_item.html")
  TodoCountTemplate* = staticRead(ViewsDir / "count.html")
  TodoErrorTemplate* = staticRead(ViewsDir / "error.html")
