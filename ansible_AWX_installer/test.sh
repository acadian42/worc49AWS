#!/usr/bin/env bash
# =============================================================================
# test.sh — run static checks and live integration tests.
#   ./test.sh            -> static + integration
#   ./test.sh static     -> static only
#   ./test.sh integration-> integration only
#   ./test.sh idempotence-> re-install idempotence test
# =============================================================================
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"
# shellcheck source=scripts/lib/common.sh
source "${PROJECT_DIR}/scripts/lib/common.sh"

what="${1:-all}"
rc=0
case "$what" in
  static)       "${PROJECT_DIR}/tests/static.sh" || rc=$? ;;
  integration)  "${PROJECT_DIR}/tests/integration.sh" || rc=$? ;;
  idempotence)  "${PROJECT_DIR}/tests/idempotence.sh" || rc=$? ;;
  all)
    "${PROJECT_DIR}/tests/static.sh" || rc=$?
    "${PROJECT_DIR}/tests/integration.sh" || rc=$?
    ;;
  *) die "unknown test target: ${what} (use: static|integration|idempotence|all)" ;;
esac
if (( rc == 0 )); then log_ok "test.sh (${what}) PASSED"; else log_error "test.sh (${what}) FAILED (rc=${rc})"; fi
exit "$rc"
