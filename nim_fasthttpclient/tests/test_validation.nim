import std/strutils
import nim_fasthttpclient/validation

var passed = 0
var failed = 0

template check(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failed += 1
    echo "FAIL: ", msg

echo "=== Validation Module Tests ==="
echo ""

proc testContainsCRLF() =
  check(containsCRLF("hello\r\nworld") == true, "containsCRLF: CRLF pair")
  check(containsCRLF("hello\rworld") == true, "containsCRLF: bare CR")
  check(containsCRLF("hello\nworld") == true, "containsCRLF: bare LF")
  check(containsCRLF("hello\0world") == true, "containsCRLF: null byte")
  check(containsCRLF("hello world") == false, "containsCRLF: clean string")
  check(containsCRLF("") == false, "containsCRLF: empty string")
  check(containsCRLF("\r") == true, "containsCRLF: lone CR")
  check(containsCRLF("\n") == true, "containsCRLF: lone LF")
  check(containsCRLF("\0") == true, "containsCRLF: lone null")
  check(containsCRLF("abcdef") == false, "containsCRLF: alpha-only")
  echo "containsCRLF: OK"

proc testContainsNullByte() =
  check(containsNullByte("hello\0world") == true, "containsNullByte: embedded null")
  check(containsNullByte("\0") == true, "containsNullByte: just null")
  check(containsNullByte("hello") == false, "containsNullByte: no null")
  check(containsNullByte("") == false, "containsNullByte: empty")
  check(containsNullByte("abc\0") == true, "containsNullByte: trailing null")
  check(containsNullByte("\0abc") == true, "containsNullByte: leading null")
  check(containsNullByte("\r\n") == false, "containsNullByte: CRLF not null")
  echo "containsNullByte: OK"

proc testIsValidHeaderName() =
  check(isValidHeaderName("Content-Type") == true, "isValidHeaderName: Content-Type")
  check(isValidHeaderName("X-Custom-123") == true, "isValidHeaderName: custom header")
  check(isValidHeaderName("accept") == true, "isValidHeaderName: lowercase")
  check(isValidHeaderName("") == false, "isValidHeaderName: empty")
  check(isValidHeaderName("Bad:Name") == false, "isValidHeaderName: colon")
  check(isValidHeaderName("Bad Name") == false, "isValidHeaderName: space")
  check(isValidHeaderName("Bad\rName") == false, "isValidHeaderName: CR")
  check(isValidHeaderName("Bad\nName") == false, "isValidHeaderName: LF")
  check(isValidHeaderName("Bad\0Name") == false, "isValidHeaderName: null byte")
  check(isValidHeaderName("Bad\tName") == false, "isValidHeaderName: tab")
  check(isValidHeaderName("a") == true, "isValidHeaderName: single char")
  check(isValidHeaderName("\x01") == false, "isValidHeaderName: control char")
  check(isValidHeaderName("\x7f") == false, "isValidHeaderName: DEL char")
  check(isValidHeaderName("\x80") == false, "isValidHeaderName: high byte")
  echo "isValidHeaderName: OK"

proc testIsValidHeaderValue() =
  check(isValidHeaderValue("text/html") == true, "isValidHeaderValue: normal value")
  check(isValidHeaderValue("") == true, "isValidHeaderValue: empty")
  check(isValidHeaderValue("val\r\nue") == false, "isValidHeaderValue: CRLF")
  check(isValidHeaderValue("val\rue") == false, "isValidHeaderValue: CR")
  check(isValidHeaderValue("val\nue") == false, "isValidHeaderValue: LF")
  check(isValidHeaderValue("val\0ue") == false, "isValidHeaderValue: null byte")
  check(isValidHeaderValue("value with spaces") == true, "isValidHeaderValue: spaces ok")
  check(isValidHeaderValue("value\twith\ttabs") == true, "isValidHeaderValue: tabs ok")
  echo "isValidHeaderValue: OK"

proc testIsValidHost() =
  check(isValidHost("example.com") == true, "isValidHost: domain")
  check(isValidHost("192.168.1.1") == true, "isValidHost: IPv4")
  check(isValidHost("localhost") == true, "isValidHost: localhost")
  check(isValidHost("") == false, "isValidHost: empty")
  check(isValidHost("evil.com/hack") == false, "isValidHost: contains slash")
  check(isValidHost("evil.com\r\n") == false, "isValidHost: CRLF injection")
  check(isValidHost("user@evil.com") == false, "isValidHost: at sign")
  check(isValidHost("evil.com\0") == false, "isValidHost: trailing null")
  check(isValidHost("evil\rhost") == false, "isValidHost: bare CR")
  check(isValidHost("evil\nhost") == false, "isValidHost: bare LF")
  check(isValidHost("a") == true, "isValidHost: single char")
  echo "isValidHost: OK"

proc testIsValidPath() =
  check(isValidPath("/") == true, "isValidPath: root")
  check(isValidPath("/api/v1/users") == true, "isValidPath: nested path")
  check(isValidPath("/path?query=1") == true, "isValidPath: with query")
  check(isValidPath("") == false, "isValidPath: empty")
  check(isValidPath("noLeadingSlash") == false, "isValidPath: no leading slash")
  check(isValidPath("/bad\r\npath") == false, "isValidPath: CRLF injection")
  check(isValidPath("/bad\rpath") == false, "isValidPath: CR")
  check(isValidPath("/bad\npath") == false, "isValidPath: LF")
  check(isValidPath("/bad\0path") == false, "isValidPath: null byte")
  echo "isValidPath: OK"

proc testIsValidPort() =
  check(isValidPort(80) == true, "isValidPort: HTTP")
  check(isValidPort(443) == true, "isValidPort: HTTPS")
  check(isValidPort(8080) == true, "isValidPort: alt HTTP")
  check(isValidPort(1) == true, "isValidPort: min valid")
  check(isValidPort(65535) == true, "isValidPort: max valid")
  check(isValidPort(0) == false, "isValidPort: zero")
  echo "isValidPort: OK"

proc testIsValidStatusCode() =
  check(isValidStatusCode(200) == true, "isValidStatusCode: 200 OK")
  check(isValidStatusCode(100) == true, "isValidStatusCode: 100 Continue")
  check(isValidStatusCode(404) == true, "isValidStatusCode: 404")
  check(isValidStatusCode(500) == true, "isValidStatusCode: 500")
  check(isValidStatusCode(999) == true, "isValidStatusCode: max")
  check(isValidStatusCode(99) == false, "isValidStatusCode: below 100")
  check(isValidStatusCode(0) == false, "isValidStatusCode: zero")
  check(isValidStatusCode(1000) == false, "isValidStatusCode: above 999")
  check(isValidStatusCode(-1) == false, "isValidStatusCode: negative")
  echo "isValidStatusCode: OK"

proc testIsValidH2StreamId() =
  check(isValidH2StreamId(1) == true, "isValidH2StreamId: min valid")
  check(isValidH2StreamId(3) == true, "isValidH2StreamId: odd")
  check(isValidH2StreamId(2) == true, "isValidH2StreamId: even (push promise)")
  check(isValidH2StreamId(2147483647'u32) == true, "isValidH2StreamId: max valid")
  check(isValidH2StreamId(0) == false, "isValidH2StreamId: zero (connection level)")
  echo "isValidH2StreamId: OK"

proc testIsValidH2WindowSize() =
  check(isValidH2WindowSize(0) == true, "isValidH2WindowSize: zero")
  check(isValidH2WindowSize(65535) == true, "isValidH2WindowSize: default")
  check(isValidH2WindowSize(2147483647'i64) == true, "isValidH2WindowSize: max valid (2^31-1)")
  check(isValidH2WindowSize(-1) == false, "isValidH2WindowSize: negative")
  check(isValidH2WindowSize(2147483648'i64) == false, "isValidH2WindowSize: 2^31 overflow")
  check(isValidH2WindowSize(4294967295'i64) == false, "isValidH2WindowSize: 2^32-1")
  echo "isValidH2WindowSize: OK"

proc testIsValidWsPayloadLen() =
  check(isValidWsPayloadLen(8, 0) == true, "isValidWsPayloadLen: close empty")
  check(isValidWsPayloadLen(8, 125) == true, "isValidWsPayloadLen: close max")
  check(isValidWsPayloadLen(8, 126) == false, "isValidWsPayloadLen: close over limit")
  check(isValidWsPayloadLen(9, 125) == true, "isValidWsPayloadLen: ping max")
  check(isValidWsPayloadLen(9, 126) == false, "isValidWsPayloadLen: ping over limit")
  check(isValidWsPayloadLen(10, 125) == true, "isValidWsPayloadLen: pong max")
  check(isValidWsPayloadLen(10, 126) == false, "isValidWsPayloadLen: pong over limit")
  check(isValidWsPayloadLen(1, 65536) == true, "isValidWsPayloadLen: text large ok")
  check(isValidWsPayloadLen(2, 65536) == true, "isValidWsPayloadLen: binary large ok")
  check(isValidWsPayloadLen(0, 65536) == true, "isValidWsPayloadLen: continuation large ok")
  echo "isValidWsPayloadLen: OK"

proc testIsControlFrame() =
  check(isControlFrame(8) == true, "isControlFrame: close (0x8)")
  check(isControlFrame(9) == true, "isControlFrame: ping (0x9)")
  check(isControlFrame(10) == true, "isControlFrame: pong (0xA)")
  check(isControlFrame(11) == true, "isControlFrame: reserved 0xB")
  check(isControlFrame(15) == true, "isControlFrame: reserved 0xF")
  check(isControlFrame(0) == false, "isControlFrame: continuation")
  check(isControlFrame(1) == false, "isControlFrame: text")
  check(isControlFrame(2) == false, "isControlFrame: binary")
  check(isControlFrame(7) == false, "isControlFrame: reserved data 0x7")
  echo "isControlFrame: OK"

proc testIsValidChunkSize() =
  check(isValidChunkSize(0) == true, "isValidChunkSize: zero (last chunk)")
  check(isValidChunkSize(1) == true, "isValidChunkSize: one byte")
  check(isValidChunkSize(MaxChunkSize) == true, "isValidChunkSize: max (16 MiB)")
  check(isValidChunkSize(MaxChunkSize + 1) == false, "isValidChunkSize: over max")
  check(isValidChunkSize(-1) == false, "isValidChunkSize: negative")
  echo "isValidChunkSize: OK"

proc testIsValidContentLength() =
  check(isValidContentLength(0) == true, "isValidContentLength: zero")
  check(isValidContentLength(1024) == true, "isValidContentLength: 1KB")
  check(isValidContentLength(MaxContentLengthVal) == true, "isValidContentLength: max (256 MiB)")
  check(isValidContentLength(MaxContentLengthVal + 1) == false, "isValidContentLength: over max")
  check(isValidContentLength(-1) == false, "isValidContentLength: negative")
  echo "isValidContentLength: OK"

proc testSanitizeForLog() =
  check(sanitizeForLog("normal text") == "normal text", "sanitizeForLog: normal text")
  check(sanitizeForLog("") == "", "sanitizeForLog: empty")
  check(sanitizeForLog("has\x01control") == "has?control", "sanitizeForLog: replaces control")
  check(sanitizeForLog("has\x7fDEL") == "has?DEL", "sanitizeForLog: replaces DEL")
  check(sanitizeForLog("has\r\n") == "has??", "sanitizeForLog: replaces CRLF")
  var longStr = newString(200)
  for i in 0..<200: longStr[i] = 'A'
  let sanitized = sanitizeForLog(longStr, 128)
  check(sanitized.len <= 131, "sanitizeForLog: truncated with ellipsis")
  check(sanitized.endsWith("..."), "sanitizeForLog: ends with ellipsis")
  let short = sanitizeForLog("short", 128)
  check(short == "short", "sanitizeForLog: no truncation for short")
  check(not short.endsWith("..."), "sanitizeForLog: no ellipsis for short")
  echo "sanitizeForLog: OK"

testContainsCRLF()
testContainsNullByte()
testIsValidHeaderName()
testIsValidHeaderValue()
testIsValidHost()
testIsValidPath()
testIsValidPort()
testIsValidStatusCode()
testIsValidH2StreamId()
testIsValidH2WindowSize()
testIsValidWsPayloadLen()
testIsControlFrame()
testIsValidChunkSize()
testIsValidContentLength()
testSanitizeForLog()

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
