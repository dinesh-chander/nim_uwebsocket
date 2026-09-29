import jsony

proc toJsonPkg*[T](v: T): string =
  jsony.toJson(v)
