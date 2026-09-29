import ../../nim_express/src/nim_express

let app = newExpressApp()
let proxyClient = app.createHttpClient("proxy", maxConnsPerHost = 64)

var proxyOptions = initFastProxyOptions("http://127.0.0.1:3201")
proxyOptions.client = proxyClient
proxyOptions.addXForwardedHeaders = false
proxyOptions.allowPrivateUpstreams = true
app.use(fastProxy(proxyOptions))

app.listen(3200) do (success: bool):
  if success: echo "Service A on :3200 -> proxying to :3201"
  else: quit(1)
