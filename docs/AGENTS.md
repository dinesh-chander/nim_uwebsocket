# docs/AGENTS.md

Curated documentation (analysis, benchmarks, design). This is a human-facing reference, not build input.

Rules:
- Keep the folder structure stable: `analysis/` (framework research), `benchmarks/` (results and reports), `design/` (plans and design docs), plus top-level status/learning notes.
- No absolute filesystem paths — use repo-relative links.
- New benchmark iterations go in `benchmarks/` with a date in the filename; new design work in `design/`.
- Generated API reference lives in `../doc/api/` (regenerate with `make docs`) — do not hand-edit generated HTML there, and do not move it into this folder.
