import std/unittest

import ../src/nim_usockets/usockets

suite "uSockets FFI surface":
  test "core FFI signatures compile":
    static:
      doAssert compiles(us_loop_iteration_number(cast[UsLoopPtr](nil)))
      doAssert compiles(us_loop_ext(cast[UsLoopPtr](nil)))
      doAssert compiles(us_create_timer(cast[UsLoopPtr](nil), 0.cint, 0.cuint))
      doAssert compiles(us_socket_ext(0.cint, cast[UsSocketPtr](nil)))
      doAssert compiles(us_socket_write(0.cint, cast[UsSocketPtr](nil), nil, 0.cint, 0.cint))
      doAssert compiles(us_socket_context_ext(0.cint, cast[UsSocketContextPtr](nil)))
      doAssert compiles(
        us_create_socket_context(
          0.cint,
          cast[UsLoopPtr](nil),
          0.cint,
          UsSocketContextOptions()
        )
      )
    check true
