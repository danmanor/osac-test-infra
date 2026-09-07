#!/usr/bin/env bash
# Deterministic tests for optional-dispatch-plan.sh.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLAN_SCRIPT="${SCRIPT_DIR}/optional-dispatch-plan.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "${TEST_DIR}"' EXIT

pass=0
fail=0

assert_eq() {
  local name=$1 expected=$2 actual=$3
  if [[ "${expected}" == "${actual}" ]]; then
    echo "PASS: ${name}"
    pass=$((pass + 1))
  else
    echo "FAIL: ${name}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    fail=$((fail + 1))
  fi
}

expect_failure() {
  local name=$1
  shift
  local output rc
  set +e
  output=$("${PLAN_SCRIPT}" "$@" 2>&1)
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]]; then
    echo "FAIL: ${name} (expected non-zero exit)"
    fail=$((fail + 1))
  else
    echo "PASS: ${name}"
    pass=$((pass + 1))
  fi
}

cat >"${TEST_DIR}/optional.json" <<'JSON'
[
  {
    "command": "bmaas-netris",
    "workflow": "e2e-bmaas-netris-full-install-caller.yml",
    "name": "E2E BMaaS Netris",
    "description": "BMaaS networking tests on the Netris infrastructure",
    "workflow_id": 101,
    "retestable": true
  }
]
JSON

same_repo_plan=$("${PLAN_SCRIPT}" plan \
  "${TEST_DIR}/optional.json" \
  bmaas-netris main 42 osac-project/osac-test-infra feature/test abc1234 \
  '' '' false)
assert_eq "same-repository plan" \
  '{"workflow":"e2e-bmaas-netris-full-install-caller.yml","marker":"PR #42 @ abc1234","default_branch":"main","dispatch_args":["-f","pr-number=42","-f","pr-repository=osac-project/osac-test-infra","-f","pr-ref=feature/test","-f","pr-sha=abc1234"]}' \
  "${same_repo_plan}"

fork_plan=$("${PLAN_SCRIPT}" plan \
  "${TEST_DIR}/optional.json" \
  bmaas-netris main 42 danmanor/osac-test-infra feature/test abc1234 \
  alice member true)
assert_eq "fork plan includes authorization metadata" \
  '{"workflow":"e2e-bmaas-netris-full-install-caller.yml","marker":"PR #42 @ abc1234","default_branch":"main","dispatch_args":["-f","pr-number=42","-f","pr-repository=danmanor/osac-test-infra","-f","pr-ref=feature/test","-f","pr-sha=abc1234","-f","fork-pr-author-association=member","-f","fork-pr-author=alice"]}' \
  "${fork_plan}"

expect_failure "unknown optional command is rejected" plan \
  "${TEST_DIR}/optional.json" \
  unknown main 42 osac-project/osac-test-infra feature/test abc1234 '' '' false

echo
echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
