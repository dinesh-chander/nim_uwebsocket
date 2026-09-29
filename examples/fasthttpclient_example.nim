import nim_fasthttpclient/types
import nim_fasthttpclient/client

echo """
=====================================
  FastHttpClient Example
=====================================
"""

var httpClient = newHttpClient(preferH2 = false)

echo "--- HTTP/1.1 GET request ---"
httpClient.get("http://httpbin.org/get") do (resp: HttpResponse, err: string):
  if err.len > 0:
    echo "Error: ", err
  else:
    echo "Status: ", resp.statusCode
    echo "Body length: ", resp.body.len
    echo "Body (first 200 chars): ", resp.body[0 ..< min(200, resp.body.len)]
    echo ""

echo "--- HTTP/1.1 POST request ---"
httpClient.post("http://httpbin.org/post", """{"name":"nim","version":"2.0"}""") do (resp: HttpResponse, err: string):
  if err.len > 0:
    echo "Error: ", err
  else:
    echo "Status: ", resp.statusCode
    echo "Body length: ", resp.body.len
    echo ""

echo "Running event loop (will auto-stop when all requests complete)..."
httpClient.run(autoStop = true)
echo "All HTTP/1.1 requests completed."
httpClient.close()

echo ""
echo "--- HTTP/2 GET request (h2c) ---"
var h2client = newHttpClient(preferH2 = true)

proc onH2Response(resp: HttpResponse, err: string) =
  if err.len > 0:
    echo "H2 Error: ", err
  else:
    echo "H2 Status: ", resp.statusCode
    echo "H2 Version: ", resp.version
    echo "H2 Body length: ", resp.body.len
    echo ""

h2client.request(hmGet, "http://httpbin.org/get", "", @[], onH2Response, forceH2 = true)

h2client.run(autoStop = true)
echo "HTTP/2 request completed."
h2client.close()

echo ""
echo "Done."
