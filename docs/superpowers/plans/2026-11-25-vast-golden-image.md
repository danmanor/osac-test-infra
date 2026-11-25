# VAST Golden Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a green VAST loopback appliance into a golden qcow2 once, and make every later `make deploy-storage` a copy-on-write clone that reaches `verify-storage` green in under ~15 minutes.

**Architecture:** The role already clones when `lab_vast_use_golden` is true and `vast_5_4-golden.qcow2` exists: the overlay is backed by the golden image, the prepared marker is written (no IDE/dracut), `install.sh` is skipped by its completeness check, and `cluster.yml` starts containers and reconciles the existing ONLINE cluster. Capture is a one-time, explicit lab action.

**Tech Stack:** Ansible, qemu-img, libvirt, VAST loopback appliance.

**Spec:** `docs/superpowers/specs/2026-11-25-vast-golden-image-design.md`

## Global Constraints

- Golden path: `/var/lib/libvirt/images/vast/vast_5_4-golden.qcow2`; deploy overlay: `vast_5_4-lab.qcow2`; base: `vast_5_4.qcow2` (never modified).
- `lab_vast_use_golden` defaults to true; `false` forces the full install path.
- Capture only after `make verify-storage` is green (cluster ONLINE, VMS DB ready).
- Capture stops the VM; write commands only after the current deploy finishes.
- Sequential lab only: never run two clones at once (same data address and VIPs).
- Commit format `OSAC-8073:` / `NO-ISSUE:`.

## Review Focus

1. **A clone boots but containers do not start** — expected: `cluster.yml` starts `registry`, `vast_vms`, `mcvms` before touching the API. Owning task: 2.
2. **The clustered PG/NFS does not recover after a clone boot** — expected: `cluster.yml` waits for the VMS DB ready; if it never recovers, the capture point or boot sequence is wrong. Owning task: 3.
3. **`install.sh` runs on a clone anyway** — expected: the completeness check sees `vman.sh` + `vast_vms` and skips it. Owning task: 3.
4. **A clone deploys the lab objects twice or fails on existing ones** — expected: `objects.yml` looks up by name and creates nothing. Owning task: 3.
5. **The golden is stale or missing** — expected: `use_golden=false` falls back to the full install; a missing golden must not silently produce a broken overlay. Owning task: 1.

---

### Task 1: Prove the golden/no-golden selection logic

**Files:**
- Modify: `infra/netris/roles/lab_vast_storage/tasks/image.yml` (already written)

**Interfaces:**
- Produces: `_lab_vast_from_golden` fact and an overlay backed by `_lab_vast_backing`.

- [ ] **Step 1: Static check**

Run: `cd infra/netris && ansible-lint roles/lab_vast_storage`
Expected: 0 failures.

- [ ] **Step 2: Selection check without a golden**

Run `ansible-playbook playbooks/deploy-storage.yml --check` with no golden file present.
Expected: the overlay backing resolves to `vast_5_4.qcow2` and the marker task removes/stays absent (`_lab_vast_from_golden` false).

- [ ] **Step 3: Commit** (already committed with the role; amend only if changed)

### Task 2: Capture the golden after a green deploy

**Files:** none (lab action; optional `playbooks/capture-golden.yml`).

- [ ] **Step 1: Confirm green**

Run on the lab: `make verify-storage`.
Expected: `PLAY RECAP ... failed=0`; cluster ONLINE; VMS DB ready; `osac-vast-clients` active.

- [ ] **Step 2: Capture**

Run on the lab: `make capture-golden` (or the same commands manually):
`virsh shutdown vast-5-4`; wait `shut off`; `qemu-img convert -O qcow2 -c /var/lib/libvirt/images/vast/vast_5_4-lab.qcow2 /var/lib/libvirt/images/vast/vast_5_4-golden.qcow2.tmp`; `mv` into place; `qemu-img check`.
Expected: golden exists, `qemu-img check` clean, VM stopped.

- [ ] **Step 3: Record metadata**

Write `vast_5_4-golden.qcow2.meta` with build, cluster name, vCPU and date.

### Task 3: Deploy and verify from the golden clone

**Files:**
- Modify (if needed): `infra/netris/roles/lab_vast_storage/tasks/cluster.yml`

- [ ] **Step 1: Destroy the deploy overlay only**

Run: `make destroy-storage`.
Expected: domain undefined, overlay + marker gone, **golden still present**.

- [ ] **Step 2: Deploy from the golden and time it**

Run: `time make deploy-storage`.
Expected: overlay backed by the golden, no IDE boot, no `install.sh`, no format; playbook reaches the cluster reconcile.

- [ ] **Step 3: Verify**

Run: `make verify-storage`.
Expected: green. If containers did not start or the DB is not ready, fix `cluster.yml` and repeat.

- [ ] **Step 4: Record the elapsed time**

Append the clone timings to `docs/lab-vast-spike-2026-11-24.md` (boot, containers, API, DB ready).

- [ ] **Step 5: Commit**

`OSAC-8073: validate the VAST golden clone path`

### Task 4: First storage proof on VAST (stage 2)

**Files:** none in this repo (suite in the mono-repo).

- [ ] **Step 1: Point the suite at VAST**

Set the `OSAC_STORAGE_*` variables to the VAST endpoint (VIP `.20`, export `/lab-storage`, `centos@192.168.16.60`, `/var/log/osac-vast-clients.log`).

- [ ] **Step 2: Run FR5-01**

Run in the mono-repo checkout: `uv run pytest tests/e2e/networking/storage/test_storage_nat.py -k fr5_01 -x -n 0 -v`.
Expected: a tenant VM mounts over the NATGateway and the VAST client log shows the tenant's NAT address.

- [ ] **Step 3: Commit any suite adjustment**

`OSAC-8073: run the storage-over-SNAT suite against VAST`

### Task 5: Document the operating model

**Files:**
- Modify: `infra/netris/README.md`, `docs/lab-vast-spike-2026-11-24.md`

- [ ] **Step 1: Write the runbook**

Cover: full deploy (no golden), capture (one-time), clone deploy, opt-out, refresh, the sequential-lab restriction, and the timings.

- [ ] **Step 2: Commit**

`OSAC-8073: document the VAST golden-image workflow`
