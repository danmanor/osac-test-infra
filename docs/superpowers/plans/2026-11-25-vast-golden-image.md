# VAST Golden Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a green VAST loopback appliance into a golden qcow2 once, and make every later `make deploy-storage` a copy-on-write clone that reaches `verify-storage` green in under ~15 minutes.

**Architecture:** The role already clones when `lab_vast_use_golden` is true and
`vast_5_4-golden.qcow2` exists: the overlay is backed by the golden image, the
prepared marker is written (no IDE/dracut), `install.sh` is skipped by its
completeness check, and `cluster.yml` starts containers and reconciles the
existing ONLINE cluster. That path has several defects that must be closed
**before** a golden is captured (Task 1), because each of them lets a clone
silently take the slow or wrong path. Capture is a one-time, explicit lab
action, and it is preceded by a rehearsal boot so the appliance's reboot
recovery is proved on the overlay itself before it is frozen (Task 2).

**Tech Stack:** Ansible, qemu-img, libvirt, VAST loopback appliance.

**Spec:** `docs/superpowers/specs/2026-11-25-vast-golden-image-design.md`

## Global Constraints

- Golden path: `/var/lib/libvirt/images/vast/vast_5_4-golden.qcow2`; deploy overlay: `vast_5_4-lab.qcow2`; base: `vast_5_4.qcow2` (never modified).
- `lab_vast_use_golden` defaults to true; `false` forces the full install path **only after `make destroy-storage`** — an existing overlay keeps its backing. The role must fail loudly instead of silently ignoring the flag.
- Capture only after `make verify-storage` is green (cluster ONLINE, VMS DB ready), and only after the capture playbook re-asserts it.
- Capture stops the VM; write commands only after the current deploy finishes. Never capture while a `.qcow2.tmp` from an interrupted convert exists — delete it first.
- Sequential lab only: never run two clones at once (same data address, VIPs, MACs and SMBIOS UUID).
- Tasks 2–5 are blocked on the in-flight deploy reaching a green `verify-storage`. Do not run role edits against that deploy while it is mid-install.
- `_lab_vast_from_golden` / `_lab_vast_use_golden` facts are strings (`"True"`/`"False"`) — always compare with `| bool`.
- Commit format `OSAC-8073:` / `NO-ISSUE:`.

## Review Focus

1. **`install.sh` re-runs on a clone (40 min, against a live cluster)** — `install.yml` probes completeness as soon as SSH answers, but `dockerd` may not be up yet, so `docker ps -a` fails and the probe reads as "install incomplete". Owning task: 1, step 1.
2. **A clone does not come back ONLINE after boot** — the whole design rests on the appliance recovering from a cold boot of an already-formatted, already-copied state. Prove it on the overlay *before* freezing it. Owning task: 2, step 3.
3. **`lab_vast_use_golden=false` is silently ignored** — the flag is only consulted when creating a new overlay, so a document escape hatch that does nothing is a trap. Owning task: 1, step 3.
4. **A stale golden is used after `lab_vast_build` changes** — the version can drift with no error. Owning task: 1, step 4.
5. **The suite passes on evidence inherited from the golden** — the client observation log is `touch`ed, not truncated, so an old mount line can satisfy the assertion the whole exercise exists to prove. Owning task: 1, step 6.
6. **A clone deploys the lab objects twice or fails on existing ones** — expected: `objects.yml` looks up by name and creates nothing. Owning task: 3, step 3.
7. **The golden is missing** — the fallback must be visible, not a silent 2.5 h install. Owning task: 1, step 2.

---

### Task 1: Harden the clone path (code, before any capture)

These edits are prerequisites for a golden. They are all small, and none of them
changes the full-install behaviour on a base-image overlay.

**Files:**
- Modify: `infra/netris/roles/lab_vast_storage/tasks/install.yml`
- Modify: `infra/netris/roles/lab_vast_storage/tasks/image.yml`
- Modify: `infra/netris/roles/lab_vast_storage/tasks/cluster.yml`
- Modify: `infra/netris/roles/lab_vast_storage/tasks/clientlog.yml`
- Modify: `infra/netris/roles/lab_vast_storage/templates/domain.xml.j2`
- Modify: `infra/netris/roles/lab_vast_storage/defaults/main.yml`
- Modify: `infra/netris/playbooks/capture-golden.yml`

**Interfaces:**
- Produces: `_lab_vast_installed_ok` (bool) replacing the `_lab_vast_installed.rc` test; `_lab_vast_backing` and `_lab_vast_from_golden` (already exist); `lab_vast_domain_uuid`.

- [ ] **Step 1: Make the install-completeness probe wait for docker**

Replace the single `Check whether the VAST install already completed` task in
`install.yml` (currently `install.yml:18-37`) with one guest-side probe that
does its own bounded wait. This keeps Ansible's retry semantics out of the
decision and behaves correctly on both paths: a base-image guest has no
`vman.sh`, so it answers immediately; a clone waits for `dockerd`.

```yaml
# A clone inherits vman.sh and the containers, but dockerd may still be
# starting when SSH answers. Probing `docker ps -a` too early reads as an
# incomplete install and re-runs install.sh (40 min) against a live cluster.
# The wait lives in the guest so the probe has exactly one meaning.
- name: Probe the VAST install sentinels
  ansible.builtin.command:
    argv:
      - sshpass
      - -p
      - "{{ lab_vast_guest_password }}"
      - ssh
      - -o
      - StrictHostKeyChecking=no
      - -o
      - UserKnownHostsFile=/dev/null
      - -o
      - ConnectTimeout=10
      - "centos@{{ lab_vast_mgmt_ip }}"
      - sudo bash -s
    stdin: |
      set -u
      [ -x /vast/deploy/vman.sh ] || { echo INCOMPLETE; exit 0; }
      for _ in $(seq 60); do
        systemctl is-active --quiet docker &&
          docker ps -a --format '{{ '{{' }}.Names{{ '}}' }}' | grep -qx vast_vms &&
          { echo COMPLETE; exit 0; }
        sleep 5
      done
      echo INCOMPLETE
  register: _lab_vast_install_probe
  changed_when: false

- name: Decide whether the VAST install already completed
  ansible.builtin.set_fact:
    _lab_vast_installed_ok: "{{ 'COMPLETE' in _lab_vast_install_probe.stdout }}"
```

Then change the install block's guard from `when: _lab_vast_installed.rc != 0`
to `when: not (_lab_vast_installed_ok | bool)`.

- [ ] **Step 2: Stop requiring the base image on a golden clone, and make the fallback visible**

`image.yml` currently stats/checksums the base image before it looks at the
golden, so a clone deploy fails if the base is gone even though it is not
needed. Reorder `image.yml` to: stat golden → choose backing facts → then guard
every base-image task with `when: not (_lab_vast_from_golden | bool)`, and make
the *selected* image (base or golden) `0644`.

Add, right after the selection facts:

```yaml
- name: Warn when the golden is requested but missing
  ansible.builtin.debug:
    msg: >-
      lab_vast_use_golden is true but {{ lab_vast_golden_image }} does not
      exist: falling back to a full install (~2.5 h).
  when:
    - lab_vast_use_golden | bool
    - not (_lab_vast_golden.stat.exists | default(false) | bool)
```

Check the golden itself instead of the base: `sha256sum` is not pinned for a
captured image, so run `qemu-img check` and move on.

- [ ] **Step 3: Fail when the existing overlay does not use the selected backing**

`lab_vast_use_golden=false` is currently a no-op while an overlay exists: the
marker and the completeness gate keep the golden in play. `image.yml` already
reads `qemu-img info` into `_lab_vast_overlay_info`; add an assertion after it:

```yaml
- name: Require the overlay to be backed by the selected image
  ansible.builtin.assert:
    that:
      - >-
        ((_lab_vast_overlay_info.stdout | from_json).get('backing-filename', '')
         | basename) == (_lab_vast_backing | basename)
    fail_msg: >-
      {{ lab_vast_overlay }} is backed by
      {{ (_lab_vast_overlay_info.stdout | from_json).get('backing-filename', 'nothing') }},
      but this run selected {{ _lab_vast_backing }}. Run `make destroy-storage`
      before changing lab_vast_use_golden or replacing the golden.
```

- [ ] **Step 4: Refuse a golden captured for a different build**

`capture-golden.yml` records `build=` in `.meta`; nothing reads it. Add, after
the backing is chosen and only when `_lab_vast_from_golden | bool`:

```yaml
- name: Stat the VAST golden metadata
  ansible.builtin.stat:
    path: "{{ lab_vast_golden_image }}.meta"
  register: _lab_vast_golden_meta
  when: _lab_vast_from_golden | bool

- name: Read the VAST golden metadata
  ansible.builtin.slurp:
    src: "{{ lab_vast_golden_image }}.meta"
  register: _lab_vast_golden_meta_body
  when: _lab_vast_golden_meta.stat.exists | default(false)

- name: Require the golden to match the configured build
  ansible.builtin.assert:
    that:
      - "'build=' ~ lab_vast_build in (_lab_vast_golden_meta_body.content | b64decode)"
    fail_msg: >-
      {{ lab_vast_golden_image }} was captured for a different build. Recapture
      it, or set lab_vast_use_golden=false and run `make destroy-storage` for a
      fresh install.
  when: _lab_vast_golden_meta.stat.exists | default(false)

- name: Warn when the golden has no metadata
  ansible.builtin.debug:
    msg: "{{ lab_vast_golden_image }}.meta is missing: build staleness is unchecked."
  when:
    - _lab_vast_from_golden | bool
    - not (_lab_vast_golden_meta.stat.exists | default(false))
```

- [ ] **Step 5: Start the inherited containers deterministically and prove one is up**

Replace the `Start the VAST containers that a golden clone inherits` body
(`cluster.yml:8-26`) with the same bounded guest-side wait, then assert instead
of silently ignoring failures:

```yaml
      set -u
      [ -x /vast/deploy/vman.sh ] || { echo SKIP; exit 0; }
      for _ in $(seq 60); do systemctl is-active --quiet docker && break; sleep 5; done
      for c in registry vast_vms mcvms; do docker start "$c" >/dev/null 2>&1 || true; done
      sleep 5
      docker ps -a --format '{{ '{{' }}.Names{{ '}}' }}{{ '\t' }}{{ '{{' }}.Status{{ '}}' }}'
```

Register it, fail the play with the container list in the message when
`vast_vms` is not `Up` (a wrong container name must be obvious in the first
minute, not after a two-hour ONLINE wait), and keep the list in the task output
so a wrong `mcvms` name is visible.

*Validated by Task 2 Step 3, which runs the same body by hand.*

- [ ] **Step 6: Truncate the client observation log on a fresh deploy**

`clientlog.yml` appends to `/var/log/osac-vast-clients.log` forever, so a clone
inherits the previous run's tcpdump lines — and that log is where the suite
reads the "VAST saw the tenant's NAT address" evidence.

Set a fact in `image.yml` immediately after the `Stat the VAST overlay` task, so
the answer reflects the state before this run creates anything:

```yaml
- name: Record whether this deploy creates a new overlay
  ansible.builtin.set_fact:
    _lab_vast_fresh_overlay: "{{ not _lab_vast_overlay.stat.exists }}"
```

Then add a task at the top of `clientlog.yml`:

```yaml
- name: Reset the VAST client observation log for a new overlay
  when: _lab_vast_fresh_overlay | default(false) | bool
  ansible.builtin.command:
    argv:
      - ssh
      - -i
      - "{{ lab_vast_ssh_key }}"
      - -o
      - StrictHostKeyChecking=no
      - -o
      - UserKnownHostsFile=/dev/null
      - "centos@{{ lab_vast_mgmt_ip }}"
      - sudo
      - bash
      - -c
      - ': > {{ lab_vast_client_log }} && systemctl restart osac-vast-clients.service'
  changed_when: true
```

Never truncate on a plain re-run of `deploy-storage` against a warm overlay:
that is the same overlay carrying evidence from the current session.

- [ ] **Step 7: Pin the domain UUID so a clone has the captured identity**

`domain.xml.j2` has no `<uuid>`, so every `virsh define` invents a new SMBIOS
UUID. Add a lab constant and render it:

```yaml
# defaults/main.yml
# Lab constant: a capture and its clones must present the same SMBIOS UUID to
# the guest. Never change this once a golden exists.
lab_vast_domain_uuid: "6f0c3a4e-0f5b-4a54-9a3e-2f2a2b7c9d10"
```

```xml
<domain type='kvm'>
  <name>{{ lab_vast_domain }}</name>
  <uuid>{{ lab_vast_domain_uuid }}</uuid>
```

A pinned value only takes effect at the next boot, which is why Task 2 Step 3
reboots the overlay before capture.

- [ ] **Step 8: Make the capture playbook self-verifying and space-honest**

In `capture-golden.yml`:

1. Before shutting the domain down, assert the appliance is green with the same
   three checks `verify-storage.yml` uses (cluster `ONLINE`, `degraded_reason`
   not in `UPDATING_CLUSTERED_DB`/`NO_NFS_EXPORT`, `osac-vast-clients` active).
   A capture of a half-broken appliance is permanent.
2. Refuse to start when `{{ lab_vast_golden_image }}.tmp` exists.
3. Default to an **uncompressed** flatten (`qemu-img convert -O qcow2 -S 64k`,
   where `-S` is the sparse granularity, not compression); `-c` makes every
   first read after each clone deploy decompress. Add
   `lab_vast_golden_compress: false` and only pass `-c` when it is true *and*
   Step 2 of Task 2 measured that space requires it.
4. `qemu-img check` the `.tmp` **before** the `mv`.
5. `chmod 0644` the golden (qemu runs as a different uid).
6. Record the date with `lookup('pipe', 'date -Iseconds')`; `gather_facts: false`
   means `ansible_date_time` never resolves and `captured=` is always `unknown`.

- [ ] **Step 9: Static checks**

Run: `cd infra/netris && ansible-lint roles/lab_vast_storage playbooks/capture-golden.yml`
Expected: 0 failures.
Run: `ansible-playbook -i inventory/local.yml playbooks/capture-golden.yml --syntax-check`
Expected: `playbook: playbooks/capture-golden.yml`.
Pre-flight evidence: both passed at `085eecf2` (before these edits).

- [ ] **Step 10: Commit**

`OSAC-8073: harden the VAST golden clone path before capture`

---

### Task 2: Rehearse the boot, measure, then capture the golden

**Files:** none in git (lab action) except the captured numbers in
`docs/lab-vast-spike-2026-11-24.md`.

- [ ] **Step 1: Confirm green**

Run on the lab: `make verify-storage`.
Expected: `failed=0`; cluster ONLINE; VMS DB ready; `osac-vast-clients` active.

- [ ] **Step 2: Measure before assuming disk headroom**

Run on the lab:

```bash
du -sh /var/lib/libvirt/images/vast/vast_5_4*.qcow2
qemu-img info -U --output=json /var/lib/libvirt/images/vast/vast_5_4-lab.qcow2
df -h /var/lib/libvirt/images
```

Expected: the overlay's *allocated* size, so the golden's size (≈ allocated,
minus compression) and the remaining free space are known before anything is
written. If a 1 TiB-allocated overlay and a second copy do not fit in 2.4 TiB,
set `lab_vast_golden_compress: true` and say so in the run log. Record the
numbers.

- [ ] **Step 3: Rehearse the clone boot on the overlay (the real go/no-go)**

The golden is only a frozen copy of the appliance's reboot behaviour. Prove that
behaviour on the overlay first, with the Task 1 Step 7 UUID pinned. A pinned
UUID only reaches the guest at the next *define*, and `domain.yml` only defines a
domain that does not exist — so undefine the domain while keeping its disk:

```bash
cd infra/netris
virsh shutdown vast-5-4
until [ "$(virsh domstate vast-5-4)" = "shut off" ]; do sleep 5; done
virsh undefine vast-5-4          # removes the definition only; the overlay stays
ansible-playbook -i inventory/local.yml playbooks/deploy-storage.yml   # defines with the pinned UUID and starts
```

Then run, by hand, the exact sequence the clone path will run (Task 1 Step 5),
recording a timestamp at each line:

| Milestone | How |
|---|---|
| VM started | `date` before the guest reaches SSH |
| Guest SSH | `until nc -z 192.168.16.60 22; do sleep 2; done` |
| dockerd | `until ssh … systemctl is-active --quiet docker; do sleep 5; done` |
| containers up | the Task 1 Step 5 body, with `docker ps -a` output captured |
| API 200 | `curl -sk -u admin:123456 https://192.168.16.60/api/clusters/` |
| cluster ONLINE | the same poll `cluster.yml` uses |
| DB READY | the same poll `cluster.yml` uses |

Expected: ONLINE and READY with no cluster create, no format, no DB copy, and
the container names confirmed (`registry`, `vast_vms`, `mcvms`).

**If this does not come back ONLINE/READY, stop.** Do not capture and do not
continue to Task 3. Options, in order: try an explicit cluster start via the
`vman.sh … vcli` shape used for create (confirm the subcommand exists with
`vcli cluster --help`; add the same fallback to `cluster.yml` after N polls), or
fall back to the spike's lever 3 (capture after install, before cluster create —
every deploy then pays only ACTIVATING).

- [ ] **Step 4: Capture**

Run on the lab: `make capture-golden`.
Expected: the green assertions pass, the domain stops, the golden exists,
`qemu-img check` is clean on the `.tmp` and the final file, `.meta` carries the
real build and a real timestamp, and the play ends `failed=0`.

- [ ] **Step 5: Record the evidence**

Append to `docs/lab-vast-spike-2026-11-24.md`: overlay and golden allocated
sizes, `df` after capture, the rehearsal timings from Step 3, and the exact
`qemu-img info` of the golden.

- [ ] **Step 6: Commit**

`OSAC-8073: record the VAST golden capture and the rehearsal boot timing`

---

### Task 3: Deploy and verify from the golden clone

**Files:**
- Modify (if needed): `infra/netris/roles/lab_vast_storage/tasks/cluster.yml`

- [ ] **Step 1: Destroy the deploy overlay only**

Run: `make destroy-storage`.
Expected: domain undefined, overlay + marker gone, **golden and `.meta` still
present** (`ls -l /var/lib/libvirt/images/vast/`).

- [ ] **Step 2: Deploy from the golden and time it**

Run: `time ansible-playbook -i inventory/local.yml playbooks/deploy-storage.yml -v`
(`make deploy-storage` does not pass `-v`, and the backing choice must be in the
log). Expected: `_lab_vast_backing` = the golden, no IDE preparation tasks, no
`Install docker and start the VAST install`, no `Create the loopback cluster when
none exists`, and the container start reports `vast_vms` `Up`. Compare against
the Task 2 Step 3 rehearsal.

- [ ] **Step 3: Verify**

Run: `make verify-storage`.
Expected: green. `objects.yml` creates nothing (all lookups hit by name). If the
cluster is not ONLINE or the DB is not ready, fix `cluster.yml` per Task 2
Step 3 and repeat from Step 1.

- [ ] **Step 4: Prove the fast path and record it**

Run: `time make deploy-storage` again *without* `destroy-storage` — this is the
warm path, and it must also be fast and idempotent. Append both timings (cold
clone, warm re-run) with the milestone table to
`docs/lab-vast-spike-2026-11-24.md`.

- [ ] **Step 5: Commit**

`OSAC-8073: validate the VAST golden clone path`

---

### Task 4: First storage proof on VAST (stage 2)

**Files:** none in this repo (suite in the mono-repo).

- [ ] **Step 1: Point the suite at VAST**

Set the `OSAC_STORAGE_*` variables to the VAST endpoint (VIP `.20`, export
`/lab-storage`, `centos@192.168.16.60`, `/var/log/osac-vast-clients.log`).

- [ ] **Step 2: Establish the log baseline**

Record `wc -l /var/log/osac-vast-clients.log` (or its mtime) immediately after
the clone deploy, and assert the suite only matches lines after that point. A
clone that inherits the previous run's tcpdump output can otherwise pass the
NAT-address assertion on stale evidence.

- [ ] **Step 3: Run FR5-01**

Run in the mono-repo checkout: `uv run pytest tests/e2e/networking/storage/test_storage_nat.py -k fr5_01 -x -n 0 -v`.
Expected: a tenant VM mounts over the NATGateway and the VAST client log shows
the tenant's NAT address, on a line written after the baseline.

- [ ] **Step 4: Commit any suite adjustment**

`OSAC-8073: run the storage-over-SNAT suite against VAST`

---

### Task 5: Document the operating model

**Files:**
- Modify: `infra/netris/README.md`, `docs/lab-vast-spike-2026-11-24.md`

- [ ] **Step 1: Write the runbook**

Cover: full deploy (no golden), capture (one-time, self-verifying, after a green
verify), clone deploy, the rehearsal-boot rule before any capture, opt-out
(`lab_vast_use_golden=false` **plus** `make destroy-storage`, and why the flag
alone is refused), stale golden after a build bump, the sequential-lab
restriction (one clone at a time, shared identity and addresses), measured sizes
and the compression trade-off, and the timings.

Also state when *not* to use the golden: to pause the appliance between test
sessions, stop the domain and start it later — `deploy-storage` already
reconciles a warm overlay, and `destroy-storage` is only for a rebuild.

- [ ] **Step 2: Commit**

`OSAC-8073: document the VAST golden-image workflow`
