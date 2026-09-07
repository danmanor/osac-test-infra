#!/usr/bin/env bash
# Deterministic tests for optional-workflows.sh.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NORMALIZER="${SCRIPT_DIR}/optional-workflows.sh"
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

assert_contains() {
  local name=$1 expected=$2 actual=$3
  if [[ "${actual}" == *"${expected}"* ]]; then
    echo "PASS: ${name}"
    pass=$((pass + 1))
  else
    echo "FAIL: ${name} (missing=${expected})"
    echo "  actual: ${actual}"
    fail=$((fail + 1))
  fi
}

expect_failure() {
  local name=$1 expected_error=$2 registry=$3
  local output rc
  set +e
  output=$("${NORMALIZER}" build "${registry}" "${TEST_DIR}/active.json" "${TEST_DIR}/failure-output.json" 2>&1)
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]]; then
    echo "FAIL: ${name} (expected non-zero exit)"
    fail=$((fail + 1))
    return
  fi
  assert_contains "${name}" "${expected_error}" "${output}"
}

normalize() {
  local registry=$1
  "${NORMALIZER}" build "${registry}" "${TEST_DIR}/active.json" "${TEST_DIR}/output.json"
  cat "${TEST_DIR}/output.json"
}

cat >"${TEST_DIR}/active.json" <<'JSON'
[
  {
    "id": 101,
    "name": "E2E BMaaS Netris",
    "path": ".github/workflows/e2e-bmaas-netris-full-install-caller.yml",
    "state": "active"
  },
  {
    "id": 102,
    "name": "Disabled workflow",
    "path": ".github/workflows/disabled.yml",
    "state": "disabled_manually"
  }
]
JSON

cat >"${TEST_DIR}/valid.yml" <<'YAML'
version: 1
workflows:
  - command: bmaas-netris
    workflow: e2e-bmaas-netris-full-install-caller.yml
    name: E2E BMaaS Netris
    description: BMaaS networking tests on the Netris infrastructure
    retestable: true
YAML

valid_output=$(normalize "${TEST_DIR}/valid.yml")
assert_eq "valid registry is normalized" \
  '[{"command":"bmaas-netris","workflow":"e2e-bmaas-netris-full-install-caller.yml","name":"E2E BMaaS Netris","description":"BMaaS networking tests on the Netris infrastructure","workflow_id":101,"retestable":true}]' \
  "${valid_output}"

cat >"${TEST_DIR}/empty.yml" <<'YAML'
version: 1
workflows: []
YAML
assert_eq "empty registry produces an empty list" \
  '[]' \
  "$(normalize "${TEST_DIR}/empty.yml")"

cat >"${TEST_DIR}/duplicate.yml" <<'YAML'
version: 1
workflows:
  - command: bmaas-netris
    workflow: e2e-bmaas-netris-full-install-caller.yml
    name: First
    description: First entry
    retestable: true
  - command: bmaas-netris
    workflow: e2e-bmaas-netris-full-install-caller.yml
    name: Duplicate
    description: Duplicate entry
    retestable: false
YAML
expect_failure "duplicate command is rejected" "duplicate command: bmaas-netris" "${TEST_DIR}/duplicate.yml"

cat >"${TEST_DIR}/reserved.yml" <<'YAML'
version: 1
workflows:
  - command: all
    workflow: e2e-bmaas-netris-full-install-caller.yml
    name: Reserved
    description: Reserved command
    retestable: true
YAML
expect_failure "reserved command is rejected" "command is reserved: all" "${TEST_DIR}/reserved.yml"

cat >"${TEST_DIR}/missing.yml" <<'YAML'
version: 1
workflows:
  - command: missing
    workflow: does-not-exist.yml
    name: Missing workflow
    description: This workflow is not active
    retestable: true
YAML
expect_failure "missing workflow is rejected" "registered workflow is missing from active workflows: does-not-exist.yml" "${TEST_DIR}/missing.yml"

cat >"${TEST_DIR}/disabled.yml" <<'YAML'
version: 1
workflows:
  - command: disabled
    workflow: disabled.yml
    name: Disabled workflow
    description: This workflow is disabled
    retestable: true
YAML
expect_failure "disabled workflow is rejected" "registered workflow is disabled: disabled.yml" "${TEST_DIR}/disabled.yml"

echo
echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
