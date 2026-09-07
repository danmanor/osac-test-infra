# Plan: Optional BMaaS Netris registry and slash-command dispatch

> **For the implementation session:** Use `superpowers:subagent-driven-development` to execute this plan task by task, with `superpowers:verification-before-completion` before claiming completion.

**Goal:** Make the manual-only BMaaS Netris workflow discoverable and triggerable through the shared slash-command handler, while preserving existing required-workflow behavior and allowing safe reruns of only previously requested optional runs.

**Scope:** `osac-test-infra` only. The later OSAC repository wrapper is tracked separately in OSAC-4964. The existing twice-daily schedule remains part of this branch.

**Design constraints:**

- Read `.github/optional-workflows.yml` from the current base repository's default branch. A reusable handler invoked by a different repository must not accidentally read the handler repository's registry.
- Dispatch the registered workflow in the current base repository, using the exact PR head repository/ref/SHA as inputs to the Phase 1 caller.
- Use a deterministic run name containing PR number and full SHA so GitHub's run listing can identify the PR/SHA without relying on unavailable workflow-dispatch input metadata.
- Keep `/test all` limited to ordinary PR workflow runs already discovered by the existing handler.
- Treat a missing registry as an empty registry so repositories that have not adopted the convention retain existing slash-command behavior.

## Task 1: Add and validate the optional-workflow registry helper

**Files:**

- Add `.github/optional-workflows.yml` with the `bmaas-netris` entry from the approved design.
- Add `.github/scripts/optional-workflows.sh`.
- Add `.github/scripts/test-optional-workflows.sh`.

**Implementation details:**

1. Define a small registry schema validator/normalizer that converts YAML to JSON with `yq`, requires version `1`, an array of workflows, unique command names, non-reserved command names, valid workflow filenames, display metadata, and boolean `retestable` values.
2. Join registry entries with the active workflow list returned by `gh workflow list`; fail clearly if a registered workflow is missing or disabled rather than silently advertising a broken command.
3. Emit normalized entries containing command, workflow filename, display name, description, workflow ID, and retestable flag. Do not include credentials or arbitrary dispatch fields.
4. Cover valid normalization, empty registry, duplicate/reserved commands, and missing workflow references with a deterministic shell test using temporary fixtures.

## Task 2: Load the registry in the reusable handler

**File:** `.github/workflows/slash-command-handler.yml`

1. Check out the small registry helper from `osac-project/osac-test-infra@main` into an isolated workspace path. Keep the handler independent of the caller repository's checkout contents.
2. Discover the caller repository's default branch and fetch `.github/optional-workflows.yml` from that branch. Treat only a genuine 404 as “no registry”; surface other API failures.
3. Normalize the registry against the caller repository's active workflow list.
4. Fetch each registered workflow YAML from the same default branch and verify it exposes `workflow_dispatch`, so a typo or trigger regression fails before command handling.
5. Extend PR metadata collection with head repository, author login, author association, and fork status while preserving existing outputs.

## Task 3: List and explicitly dispatch optional commands

**Files:** `.github/workflows/slash-command-handler.yml`, `.github/workflows/e2e-bmaas-netris-full-install-caller.yml`

1. Add a stable `run-name` to the Netris caller. PR-triggered/manual PR runs must include `PR #<number> @ <full-sha>`; direct/scheduled runs retain a useful non-PR title.
2. Extend `/test ?` help with normalized optional entries, marked `optional, manual`, including their descriptions. Do not manufacture optional entries from arbitrary `workflow_dispatch` workflows.
3. In the command execution path, resolve an exact optional command before ordinary prefix matching. Re-query the PR immediately before dispatch and reject stale SHA, ref, or head-repository metadata.
4. Detect queued/in-progress/waiting runs of the registered workflow whose run title contains the exact current PR/SHA identity. If one exists, comment with its URL and do not dispatch another run.
5. Dispatch the registered workflow on the base repository default branch with `pr-number`, `pr-repository`, `pr-ref`, `pr-sha`, and fork author metadata. Poll briefly for the new run URL and fall back to the workflow URL if GitHub has not indexed the run yet.
6. Keep `/test all` operating only on `/tmp/available.json`, so never-requested optional workflows are not started implicitly.

## Task 4: Extend `/retest` without starting never-requested optional jobs

**File:** `.github/workflows/slash-command-handler.yml`

1. Re-query PR metadata before selecting runs and refuse to operate if the head moved since the handler began.
2. Preserve the existing failed pull-request workflow query.
3. For each normalized registry entry with `retestable: true`, find failed `workflow_dispatch` runs whose deterministic title identifies the current PR number and full SHA. Add only those existing run IDs to the rerun set.
4. Do not dispatch an optional workflow when no matching previous run exists. Include optional runs in the existing success/error comment and avoid duplicate IDs.

## Task 5: Validate and review

1. Run the optional-workflow shell tests.
2. Run `actionlint` on the changed workflows, `shellcheck` on the changed scripts, `yamllint` on the registry/workflows, and `git diff --check`.
3. Review the resulting diff for unchanged required-workflow behavior, correct fork metadata propagation, no secret exposure, no accidental `/test all` dispatch, and correct default-branch/PR-revision separation.
4. Run the repository's existing relevant checks if available, then report exact validation results and any GitHub-only behavior that still requires a post-merge command test.
