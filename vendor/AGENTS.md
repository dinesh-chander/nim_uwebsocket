# vendor/AGENTS.md

Vendored upstream dependencies: **zippy**, **brotli**, **nim_zstd**, **nim_libdeflate_gzip**, **malebolgia**, **jsony**, **checksums**.

Rules:
- Treat as read-only. Do not edit vendored code; fix issues upstream and re-vendored.
- Do not "clean up" or reformat vendored files.
- Large upstream test fixtures (zippy `tests/data/tor-list*`, `tests/data/tarballs/`, malebolgia `bench/data/`) are intentionally not committed to keep the repo small. They are only needed when running the vendored projects' own test suites, which `make test` does not do.
- Pin updates deliberately: the nimble file and CI depend on the vendored versions.
