# HTTP Compliance Iterations (5)

Target: http://127.0.0.1:3002 (bench_nim_express)
Checks: GET 200, TRACE->501, HTTP/1.1 missing Host->400, invalid Content-Length->400
Date: 2026-03-05 06:15:10Z

- Iteration 1: GET= TRACE=501 NOHOST=400 BADCL= PASS=0
- Iteration 2: GET= TRACE=501 NOHOST=400 BADCL= PASS=0
- Iteration 3: GET= TRACE= NOHOST= BADCL=400 PASS=0
- Iteration 4: GET= TRACE= NOHOST= BADCL= PASS=0
- Iteration 5: GET=200 TRACE= NOHOST= BADCL= PASS=0

Pass count: 0/5
