#!/usr/bin/env bash
# Gate for the nim_express package: all tests in nim_express/tests.
# For middleware-scoped work prefer the narrower harness/middleware/<name>/run.sh.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../common.sh"
FILES=("$ROOT_DIR"/nim_express/tests/test_*.nim)
harness_run_tests "nim_express" -- "${FILES[@]}" || exit 1
# Offload tests need their define (admission limit pinned to 1) and threads to
# exercise the malebolgia pool exactly like the examples are built.
harness_run_tests "nim_express_offload_admission" --threads:on -d:nimExpressOffloadTest -d:NimExpressOffloadQueueLimit:1 \
  -- "$ROOT_DIR"/nim_express/tests/test_offload_admission.nim || exit 1
harness_run_tests "nim_express_offload_reuse" --threads:on -d:nimExpressOffloadTest \
  -- "$ROOT_DIR"/nim_express/tests/test_offload_master_reuse.nim || exit 1
