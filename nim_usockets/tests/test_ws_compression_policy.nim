import std/[unittest, strutils]
import ../src/nim_usockets/http

suite "WebSocket compression policy matrix":
  test "default server options keep ws compression disabled":
    let options = defaultServerOptions()
    check options.wsCompressionEnabled == false
    check options.wsCompressionMinBytes > 0
    check options.wsCompressionServerNoContextTakeover == true
    check options.wsCompressionClientNoContextTakeover == true
    check options.wsCompressionBackpressureBypassBytes == 0

  test "negotiation adds required no-context parameters":
    var options = defaultServerOptions()
    options.wsCompressionEnabled = true

    check negotiateWsCompressionHeader("", options).len == 0
    let bareNegotiated = negotiateWsCompressionHeader("permessage-deflate", options)
    check bareNegotiated.contains("Sec-WebSocket-Extensions")
    check bareNegotiated.contains("permessage-deflate")
    check bareNegotiated.contains("server_no_context_takeover")
    check bareNegotiated.contains("client_no_context_takeover")

    let partialNegotiated = negotiateWsCompressionHeader(
      "permessage-deflate; server_no_context_takeover",
      options
    )
    check partialNegotiated.contains("Sec-WebSocket-Extensions")
    check partialNegotiated.contains("permessage-deflate")
    check partialNegotiated.contains("server_no_context_takeover")
    check partialNegotiated.contains("client_no_context_takeover")

    let negotiated = negotiateWsCompressionHeader(
      "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
      options
    )
    check negotiated.contains("Sec-WebSocket-Extensions")
    check negotiated.contains("permessage-deflate")
    check negotiated.contains("server_no_context_takeover")
    check negotiated.contains("client_no_context_takeover")

  test "context takeover opt-out disables negotiation for protocol safety":
    var options = defaultServerOptions()
    options.wsCompressionEnabled = true
    options.wsCompressionClientNoContextTakeover = false
    options.wsCompressionServerNoContextTakeover = true

    check negotiateWsCompressionHeader(
      "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
      options
    ).len == 0

  test "policy matrix enforces threshold bypass type and backpressure":
    var options = defaultServerOptions()
    options.wsCompressionEnabled = true
    options.wsCompressionMinBytes = 1024
    options.wsCompressionDisableForBinary = true
    options.wsCompressionDisableForText = false
    options.wsCompressionBackpressureBypassBytes = 2048

    check wsCompressionDecision(options, true, 800, false, false, 0) == false
    check wsCompressionDecision(options, true, 2048, false, false, 0) == true
    check wsCompressionDecision(options, true, 2048, true, false, 0) == false
    check wsCompressionDecision(options, true, 2048, false, true, 0) == false
    check wsCompressionDecision(options, true, 2048, false, false, 4096) == false
    check wsCompressionDecision(options, false, 4096, false, false, 0) == false
