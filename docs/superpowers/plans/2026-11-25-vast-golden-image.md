# VAST Golden Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a green VAST loopback appliance into a golden qcow2 once, and make every later `make deploy-storage` a copy-on-write clone that reaches `verify-storage` green in under ~15 minutes instead of ~2.5 hours.

**Architecture:** A fresh deploy spends ~2 h on three write-once results that all land on the appliance's single virtio disk: the `install.sh` image import (~40 min), the 1 TiB loopback format (~52 min) and the management-DB copy (~35 min). The golden is that disk, flattened once after a green deploy. A clone deploy creates a qcow2 overlay backed by the golden (a ~200 KiB file, created in a second), boots it with the captured domain UUID, and reconciles: the install is skipped, the cluster is found ONLINE and the DB ready, the lab objects already exist. Task 1 hardens the clone path (the code committed in `5215a7f2` can silently re-run `install.sh`, ignore the opt-out, use a stale golden, delete the captured cluster, or pass the suite on inherited evidence). Task 3 proves the appliance survives a cold boot **before** anything is frozen.

**Tech Stack:** Ansible (verified on ansible-core 2.20; uses only long-standing builtins), qemu-img, libvirt, VAST 5.4 loopback appliance.

**Spec:** `docs/superpowers/specs/2026-11-25-vast-golden-image-design.md`
**Parent plan:** `docs/superpowers/plans/2026-11-24-lab-vast-storage-snat.md` (lab host, sync rule, suite location)

## Verification status of this plan

Verified on the developer machine (2026-11-25, ansible-core 2.20, qemu-img 10.2):

| What | How | Result |
|---|---|---|
| All Task 1 code | `ansible-lint` (production profile) + every repo pre-commit hook | 0 failures |
| `image.yml` selection logic | real run against small qcow2 files, 10 scenarios (Task 1 Step 8) | all as specified |
| Install probe script | stubbed `systemctl`/`docker`, 5 cases | as specified |
| Clone cluster guards | 6 golden × cluster-state cases | clone never deletes/creates; full install unchanged |
| `domain.xml.j2` with and without UUID | `virt-xml-validate` | both validate |
| Capture disk path (flatten, check, chmod, meta, compress flag) | real run of the capture tasks on qcow2 files | standalone, content-identical, meta round-trips into the clone path with the base image deleted |
| Recapture from a golden-backed overlay | flatten, replace the golden, compare | guest view unchanged, VM off |
| `qemu-img measure -U` | against a chain | predicts the flattened size exactly |

**Only the lab can answer:** whether the VAST platform returns ONLINE/READY from a cold boot of its own disk (Task 3), the real sizes and durations (Tasks 2–5), and whether the suite matches only new client-log lines (Task 6). The plan is ordered so these are answered before the next expensive step.

## Global Constraints

- Lab host: `root@rdu-infra-edge-06.ecosys.eng.rdu2.dc.redhat.com`. Lab commands run as root in `/home/test/osac-test-infra/infra/netris`. Code reaches the lab only by the parent plan's sync (from the repo root of the local checkout):
  `rsync -a --exclude .git --exclude logs --exclude artifacts --exclude config --exclude .env.infra ./ root@rdu-infra-edge-06.ecosys.eng.rdu2.dc.redhat.com:/home/test/osac-test-infra/`
- **Never sync while an `ansible-playbook` against the appliance is running.** Templates and included files are read at run time. Check with `pgrep -af ansible-playbook` on the lab first.
- Files under `/var/lib/libvirt/images/vast/`: base `vast_5_4.qcow2` (never modified), golden `vast_5_4-golden.qcow2` + `vast_5_4-golden.qcow2.meta`, deploy overlay `vast_5_4-lab.qcow2` + `vast_5_4-lab.qcow2.prepared`.
- `lab_vast_use_golden` defaults to true. Opt-out is `make destroy-storage` **then** `make deploy-storage EXTRA_VARS='lab_vast_use_golden=false'`. The flag alone against an existing overlay is refused (by design).
- A golden is only valid with its `.meta` (`build=` must equal `lab_vast_build`; `uuid=` is the domain UUID the cluster was created under). Never copy or rename one without the other.
- Capture only via `make capture-golden`; it re-checks green and stops the VM. Use the same `virsh shutdown` for the Task 3 rehearsal, so the rehearsal tests exactly the state a capture freezes.
- Capture before the parent plan's Task 10 (`configure-vast-tenants`) is first run, so only the stage-1 `lab` objects are frozen. Once Task 10 exists, run `make configure-vast-tenants` after every clone deploy: tenant NAT addresses change between OSAC installs, and the golden must not carry a stale allowlist.
- Sequential lab only: one clone at a time (same IPs, MACs, VIPs and domain UUID).
- Commit format `OSAC-8073:` / `NO-ISSUE:`.

## Review Focus

1. **`install.sh` re-runs on a clone** (40 min, rebuilding over a live cluster) — the old probe read `docker ps -a` as soon as SSH answered; a not-yet-started dockerd looked like "not installed". Owning task: 1, step 2.
2. **The appliance does not come back from a cold boot** — the whole design rests on it. Proved on the overlay before any capture. Owning task: 3.
3. **A clone deletes or re-creates its cluster** — the old `cluster.yml` deletes any `FAILED` cluster and creates when none is listed; on a clone that destroys the captured state. Owning task: 1, step 3.
4. **`lab_vast_use_golden=false` silently ignored** — the backing was only chosen when an overlay was created. Owning task: 1, step 1.
5. **A stale golden used after a build bump, or with the wrong identity** — `.meta` was written but never read; no UUID was recorded. Owning task: 1, steps 1 and 5.
6. **The suite passes on evidence inherited from the golden** — the client log was `touch`ed, never reset. Owning tasks: 1 step 4, 6 step 2.
7. **A capture of a half-broken appliance** — the capture only had a comment saying "verify first". Owning task: 1, step 6.

---

### Task 1: Harden the clone path (local code, before any capture)

None of these changes alters the full-install path on a base-backed overlay, except that a stale/foreign overlay now fails fast instead of being silently reused.

**Files:**
- Modify: `infra/netris/roles/lab_vast_storage/tasks/image.yml` (rewrite)
- Modify: `infra/netris/roles/lab_vast_storage/tasks/install.yml`
- Modify: `infra/netris/roles/lab_vast_storage/tasks/cluster.yml`
- Modify: `infra/netris/roles/lab_vast_storage/tasks/clientlog.yml`
- Modify: `infra/netris/roles/lab_vast_storage/templates/domain.xml.j2`
- Modify: `infra/netris/roles/lab_vast_storage/defaults/main.yml`
- Modify: `infra/netris/playbooks/capture-golden.yml` (rewrite)

**Interfaces (facts set by `image.yml`, consumed later in the role):**
- `_lab_vast_from_golden` (bool): this deploy's overlay is, or will be, backed by the golden. Guaranteed to match the existing overlay by the backing assertion.
- `_lab_vast_backing` (path): the selected backing image.
- `_lab_vast_fresh_overlay` (bool): this run created the overlay.
- `_lab_vast_domain_uuid` (str, golden only): rendered into `domain.xml.j2`.
- `.meta` keys written by capture and read by the role: `build`, `uuid` (required); `cluster`, `vcpu`, `memory_mib`, `compressed`, `captured`, `source`, `source_backing`, `tenants`, `views` (informational).

- [ ] **Step 1: Replace `image.yml`**

Order: choose golden vs base first; verify only the image that will be read; on a golden, require `.meta` with a matching build and a UUID; create the overlay; then assert the existing overlay really uses the selected backing (this is what makes the opt-out honest).

Full file:

```yaml
---
# The VAST qcow2 is too large for git. It is a one-time lab precondition,
# cached on the host; the role fails with the path and checksum in the message
# instead of trying to download it.
#
# A golden clone (lab_vast_use_golden and the golden file present) is backed by
# the golden image only: the base image is not read, so it is not required.

- name: Ensure the VAST image directory
  ansible.builtin.file:
    path: "{{ lab_vast_image_dir }}"
    state: directory
    mode: "0755"

- name: Stat the VAST golden image
  ansible.builtin.stat:
    path: "{{ lab_vast_golden_image }}"
  register: _lab_vast_golden
  when: lab_vast_use_golden | bool

- name: Decide whether this deploy clones the golden image
  ansible.builtin.set_fact:
    _lab_vast_from_golden: "{{ (lab_vast_use_golden | bool) and (_lab_vast_golden.stat.exists | default(false)) }}"

- name: Choose the overlay backing image
  ansible.builtin.set_fact:
    _lab_vast_backing: "{{ lab_vast_golden_image if (_lab_vast_from_golden | bool) else lab_vast_base_image }}"

- name: Warn when the golden image is requested but missing
  ansible.builtin.debug:
    msg: >-
      lab_vast_use_golden is true but {{ lab_vast_golden_image }} does not
      exist: this deploy is a full install (~2.5 h).
  when:
    - lab_vast_use_golden | bool
    - not (_lab_vast_from_golden | bool)

- name: Verify the VAST base image
  when: not (_lab_vast_from_golden | bool)
  block:
    - name: Require the VAST base image
      ansible.builtin.stat:
        path: "{{ lab_vast_base_image }}"
      register: _lab_vast_base

    - name: Fail when the VAST base image is missing
      ansible.builtin.assert:
        that:
          - _lab_vast_base.stat.exists
        fail_msg: >-
          {{ lab_vast_base_image }} is missing. Copy the VAST 5.4 appliance image
          there once (sha256 {{ lab_vast_base_image_sha256 }}) before deploying the
          storage endpoint.

    - name: Verify the VAST base image checksum
      ansible.builtin.command:
        argv: [sha256sum, "{{ lab_vast_base_image }}"]
      register: _lab_vast_checksum
      changed_when: false

    - name: Require the expected VAST image checksum
      ansible.builtin.assert:
        that:
          - _lab_vast_checksum.stdout.split()[0] == lab_vast_base_image_sha256
        fail_msg: >-
          {{ lab_vast_base_image }} has the wrong checksum
          ({{ _lab_vast_checksum.stdout.split()[0] }}), expected
          {{ lab_vast_base_image_sha256 }}

# A captured golden has no pinned checksum; its integrity is qemu-img check and
# the build recorded at capture time.
- name: Verify the VAST golden image
  when: _lab_vast_from_golden | bool
  block:
    - name: Read the VAST golden metadata
      ansible.builtin.slurp:
        src: "{{ lab_vast_golden_image }}.meta"
      register: _lab_vast_golden_meta
      failed_when: false

    - name: Parse the VAST golden metadata
      ansible.builtin.set_fact:
        _lab_vast_golden_meta_text: "{{ _lab_vast_golden_meta.content | default('') | b64decode }}"

    - name: Require the golden image metadata
      ansible.builtin.assert:
        that:
          - _lab_vast_golden_meta_text | length > 0
        fail_msg: >-
          {{ lab_vast_golden_image }}.meta is missing, so the golden's build and
          domain UUID are unknown. Recapture with `make capture-golden`, or delete
          the golden for a full install.

    - name: Require the golden image to match the configured build
      ansible.builtin.assert:
        that:
          - ('build=' ~ lab_vast_build) in _lab_vast_golden_meta_text.splitlines()
        fail_msg: >-
          {{ lab_vast_golden_image }} was captured for a different build than
          {{ lab_vast_build }}. Recapture it, or run `make destroy-storage` and
          deploy with lab_vast_use_golden=false.

    - name: Read the captured domain UUID
      ansible.builtin.set_fact:
        _lab_vast_domain_uuid: >-
          {{ _lab_vast_golden_meta_text
             | regex_search('(?m)^uuid=([0-9a-fA-F-]{36})$', '\1')
             | default([''], true) | first }}

    - name: Require the captured domain UUID
      ansible.builtin.assert:
        that:
          - _lab_vast_domain_uuid | length == 36
        fail_msg: "{{ lab_vast_golden_image }}.meta has no uuid= line; recapture the golden."

- name: Check the VAST backing image
  ansible.builtin.command:
    argv: [qemu-img, check, "{{ _lab_vast_backing }}"]
  changed_when: false

- name: Make the VAST backing image readable by libvirt
  ansible.builtin.file:
    path: "{{ _lab_vast_backing }}"
    state: file
    mode: "0644"

- name: Stat the VAST overlay
  ansible.builtin.stat:
    path: "{{ lab_vast_overlay }}"
  register: _lab_vast_overlay

- name: Record whether this deploy creates a new overlay
  ansible.builtin.set_fact:
    _lab_vast_fresh_overlay: "{{ not _lab_vast_overlay.stat.exists }}"

- name: Create the VAST overlay
  when: _lab_vast_fresh_overlay | bool
  ansible.builtin.command:
    argv:
      - qemu-img
      - create
      - -f
      - qcow2
      - -F
      - qcow2
      - -b
      - "{{ _lab_vast_backing }}"
      - "{{ lab_vast_overlay }}"
      - "{{ lab_vast_disk_gb }}G"

# A golden clone is already virtio-ready; a base overlay needs prepare.yml.
- name: Record the preparation state of the new overlay
  ansible.builtin.file:
    path: "{{ lab_vast_prepared_marker }}"
    state: "{{ 'touch' if (_lab_vast_from_golden | bool) else 'absent' }}"
    mode: "0644"
  when: _lab_vast_fresh_overlay | bool

- name: Read the VAST overlay
  ansible.builtin.command:
    argv: [qemu-img, info, -U, --output=json, "{{ lab_vast_overlay }}"]
  register: _lab_vast_overlay_info
  changed_when: false

- name: Require the VAST overlay geometry
  ansible.builtin.assert:
    that:
      - (_lab_vast_overlay_info.stdout | from_json).get('virtual-size', 0) >= (lab_vast_disk_gb | int) * 1024 * 1024 * 1024
    fail_msg: "VAST overlay {{ lab_vast_overlay }} has the wrong virtual size"

# The backing choice is only applied when an overlay is created. Without this
# check, lab_vast_use_golden=false (or a new golden) would be silently ignored
# by every later run against an existing overlay.
- name: Require the VAST overlay to use the selected backing image
  ansible.builtin.assert:
    that:
      - ((_lab_vast_overlay_info.stdout | from_json).get('backing-filename', '') | basename) == (_lab_vast_backing | basename)
    fail_msg: >-
      {{ lab_vast_overlay }} is backed by
      {{ (_lab_vast_overlay_info.stdout | from_json).get('backing-filename', 'nothing') }},
      but this run selected {{ _lab_vast_backing }}. Run `make destroy-storage`
      first, or keep the current overlay with
      EXTRA_VARS='lab_vast_use_golden={{ not (_lab_vast_from_golden | bool) }}'.
```

- [ ] **Step 2: Make the install probe wait for dockerd and refuse a reinstall over a clone**

The probe returns exactly one line, `COMPLETE` or `INCOMPLETE`, and is matched as a whole line (`'COMPLETE' in stdout` would also match `INCOMPLETE`). A base guest has no `/vast/deploy/vman.sh`, so it answers at once; a clone waits up to 5 min for dockerd.

```diff
diff --git a/infra/netris/roles/lab_vast_storage/tasks/install.yml b/infra/netris/roles/lab_vast_storage/tasks/install.yml
index 58c9fc2..294176d 100644
--- a/infra/netris/roles/lab_vast_storage/tasks/install.yml
+++ b/infra/netris/roles/lab_vast_storage/tasks/install.yml
@@ -15,7 +15,11 @@
     argv: [ssh-keygen, -t, ed25519, -N, "", -f, "{{ lab_vast_ssh_key }}"]
     creates: "{{ lab_vast_ssh_key }}"

-- name: Check whether the VAST install already completed
+# A golden clone has vman.sh and the containers, but dockerd may still be
+# starting when SSH answers. Reading `docker ps -a` too early looks like an
+# incomplete install and re-runs install.sh (40 min) against a live cluster,
+# so the probe waits for dockerd in the guest before it decides.
+- name: Probe the VAST install sentinels
   ansible.builtin.command:
     argv:
       - sshpass
@@ -29,15 +33,37 @@
       - -o
       - ConnectTimeout=10
       - "centos@{{ lab_vast_mgmt_ip }}"
-      - >-
-        test -x /vast/deploy/vman.sh &&
-        sudo docker ps -a --format '{{ '{{' }}.Names{{ '}}' }}' | grep -qx vast_vms
-  register: _lab_vast_installed
+      - sudo bash -s
+    stdin: |
+      [ -x /vast/deploy/vman.sh ] || { echo INCOMPLETE; exit 0; }
+      for _ in $(seq 60); do
+        if systemctl is-active --quiet docker; then
+          if docker ps -a --format '{{ '{{' }}.Names{{ '}}' }}' | grep -qx vast_vms; then
+            echo COMPLETE
+          else
+            echo INCOMPLETE
+          fi
+          exit 0
+        fi
+        sleep 5
+      done
+      echo INCOMPLETE
+  register: _lab_vast_install_probe
   changed_when: false
-  failed_when: false
+
+- name: Refuse to reinstall over a golden clone
+  ansible.builtin.assert:
+    that:
+      - "'COMPLETE' in _lab_vast_install_probe.stdout_lines"
+    fail_msg: >-
+      This overlay is a golden clone but the guest does not look installed
+      (docker inactive after 5 min, or no vast_vms container). Running
+      install.sh here would rebuild over the captured cluster; inspect the guest
+      or deploy with lab_vast_use_golden=false after `make destroy-storage`.
+  when: _lab_vast_from_golden | bool

 - name: Install docker and start the VAST install
-  when: _lab_vast_installed.rc != 0
+  when: "'COMPLETE' not in _lab_vast_install_probe.stdout_lines"
   block:
     - name: Install docker and launch the VAST installer
       ansible.builtin.command:
```

- [ ] **Step 3: Start the inherited containers deterministically; never delete or create a cluster on a clone**

```diff
diff --git a/infra/netris/roles/lab_vast_storage/tasks/cluster.yml b/infra/netris/roles/lab_vast_storage/tasks/cluster.yml
index 890181e..5cc0a0f 100644
--- a/infra/netris/roles/lab_vast_storage/tasks/cluster.yml
+++ b/infra/netris/roles/lab_vast_storage/tasks/cluster.yml
@@ -20,11 +20,23 @@
       - "centos@{{ lab_vast_mgmt_ip }}"
       - sudo bash -s
     stdin: |
+      for _ in $(seq 60); do systemctl is-active --quiet docker && break; sleep 5; done
       for c in registry vast_vms mcvms; do
         docker start "$c" >/dev/null 2>&1 || true
       done
+      sleep 5
+      docker ps -a --format '{{ '{{' }}.Names{{ '}}' }} {{ '{{' }}.State{{ '}}' }}'
+  register: _lab_vast_containers
   changed_when: false

+# A wrong container name or a dead dockerd must fail here, not after the
+# two-hour ONLINE wait below.
+- name: Require the VMS container to be running
+  ansible.builtin.assert:
+    that:
+      - "'vast_vms running' in _lab_vast_containers.stdout_lines"
+    fail_msg: "vast_vms is not running. Containers: {{ _lab_vast_containers.stdout_lines }}"
+
 - name: Ensure the VAST management API is reachable
   ansible.builtin.command:
     argv:
@@ -122,8 +134,24 @@
   ansible.builtin.set_fact:
     _lab_vast_clusters: "{{ _lab_vast_clusters_raw.stdout | from_json }}"

+# On a golden clone the cluster and its formatted loopback drives are the
+# captured state. Deleting or re-creating it would rebuild over that data, so a
+# clone fails instead and the operator decides.
+- name: Refuse to delete or create a cluster on a golden clone
+  ansible.builtin.assert:
+    that:
+      - _lab_vast_clusters | selectattr('state', 'in', ['FAILED']) | list | length == 0
+      - _lab_vast_clusters | length > 0
+    fail_msg: >-
+      The golden clone reports clusters {{ _lab_vast_clusters | map(attribute='state') | list }}.
+      A clone must find its captured cluster; it does not delete or create one.
+      Inspect the guest, or deploy with lab_vast_use_golden=false after
+      `make destroy-storage`.
+  when: _lab_vast_from_golden | bool
+
 - name: Delete a leftover cluster that failed
   when:
+    - not (_lab_vast_from_golden | bool)
     - _lab_vast_clusters | selectattr('state', 'in', ['FAILED']) | list | length > 0
   ansible.builtin.command:
     argv:
@@ -142,6 +170,7 @@

 - name: Create the loopback cluster when none exists
   when:
+    - not (_lab_vast_from_golden | bool)
     - _lab_vast_clusters | rejectattr('state', 'in', ['FAILED']) | list | length == 0
   ansible.builtin.command:
     argv:
```

A clone whose cluster is in a transitional state (neither `FAILED` nor missing) passes the guard and waits for ONLINE as before.

- [ ] **Step 4: Reset the client observation log on a new overlay**

The truncation runs after the unit exists (both paths), and only when this run created the overlay.

```diff
diff --git a/infra/netris/roles/lab_vast_storage/tasks/clientlog.yml b/infra/netris/roles/lab_vast_storage/tasks/clientlog.yml
index 9918441..053c4b1 100644
--- a/infra/netris/roles/lab_vast_storage/tasks/clientlog.yml
+++ b/infra/netris/roles/lab_vast_storage/tasks/clientlog.yml
@@ -41,6 +41,30 @@
       systemctl restart osac-vast-clients.service
       systemctl is-active osac-vast-clients.service

+# A golden clone inherits the captured run's tcpdump lines, and the suite reads
+# its NAT-address evidence from this log. Start every new overlay empty; never
+# truncate on a re-run against the same overlay.
+- name: Reset the VAST client observation log for a new overlay
+  when: _lab_vast_fresh_overlay | default(false) | bool
+  ansible.builtin.command:
+    argv:
+      - ssh
+      - -i
+      - "{{ lab_vast_ssh_key }}"
+      - -o
+      - StrictHostKeyChecking=no
+      - -o
+      - UserKnownHostsFile=/dev/null
+      - -o
+      - ConnectTimeout=10
+      - "centos@{{ lab_vast_mgmt_ip }}"
+      - sudo bash -s
+    stdin: |
+      set -e
+      : > {{ lab_vast_client_log }}
+      systemctl restart osac-vast-clients.service
+  changed_when: true
+
 - name: Require the client observation to be running
   ansible.builtin.command:
     argv:
```

- [ ] **Step 5: Render the captured domain UUID on a clone**

The UUID is the one the cluster was created under (read from the live domain at capture). A full install keeps libvirt's random UUID, and `domain.yml` never redefines an existing domain, so a rehearsal boot keeps it too.

```diff
diff --git a/infra/netris/roles/lab_vast_storage/templates/domain.xml.j2 b/infra/netris/roles/lab_vast_storage/templates/domain.xml.j2
index 28f0e29..b8210e0 100644
--- a/infra/netris/roles/lab_vast_storage/templates/domain.xml.j2
+++ b/infra/netris/roles/lab_vast_storage/templates/domain.xml.j2
@@ -1,5 +1,8 @@
 <domain type='kvm'>
   <name>{{ lab_vast_domain }}</name>
+{% if _lab_vast_domain_uuid | default('') | length > 0 %}
+  <uuid>{{ _lab_vast_domain_uuid }}</uuid>
+{% endif %}
   <memory unit='MiB'>{{ lab_vast_memory_mib }}</memory>
   <vcpu>{{ lab_vast_vcpu }}</vcpu>
   <os>
```

- [ ] **Step 6: Make the capture self-verifying, consistent and atomic**

Re-checks green (cluster ONLINE, VMS not degraded by the DB copy, client log active) on the running domain; records tenants/views; reads the domain UUID; shuts down gracefully and fails rather than forcing off; flattens (uncompressed by default); checks and chmods the `.tmp` before moving it; replaces image and metadata together.

```diff
diff --git a/infra/netris/roles/lab_vast_storage/defaults/main.yml b/infra/netris/roles/lab_vast_storage/defaults/main.yml
index 0810949..ba8efda 100644
--- a/infra/netris/roles/lab_vast_storage/defaults/main.yml
+++ b/infra/netris/roles/lab_vast_storage/defaults/main.yml
@@ -27,6 +27,12 @@ lab_vast_prepared_marker: "{{ lab_vast_overlay }}.prepared"
 # cluster identity.
 lab_vast_golden_image: "{{ lab_vast_image_dir }}/vast_5_4-golden.qcow2"
 lab_vast_use_golden: true
+# Compressed backing makes every first read after a clone decompress, and
+# `qemu-img convert -c` is single-threaded. Only enable when space requires it.
+lab_vast_golden_compress: false
+# A guest shutdown that does not finish is not a consistent capture; fail
+# instead of forcing the domain off.
+lab_vast_shutdown_timeout_s: 900
 lab_vast_nbd_device: "/dev/nbd0"
 lab_vast_root_partition: "/dev/nbd0p3"
 lab_vast_mount: "/mnt/vastroot"
```

Full `playbooks/capture-golden.yml`:

```yaml
---
# Capture the current VAST appliance as the golden image. Run it after a green
# `make verify-storage`; it re-checks green itself, because a broken capture is
# permanent. The next `make destroy-storage && make deploy-storage` is a
# copy-on-write clone that skips the install, the 1 TiB format and the
# management-DB copy.
- name: Capture the VAST golden image
  hosts: all
  gather_facts: false
  become: true
  tasks:
    - name: Read the endpoint defaults
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../roles/lab_vast_storage/defaults/main.yml"

    - name: Require the golden image to differ from the deploy overlay
      ansible.builtin.assert:
        that:
          - lab_vast_golden_image != lab_vast_overlay

    - name: Stat a leftover golden image from an interrupted capture
      ansible.builtin.stat:
        path: "{{ lab_vast_golden_image }}.tmp"
      register: _golden_tmp

    - name: Refuse to capture over an interrupted capture
      ansible.builtin.assert:
        that:
          - not _golden_tmp.stat.exists
        fail_msg: "Delete {{ lab_vast_golden_image }}.tmp (an interrupted capture) and rerun."

    - name: Read the VAST domain state
      ansible.builtin.command:
        argv: [virsh, domstate, "{{ lab_vast_domain }}"]
      register: _golden_domstate
      changed_when: false
      failed_when: false

    - name: Require the VAST domain to be running
      ansible.builtin.assert:
        that:
          - _golden_domstate.rc == 0
          - _golden_domstate.stdout | trim == 'running'
        fail_msg: "Capture checks a running, green appliance; {{ lab_vast_domain }} is not running."

    - name: Read the VAST cluster, VMS and client observation state
      ansible.builtin.command:
        argv:
          - ssh
          - -i
          - "{{ lab_vast_ssh_key }}"
          - -o
          - StrictHostKeyChecking=no
          - -o
          - UserKnownHostsFile=/dev/null
          - -o
          - ConnectTimeout=10
          - "centos@{{ lab_vast_mgmt_ip }}"
          - bash -s
        stdin: |
          set -e
          V="https://{{ lab_vast_mgmt_ip }}"
          A="-sk -u admin:{{ lab_vast_admin_password }}"
          curl $A "$V/api/clusters/" | python3 -c 'import json,sys; print("cluster=" + ("ONLINE" if any(c.get("state")=="ONLINE" for c in json.load(sys.stdin)) else "PENDING"))'
          curl $A "$V/api/latest/vms/" | python3 -c 'import json,sys; v=json.load(sys.stdin)[0]; print("vms=" + (v.get("degraded_reason") or "READY"))'
          echo "clientlog=$(systemctl is-active osac-vast-clients.service || true)"
          curl $A "$V/api/latest/tenants/" | python3 -c 'import json,sys; print("tenants=" + ",".join(sorted(t["name"] for t in json.load(sys.stdin))))'
          curl $A "$V/api/latest/views/" | python3 -c 'import json,sys; print("views=" + ",".join(sorted(v["path"] for v in json.load(sys.stdin))))'
      register: _golden_state
      changed_when: false

    - name: Require a green appliance
      ansible.builtin.assert:
        that:
          - "'cluster=ONLINE' in _golden_state.stdout_lines"
          - "'vms=UPDATING_CLUSTERED_DB' not in _golden_state.stdout_lines"
          - "'vms=NO_NFS_EXPORT' not in _golden_state.stdout_lines"
          - "'clientlog=active' in _golden_state.stdout_lines"
        fail_msg: "Not green, refusing to capture: {{ _golden_state.stdout_lines }}"

    - name: Read the VAST domain UUID
      ansible.builtin.command:
        argv: [virsh, domuuid, "{{ lab_vast_domain }}"]
      register: _golden_uuid
      changed_when: false

    - name: Read the deploy overlay
      ansible.builtin.command:
        argv: [qemu-img, info, -U, --output=json, "{{ lab_vast_overlay }}"]
      register: _golden_overlay_info
      changed_when: false

    - name: Shut down the VAST domain for a consistent capture
      ansible.builtin.command:
        argv: [virsh, shutdown, "{{ lab_vast_domain }}"]
      changed_when: true

    - name: Wait for the VAST domain to stop
      ansible.builtin.command:
        argv: [virsh, domstate, "{{ lab_vast_domain }}"]
      register: _golden_stopped
      until: _golden_stopped.stdout | trim == 'shut off'
      retries: "{{ (lab_vast_shutdown_timeout_s | int) // 10 }}"
      delay: 10
      changed_when: false

    - name: Flatten the deploy overlay into a standalone image
      ansible.builtin.command:
        argv: >-
          {{ ['qemu-img', 'convert', '-O', 'qcow2']
             + (['-c'] if (lab_vast_golden_compress | bool) else [])
             + [lab_vast_overlay, lab_vast_golden_image ~ '.tmp'] }}
      changed_when: true

    - name: Check the flattened image
      ansible.builtin.command:
        argv: [qemu-img, check, "{{ lab_vast_golden_image }}.tmp"]
      changed_when: false

    - name: Make the flattened image readable by libvirt
      ansible.builtin.file:
        path: "{{ lab_vast_golden_image }}.tmp"
        mode: "0644"

    # The image and its metadata are replaced together: a golden without a
    # matching .meta is refused by the role, never used with a stale one.
    - name: Remove the previous golden metadata
      ansible.builtin.file:
        path: "{{ lab_vast_golden_image }}.meta"
        state: absent

    - name: Move the golden image into place
      ansible.builtin.command:
        argv: [mv, -f, "{{ lab_vast_golden_image }}.tmp", "{{ lab_vast_golden_image }}"]
      changed_when: true

    - name: Record the golden image metadata
      ansible.builtin.copy:
        dest: "{{ lab_vast_golden_image }}.meta"
        mode: "0644"
        content: |
          build={{ lab_vast_build }}
          cluster={{ lab_vast_cluster_name }}
          uuid={{ _golden_uuid.stdout | trim }}
          vcpu={{ lab_vast_vcpu }}
          memory_mib={{ lab_vast_memory_mib }}
          compressed={{ lab_vast_golden_compress | bool }}
          captured={{ lookup('ansible.builtin.pipe', 'date -Iseconds') }}
          source={{ lab_vast_overlay }}
          source_backing={{ (_golden_overlay_info.stdout | from_json).get('backing-filename', 'none') }}
          {% for line in _golden_state.stdout_lines if line.startswith('tenants=') or line.startswith('views=') %}
          {{ line }}
          {% endfor %}

    - name: Report the capture
      ansible.builtin.debug:
        msg:
          - "Golden image: {{ lab_vast_golden_image }} ({{ lab_vast_golden_image }}.meta)"
          - "Captured objects: {{ _golden_state.stdout_lines | select('match', '^(tenants|views)=') | list }}"
          - "The VAST domain is stopped. Next: make destroy-storage && make deploy-storage"
          - >-
            {{ 'To resume this same base-backed overlay instead, deploy with EXTRA_VARS=lab_vast_use_golden=false.'
               if ((_golden_overlay_info.stdout | from_json).get('backing-filename', '') | basename) == (lab_vast_base_image | basename)
               else 'This overlay is golden-backed and stays valid: make deploy-storage resumes it.' }}
```

- [ ] **Step 7: Static checks**

```bash
cd infra/netris
ansible-lint roles/lab_vast_storage playbooks/capture-golden.yml
for p in capture-golden deploy-storage destroy-storage verify-storage; do ansible-playbook playbooks/$p.yml --syntax-check; done
cd ../.. && pre-commit run --files infra/netris/playbooks/capture-golden.yml infra/netris/roles/lab_vast_storage/defaults/main.yml infra/netris/roles/lab_vast_storage/tasks/*.yml
```

Expected: `Passed: 0 failure(s)`; four `playbook: …` lines; every hook `Passed`/`Skipped`.

- [ ] **Step 8: Prove the image selection locally**

No lab needed. From `infra/netris`, with a scratch directory:

```bash
D=/tmp/vast-image-test; rm -rf $D; mkdir -p $D
cat > _harness.yml <<'EOF'
- hosts: localhost
  connection: local
  gather_facts: false
  vars_files: [roles/lab_vast_storage/defaults/main.yml]
  tasks:
    - ansible.builtin.import_tasks: roles/lab_vast_storage/tasks/image.yml
    - ansible.builtin.debug:
        msg: "from_golden={{ _lab_vast_from_golden }} backing={{ _lab_vast_backing | basename }} fresh={{ _lab_vast_fresh_overlay }} uuid={{ _lab_vast_domain_uuid | default('-') }}"
EOF
run() { ansible-playbook _harness.yml -e lab_vast_image_dir=$D -e lab_vast_base_image=$D/vast_5_4.qcow2 \
  -e lab_vast_disk_gb=1 -e lab_vast_base_image_sha256=$(sha256sum $D/vast_5_4.qcow2 2>/dev/null | cut -d' ' -f1) "$@" \
  2>&1 | grep -E 'from_golden=|is backed by|different build|meta is missing|uuid= line|failed='; }
destroy() { rm -f $D/vast_5_4-lab.qcow2 $D/vast_5_4-lab.qcow2.prepared; }
B=release-5-4-1-sp3-2209349; U=6f0c3a4e-0f5b-4a54-9a3e-2f2a2b7c9d10
qemu-img create -q -f qcow2 $D/vast_5_4.qcow2 1G
run                                                    # A
qemu-img create -q -f qcow2 $D/vast_5_4-golden.qcow2 1G; printf "build=$B\nuuid=$U\n" > $D/vast_5_4-golden.qcow2.meta
run                                                    # H1
run -e lab_vast_use_golden=false                       # H2
destroy; run                                           # B
run                                                    # G
run -e lab_vast_use_golden=false                       # C
destroy; rm $D/vast_5_4.qcow2; run                     # F
destroy; printf "build=release-9\nuuid=$U\n" > $D/vast_5_4-golden.qcow2.meta; run   # D
destroy; rm $D/vast_5_4-golden.qcow2.meta; run         # E
rm -f _harness.yml
```

Expected:

| Case | Situation | Expected |
|---|---|---|
| A | no golden | `failed=0`, backing `vast_5_4.qcow2`, no marker, "full install (~2.5 h)" warning |
| H1 | base overlay exists, golden appears | fails: "is backed by …vast_5_4.qcow2 … Run `make destroy-storage`" |
| H2 | same, `use_golden=false` | `failed=0` (resume the base overlay) |
| B | clone | `failed=0`, `from_golden=True`, backing golden, `fresh=True`, `uuid=6f0c…` |
| G | warm re-run of the clone | `failed=0`, `fresh=False` |
| C | clone overlay, `use_golden=false` | fails: "is backed by …golden…" |
| F | clone with the base image deleted | `failed=0` |
| D | golden for another build | fails: "different build" |
| E | golden without `.meta` | fails: "meta is missing" |

- [ ] **Step 9: Commit**

`OSAC-8073: harden the VAST golden clone path before capture`

---

### Task 2: Wait for the current deploy, sync, measure

**Files:** none in git.

- [ ] **Step 1: Let the in-flight deploy finish**

On the lab: `pgrep -af ansible-playbook` must print nothing. Do not sync before.

- [ ] **Step 2: Sync and confirm green**

Run the sync from the Global Constraints, then on the lab: `make verify-storage`.
Expected: `failed=0`. If it is not green, fix the full install first; there is nothing worth capturing.

With the new code, this overlay is base-backed and no golden exists, so `image.yml` selects the base and passes; the install probe returns `COMPLETE` and skips `install.sh`.

- [ ] **Step 3: Record the pre-boot inventory**

On the lab (root):

```bash
K=/root/.ssh/lab-vast
S="ssh -i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null centos@192.168.16.60"
$S "sudo docker ps -a --format '{{.Names}} {{.State}}'" | sort > /root/vast-containers-before.txt
$S "sudo docker ps -a -q | xargs sudo docker inspect -f '{{.Name}} restart={{.HostConfig.RestartPolicy.Name}}'" | sort > /root/vast-restart-policies.txt
virsh domuuid vast-5-4 > /root/vast-domuuid.txt
cat /root/vast-containers-before.txt /root/vast-restart-policies.txt /root/vast-domuuid.txt
```

This is what "came back" is compared against in Task 3: the CNode/DNode containers of the loopback cluster are started either by their restart policy or by VMS, and the role only starts `registry`, `vast_vms` and `mcvms` itself.

- [ ] **Step 4: Measure the golden before writing it**

```bash
cd /var/lib/libvirt/images/vast
du -h vast_5_4*.qcow2
qemu-img measure -U -O qcow2 vast_5_4-lab.qcow2     # "required size" = uncompressed golden size
df -h /var/lib/libvirt/images
```

If `-U` is rejected by the lab's qemu-img, run `measure` after the Task 3 shutdown instead. Decision: keep `lab_vast_golden_compress: false` unless the required size leaves less than ~200 GiB free (compression is single-threaded and slows every clone's first reads). Record the numbers.

---

### Task 3: Rehearse the cold boot (go/no-go)

**Files:** none in git.

The golden is a frozen copy of this disk, so a clone boots exactly what this rehearsal boots, with the same UUID and MACs. If this fails, a golden cannot work.

- [ ] **Step 1: Shut down the way capture will**

```bash
virsh shutdown vast-5-4
timeout 900 bash -c 'until [ "$(virsh domstate vast-5-4)" = "shut off" ]; do sleep 10; done' && echo stopped
```

If it does not stop within 15 min, record it and stop: the capture would fail the same way (and must never force the domain off).

- [ ] **Step 2: Start the milestone watcher**

In a second shell on the lab, save and run `/root/vast-milestones.sh`:

```bash
#!/bin/bash
K=/root/.ssh/lab-vast; IP=192.168.16.60
S="ssh -i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 centos@$IP"
API="curl -sk -u admin:123456 https://$IP/api"
t0=$(date +%s); ts() { echo "+$(( $(date +%s) - t0 ))s $*"; }
until [ "$(virsh domstate vast-5-4 2>/dev/null)" = running ]; do sleep 2; done; t0=$(date +%s); ts domain running
until timeout 2 bash -c "</dev/tcp/$IP/22" 2>/dev/null; do sleep 2; done; ts ssh
until $S systemctl is-active --quiet docker; do sleep 5; done; ts dockerd
until $S "sudo docker ps --format '{{.Names}}'" | grep -qx vast_vms; do sleep 5; done; ts vast_vms running
until [ "$($S "$API/clusters/ -o /dev/null -w '%{http_code}'")" = 200 ]; do sleep 10; done; ts api 200
until $S "$API/clusters/" | python3 -c 'import json,sys; sys.exit(0 if any(c.get("state")=="ONLINE" for c in json.load(sys.stdin)) else 1)' 2>/dev/null; do sleep 15; done; ts cluster ONLINE
until $S "$API/latest/vms/" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)[0].get("degraded_reason") not in ("UPDATING_CLUSTERED_DB","NO_NFS_EXPORT") else 1)' 2>/dev/null; do sleep 15; done; ts vms db ready
$S "sudo docker ps -a --format '{{.Names}} {{.State}}'" | sort > /root/vast-containers-after.txt
diff /root/vast-containers-before.txt /root/vast-containers-after.txt && ts containers match the pre-boot inventory
```

- [ ] **Step 3: Boot through the role and time it**

In the first shell: `time make deploy-storage 2>&1 | tee /root/vast-rehearsal-deploy.log`, then `make verify-storage`.

Run the skip check from Task 5 Step 2 with `L=/root/vast-rehearsal-deploy.log`. Expected on this warm, base-backed overlay: `Install docker and launch the VAST installer`, `Create the loopback cluster when none exists` and `Rebuild the initramfs inside the running guest` skipped; the client-log reset **not** run (not a new overlay); `objects.yml` prints no `create`; `verify-storage` `failed=0`; the watcher reaches `vms db ready`; the container diff is empty (or differs only in containers that were not running before). `virsh domuuid vast-5-4` still equals `/root/vast-domuuid.txt`.

- [ ] **Step 4: Decide**

- **Green:** continue to Task 4. Record the watcher output.
- **Containers missing after boot:** add them to the `docker start` list in `cluster.yml` (Task 1 Step 3) with the names from the diff, sync, repeat Step 3.
- **Never ONLINE (cluster state stuck, not `FAILED`):** check the VAST CLI for a cluster start, using `cluster.yml`'s create invocation in the guest (`cd /vast/deploy && sudo -E sg docker -c './vman.sh release-5-4-1-sp3-2209349 /vast/deploy/ssh_key.pem vcli -u admin -p 123456 -c cluster --help'`); if one exists and works by hand, add it to `cluster.yml` after a bounded wait and repeat. Never use `start --with-db-cleanup` here: it discards the management DB.
- **DB never READY:** stop. Fall back to the spike's lever 3 (capture after `install.sh`, before cluster create; every deploy pays only the ~52 min ACTIVATING) and revise the design.

---

### Task 4: Capture the golden

**Files:** `docs/lab-vast-spike-2026-11-24.md` (evidence only).

- [ ] **Step 1: Capture**

On the lab: `time make capture-golden`.
Expected: `Require a green appliance` passes, the domain stops, `Check the flattened image` is clean, `failed=0`, and the report lists `tenants=` with only the stage-1 objects (VAST's built-in tenant plus `lab`) and `views=` including `/lab-storage`.

- [ ] **Step 2: Check the artifacts**

```bash
cd /var/lib/libvirt/images/vast
ls -l vast_5_4-golden.qcow2 vast_5_4-golden.qcow2.meta
cat vast_5_4-golden.qcow2.meta                     # build=, uuid= (== /root/vast-domuuid.txt), captured= real timestamp
qemu-img info vast_5_4-golden.qcow2 | grep -E 'virtual size|disk size|backing'   # no backing file
df -h /var/lib/libvirt/images
```

- [ ] **Step 3: Record and commit**

Append to `docs/lab-vast-spike-2026-11-24.md`: the measured sizes (Task 2 Step 4 and the final golden), capture duration, the Task 3 watcher output, the `.meta` contents.
Commit: `OSAC-8073: record the VAST golden capture and the cold-boot rehearsal`

---

### Task 5: Clone, verify, prove the guards on the lab

**Files:**
- Modify (only if the run requires it): `infra/netris/roles/lab_vast_storage/tasks/cluster.yml`
- Modify: `docs/lab-vast-spike-2026-11-24.md`

- [ ] **Step 1: Destroy the deploy overlay only**

`make destroy-storage`, then `ls /var/lib/libvirt/images/vast/`.
Expected: no `vast_5_4-lab.qcow2*`; golden, `.meta` and base still present.

- [ ] **Step 2: Clone deploy, timed**

Start `/root/vast-milestones.sh` in a second shell, then:

```bash
time make deploy-storage 2>&1 | tee /root/vast-clone-deploy.log
L=/root/vast-clone-deploy.log
for t in 'Rebuild the initramfs inside the running guest' 'Install docker and launch the VAST installer' \
         'Create the loopback cluster when none exists' 'Delete a leftover cluster that failed'; do
  grep -A4 "TASK \[lab_vast_storage : $t\]" $L | grep -q skipping && echo "skipped: $t" || echo "NOT SKIPPED: $t"
done
grep -A4 'TASK \[lab_vast_storage : Reset the VAST client observation log for a new overlay\]' $L | grep -qE "^(changed|ok):" && echo "ran: client log reset"
qemu-img info /var/lib/libvirt/images/vast/vast_5_4-lab.qcow2 | grep backing
virsh domuuid vast-5-4; grep '^uuid=' /var/lib/libvirt/images/vast/vast_5_4-golden.qcow2.meta
```

Expected: four `skipped:` lines and `ran: client log reset`; the overlay's backing file is the golden; the two UUIDs are equal; `failed=0`; wall time and watcher output recorded. Target < 15 min.

- [ ] **Step 3: Verify**

`make verify-storage` → `failed=0`. Then: `ssh -i /root/.ssh/lab-vast centos@192.168.16.60 wc -l /var/log/osac-vast-clients.log` → near 0 (only lines since the clone started).

- [ ] **Step 4: Warm re-run is a no-op**

`time make deploy-storage` again. Expected: `failed=0`, the overlay is not recreated, the client log is **not** reset, objects create nothing.

- [ ] **Step 5: The opt-out is refused without a destroy**

`make deploy-storage EXTRA_VARS='lab_vast_use_golden=false'`.
Expected: fails in `Require the VAST overlay to use the selected backing image` (before the domain is touched), naming `make destroy-storage`. Then `make deploy-storage` (default) succeeds again.

- [ ] **Step 6: Record and commit**

Append the clone and warm timings with the milestone table. Commit: `OSAC-8073: validate the VAST golden clone path`

---

### Task 6: First storage proof on the clone

**Files:** none in this repo. Depends on the parent plan's Tasks 10–12 (per-tenant VAST objects, suite re-homed in `/root/osac-storage-work`, VAST endpoint selection). If they are not done yet, stop here; Task 5 is the golden's acceptance.

- [ ] **Step 1: Re-apply the live tenant objects**

`make configure-vast-tenants` (parent plan Task 10). Expected: per-tenant VAST tenants carry the NAT addresses the hub reports now.

- [ ] **Step 2: Confirm the suite cannot pass on old log lines**

In `/root/osac-storage-work/tests/e2e/networking/storage/endpoint.py`, read how `wait_for_client` / `assert_client_in_range` read `/var/log/osac-vast-clients.log`. Required: they consider only lines written after the test's mount started (a byte offset or line count taken before the mount, or a unique marker). If they scan the whole file, change them to record `wc -c` before mounting and read from that offset; commit in the mono-repo. The Task 1 reset makes a clone start empty, but the suite must not depend on that.

- [ ] **Step 3: Run the VM-path cases against the clone**

The parent plan's Task 12 Step 4, from `/root/osac-storage-work`:
`OSAC_STORAGE_BACKEND=vast uv run pytest tests/e2e/networking/storage/test_storage_nat.py -k "fr5_01 or fr5_02 or fr6_01 or nfr2 or nfr3" -x -n 0 -v`
Expected: pass; each observed source equals the tenant's API-reported `default-nat` address.

- [ ] **Step 4: Commit any suite change**

`OSAC-8073: bound the VAST client-log evidence to the current mount`

---

### Task 7: Document the operating model

**Files:**
- Modify: `infra/netris/README.md`, `docs/lab-vast-spike-2026-11-24.md`

- [ ] **Step 1: Write the runbook**

Cover, with the measured numbers:
- **Full install** (no golden, or `lab_vast_use_golden=false` after `destroy-storage`): ~2.5 h.
- **Capture** (`make capture-golden`): when (green, before `configure-vast-tenants` has ever run), what it checks, what it writes, that it leaves the domain stopped.
- **Clone deploy** (`make destroy-storage && make deploy-storage`) and then `make configure-vast-tenants`.
- **Pause/resume without the golden:** `virsh shutdown vast-5-4`, later `make deploy-storage`. The golden is for rebuilds, not for pausing.
- **Refusals and what to do:** overlay/backing mismatch, golden build mismatch, missing `.meta`, clone with a `FAILED` or missing cluster, a clone that does not look installed.
- **Refresh:** after a VAST build bump set `lab_vast_build`, `make destroy-storage`, full install, capture again.
- **Limits:** one clone at a time; clones share the captured cluster identity (GUID, SSH host keys, domain UUID, MACs, IPs).

- [ ] **Step 2: Commit**

`OSAC-8073: document the VAST golden-image workflow`
