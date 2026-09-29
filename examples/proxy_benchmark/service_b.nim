import std/json
import ../../nim_express/src/nim_express

const MediumPoolSize = 128

proc buildMediumPayload(idx: int): string =
  result = newStringOfCap(1400)
  result.add """{"id":"""
  result.addInt(idx * 7 + 1000)
  result.add ""","timestamp":1700"""
  result.addInt(idx * 13 + 100000)
  result.add ""","name":"user_"""
  result.addInt(idx mod 9999)
  result.add """","email":"user"""
  result.addInt(idx mod 9999)
  result.add """@example.com","active":true,"balance":"""
  result.addInt((idx * 37) mod 1000)
  result.add """.50,"metadata":{"region":"us-east","tier":"pro","score":7.3,"loginCount":"""
  result.addInt((idx * 41) mod 5000)
  result.add ""","verified":true},"tags":["tag_1","tag_2","tag_3","tag_4","tag_5","tag_6","tag_7","tag_8","tag_9","tag_10"],"description":"Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.","history":[{"action":"event_1","value":100,"ts":1700043200},{"action":"event_2","value":200,"ts":1700050000},{"action":"event_3","value":300,"ts":1700060000},{"action":"event_4","value":400,"ts":1700070000},{"action":"event_5","value":500,"ts":1700080000}],"config":{"enabled":true,"retries":3,"timeout_ms":5000,"endpoints":["https://api1.example.com/v1","https://api2.example.com/v2","https://api3.example.com/v3"],"features":{"caching":true,"compression":true,"rateLimit":5000,"maxPayload":1048576}},"permissions":["read","write","admin","audit"],"address":{"street":"1234 Main Street","city":"Anytown","state":"CA","zip":"90210"}}"""

var mediumPayloads: array[MediumPoolSize, string]
for i in 0 ..< MediumPoolSize:
  mediumPayloads[i] = buildMediumPayload(i)

var largePayload: string
block:
  largePayload = newStringOfCap(8192)
  largePayload.add """{"total":20,"page":1,"perPage":20,"items":["""
  for i in 0 ..< 20:
    if i > 0: largePayload.add ','
    largePayload.add """{"id":"""
    largePayload.addInt(i)
    largePayload.add ""","name":"item_"""
    largePayload.addInt(i)
    largePayload.add """","description":"This is a detailed description for item number """
    largePayload.addInt(i)
    largePayload.add """. It contains various metadata fields and configuration options that simulate a realistic API response payload for benchmarking purposes.","tags":["alpha","beta","gamma","delta","epsilon"],"metrics":{"views":50000,"clicks":25000,"conversions":500},"nested":{"level1":{"level2":{"level3":{"value":"deep_"""
    largePayload.addInt(i)
    largePayload.add """"}}}}}"""
  largePayload.add """],"metadata":{"generatedAt":1700000000,"version":"2.0.0","region":"us-east-1"}}"""

var smallCounter: int = 0
var mediumIdx: int = 0

let app = newExpressApp()

app.get("/api/small") do (req: Request, res: Response):
  res.jsonRaw("""{"msg":"ok","ts":""" & $smallCounter & "}")
  smallCounter += 1

app.get("/api/medium") do (req: Request, res: Response):
  res.jsonRaw(mediumPayloads[mediumIdx])
  mediumIdx = (mediumIdx + 1) and (MediumPoolSize - 1)

app.get("/api/large") do (req: Request, res: Response):
  res.jsonRaw(largePayload)

app.post("/api/echo") do (req: Request, res: Response):
  let body = req.rawBody()
  res.json(%*{"echoed": body, "len": body.len})

var delayCounter: int = 0

app.get("/api/delay/:ms") do (req: Request, res: Response):
  let msParam = req.param("ms")
  var ms = 0
  for c in msParam:
    if c >= '0' and c <= '9':
      ms = ms * 10 + (ord(c) - ord('0'))
  for i in 0 ..< ms * 1000:
    delayCounter += 1
  res.json(%*{"delayed": msParam, "counter": delayCounter})

app.get("/api/headers") do (req: Request, res: Response):
  req.bindHeaders()
  var headers = newJObject()
  for key, value in req.headers.pairs():
    headers[key] = %value
  res.json(headers)

app.get("/health") do (req: Request, res: Response):
  res.jsonRaw("""{"status":"ok","service":"B"}""")

app.get("/") do (req: Request, res: Response):
  res.jsonRaw(mediumPayloads[mediumIdx])
  mediumIdx = (mediumIdx + 1) and (MediumPoolSize - 1)

echo "Service B (upstream backend) starting on port 3201..."
app.listen(3201) do (success: bool):
  if success:
    echo "Service B running on http://127.0.0.1:3201"
  else:
    echo "Service B failed to start!"
    quit(1)
