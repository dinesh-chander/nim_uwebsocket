# COMMON.md — shared guardrails for all nim_express middleware units

Read this before touching any `nim_express/src/nim_express/middlewares/*.nim`.
The unit's own `AGENTS.md` adds specific rules on top of these; `nim_express/AGENTS.md`
and the root `AGENTS.md` own framework-level rules (routing, response path, scaling,
doc-comment format). When files disagree, the unit-specific file wins for that unit.

## Contract
1. Middleware signature is `proc(req: Request, res: Response, next: NextProc)`. Always
   call `next()` on pass-through paths; when short-circuiting, finish the response
   yourself. Middleware order is meaningful — don't assume execution order beyond
   what the unit's own tests prove.
2. A middleware must never abort the process: handler exceptions are the framework's
   concern (`panic_recovery`/`global_error_filter`). Guard your own state access.

## Performance (this stack targets ~95k req/s on the JSON hot path)
3. Keep the per-request path low/zero-allocation: no `newSeq`/`Table`/string
   concatenation per request unless the feature requires it. Pre-size with
   `newSeqOfCap`/`newStringOfCap` when you must. Note any allocation you add in
   your summary.
4. No per-request I/O on the loop thread (file, DNS, blocking socket). Offload via
   the established `offload` machinery if truly needed.

## Security
5. Every header value you emit is sanitized (reuse `common.nim` header sanitizers —
   no CRLF injection). Never echo raw user input into error messages, logs, or
   responses.
6. Anything you store per connection/request must be bounded (sizes, counts,
   durations); unbounded growth is a bug.
7. If your middleware caches, keys, or parses input, treat the input as adversarial:
   fuzz-shaped inputs (empty, oversized, NUL, Unicode, duplicate headers) must not
   hang, crash, or leak memory.

## Process
8. Public API: `## ` doc comment directly above every public declaration (same
   indentation, no square brackets in the text).
9. Bugfix/behavior change ships with a regression test in
   `nim_express/tests/test_<unit>_*.nim` (new file or extend existing).
10. Ownership: you own the unit's middleware file + its `test_<unit>*` files.
    Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`,
    `etag_core.nim`) are shared by other units — edit only when strictly required,
    then re-run the gates of every unit that imports them.
    Do NOT modify other packages or framework core (`app.nim`, `router.nim`,
    `request.nim`, `response.nim`, `offload.nim`); report the need instead.
    No `git add/commit` unless the operator asked.
11. Done = the unit gate exits 0:
    `bash harness/middleware/<unit>/run.sh`
