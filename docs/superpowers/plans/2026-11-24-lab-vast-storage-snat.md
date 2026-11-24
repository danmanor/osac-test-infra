# VAST-over-SNAT lab storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a VAST 5.4 loopback cluster in the Netris lab, bring it up from lab code, and prove tenant storage over the fabric's SNAT path for VMs, CaaS PVCs and BMaaS hosts, then serve real OSAC volumes from it.

**Architecture:** A libvirt VM on the lab host with its management NIC on `br-mgmt` and its data NIC on a new host bridge `br-vast` (`192.168.124.0/24`) outside the fabric gateway. Tenant workloads reach VAST VIPs through the VirtualNetwork NATGateway (SoftGate SNAT to the tenant's `default-nat` address); the hub reaches the infra VIP through the lab host. A new Ansible role builds the appliance and its VAST objects; the mono-repo E2E suite observes the translated source from a tcpdump log on the VAST guest.

**Tech Stack:** Ansible (infra/netris), libvirt/QEMU, VAST 5.4 loopback appliance (vcli/VMS API), Netris lab, pytest E2E (osac mono-repo), Helm values for OSAC storage.

**Spec:** `docs/superpowers/specs/2026-11-24-lab-vast-storage-snat-design.md`

## Global Constraints

- Lab host: `root@rdu-infra-edge-06.ecosys.eng.rdu2.dc.redhat.com`; runtime checkout `/home/test/osac-test-infra`; mono-repo checkout for tests: `/root/osac-storage-work` (created in Task 11).
- Local repo `osac-test-infra` is the source of truth. Sync to the lab with
  `rsync -a --exclude .git --exclude logs --exclude artifacts --exclude config --exclude .env.infra ./ root@rdu-infra-edge-06.ecosys.eng.rdu2.dc.redhat.com:/home/test/osac-test-infra/`
  before every lab run. Never sync `.env.infra`, `config`, `logs`, `artifacts`.
- VAST: 16 vCPU, 131072 MiB, **virtio-blk** boot disk, 1 TiB qcow2 overlay, loopback cluster, build `release-5-4-1-sp3-2209349`. Never IDE.
- Base image `/var/lib/libvirt/images/vast/vast_5_4.qcow2`, sha256 `be2cbdab375760873aa50d2e6a8aca16cf61bc2f4453605b15b4a35ed0186dd7`.
- Addresses: guest mgmt `192.168.16.60/20` gw `192.168.16.1`; guest data `192.168.124.11/24`, no default route; bridge `br-vast` `192.168.124.1/24`; VIP pool `192.168.124.20`–`192.168.124.23` gw `192.168.124.1` subnet 24 vlan 0; reserved CIDR `192.168.124.0/24`.
- NAT sources: workload pool `198.51.100.24/29`, BMaaS provisioning `198.51.100.32/29`. Tests must use each tenant's API-reported `default-nat` address; **never hard-code `.25`/`.26`**.
- No tests in `osac-test-infra` (OSAC-3593). Test code lands in the osac mono-repo only.
- No credentials in git. `.env.infra` is 0600; run logs redact VAST passwords and keys.
- Ansible: FQCN, `argv` over `command` strings, `changed_when`/`failed_when` on every command, ansible-lint clean.
- Python: `from __future__ import annotations`, ruff line length 120, rules E,F,W,I,UP,ANN,B,SIM,RUF.
- Commit messages: `OSAC-8073: …` or `NO-ISSUE: …`.
- Storage stays opt-in: `netris_storage_endpoint_enabled` default false; no scheduled or PR CI wiring.

## Review Focus

1. **A second `deploy-storage` on a host that already has a domain or overlay** — expected: reconcile and continue, never create `vast-5-4-1` or a second bridge. Owning task: 7.
2. **A tenant's NAT address changes after a rebuild** — expected: the VAST view policy follows the new address, and a stale allowlist is detected, not silently left. Owning task: 10.
3. **A failed cluster create leaves an `INSTALLING` cluster** — expected: the next run deletes it before creating, instead of failing forever. Owning task: 8.
4. **VAST plus the SNO and hosts exceed host memory** — expected: the role refuses to boot before libvirt starts the domain, so the SNO is never OOM-killed. Owning task: 7.
5. **A mount that succeeds without the SNAT path** (run from the lab host or the hub) — expected: the test's evidence check rejects a source that is not inside the tenant NAT range. Owning tasks: 5, 12, 14.

---

## Stage 0 — Spike on the lab host (throwaway, evidence recorded)

### Task 1: Host prep, image, and data bridge

**Files:**
- Create (lab host): `/home/test/cache/vast/vast_5_4.qcow2`
- Create (local): `docs/lab-vast-spike-2026-11-24.md` (run log)

**Interfaces:**
- Produces: a verified base image path, `br-vast` with `192.168.124.1/24`, and a recorded free-memory number used by Task 7's guard.

- [ ] **Step 1: Copy the image and verify it**

```bash
ssh root@rdu-infra-edge-06... 'mkdir -p /home/test/cache/vast'
rsync -avP /home/dmanor/Downloads/vast_5_4.qcow2 root@rdu-infra-edge-06...:/home/test/cache/vast/
ssh root@rdu-infra-edge-06... 'cd /home/test/cache/vast && echo "be2cbdab375760873aa50d2e6a8aca16cf61bc2f4453605b15b4a35ed0186dd7  vast_5_4.qcow2" | sha256sum -c - && qemu-img check vast_5_4.qcow2'
```
Expected: `OK` and no qcow2 errors.

- [ ] **Step 2: Create the data bridge**

```bash
ssh root@rdu-infra-edge-06... 'nmcli con add type bridge ifname br-vast con-name br-vast ipv4.method manual ipv4.addresses 192.168.124.1/24 bridge.stp no ipv6.method disabled || true; nmcli con mod br-vast bridge.stp no; nmcli con up br-vast; ip -br addr show br-vast'
```
Expected: `br-vast UP 192.168.124.1/24`.

- [ ] **Step 3: Record free memory and confirm the range is excluded**

Record `free -m` and confirm `192.168.124.0/24` is not used by any lab VPC (`nmcli`, `ip route`, Netris UI). Put both in the run log under `## Host`.

- [ ] **Step 4: Commit the run log skeleton**

```bash
git add docs/lab-vast-spike-2026-11-24.md
git commit -m "NO-ISSUE: start VAST-over-SNAT lab spike log"
```

### Task 2: Boot the appliance and reach the guest

**Files:**
- Create (lab host): `/var/lib/libvirt/images/vast/vast_5_4-lab.qcow2`, domain `vast-5-4`
- Modify (local): `docs/lab-vast-spike-2026-11-24.md`

**Interfaces:**
- Produces: SSH to `centos@192.168.16.60`; the exact domain XML that Task 7 templates.

- [ ] **Step 1: Create the overlay and define the domain**

Overlay: `qemu-img create -f qcow2 -F qcow2 -b /home/test/cache/vast/vast_5_4.qcow2 /var/lib/libvirt/images/vast/vast_5_4-lab.qcow2 1T`.
Domain: 16 vCPU, 131072 MiB, `<disk type='file' device='disk'><driver name='qemu' type='qcow2'/><target dev='vda' bus='virtio'/>`, two `<interface type='bridge'>` with `model virtio`: `br-mgmt` MAC `52:54:00:5a:54:54`, `br-vast` MAC `52:54:00:5a:54:55`. Record the full XML in the run log.

- [ ] **Step 2: Start and find the guest**

`virsh start vast-5-4`; watch `virsh domifaddr vast-5-4 --source lease` and `ip neigh` on `br-mgmt`. Expected: a DHCP address in `192.168.16.0/20`.

- [ ] **Step 3: Verify the guest is reachable and note the boot disk device**

`ssh centos@<dhcp-ip` (password `centos`); `lsblk` must show `vda` (not `sda`/`hda`). If `vda` is absent, stop: the disk is not virtio.

- [ ] **Step 4: Commit the domain XML finding to the run log**

### Task 3: Bootstrap and cluster create

**Files:**
- Modify (local): `docs/lab-vast-spike-2026-11-24.md`

**Interfaces:**
- Produces: cluster `ONLINE`, API `https://192.168.16.60/api/clusters/` answering, and the exact `vman.sh` sequence Task 8 runs.

- [ ] **Step 1: Write the guest network files and sysctls**

`eth0` static `192.168.16.60/20` gw `192.168.16.1`; `eth1` static `192.168.124.11/24`, `DEFROUTE=no`, no gateway; `route-eth1` for the NAT `/27`s via `192.168.16.1`; the `r212-vast-bridge.md` §2.1 sysctl file (`arp_ignore`, `arp_announce`, `rp_filter=2`, `proxy_arp=0`). Reboot, then confirm `eth0` and `eth1` addresses and that the default is on `eth0`.

- [ ] **Step 2: Set mgmt-vip and bootstrap**

```bash
echo 192.168.16.60 | sudo tee /vast/vman/mgmt-vip
/vast/bundles/vast_bootstrap.sh --interface 192.168.16.60 --skip-prompt   # as centos, not root
curl -sk -u admin:123456 https://192.168.16.60/api/clusters/
```
Expected: the API answers and `mgmt-vip` still contains `192.168.16.60`.

- [ ] **Step 3: Start VMS with the file server mount and prove the registry**

```bash
export EXTRA_VOLUME_MOUNTS="-v /file_server:/file_server"; export DISABLE_IPV6_FOR_LOOPBACK=yes
cd /vast/deploy && ./vman.sh release-5-4-1-sp3-2209349 /vast/deploy/ssh_key.pem stop
./vman.sh release-5-4-1-sp3-2209349 /vast/deploy/ssh_key.pem start
docker exec vast_vms python3 -c 'from vastools.docker_registry import get_registry_url; print(get_registry_url())'
```
Expected: `vastdata.registry.local:5000`. If it prints an ECR host, stop and fix the mount.

- [ ] **Step 4: Create the cluster detached and wait for ONLINE**

Delete any leftover cluster in `INSTALLING` first. Run in `tmux`:
`./vman.sh release-5-4-1-sp3-2209349 /vast/deploy/ssh_key.pem vcli -u admin -p 123456 -c cluster create --build release-5-4-1-sp3-2209349 --vsettings CAS_OVER_RPC=true,IN_CLUSTER_COMMUNICATION_TCP=true --name lab-vast --loopback`
then poll `https://192.168.16.60/api/clusters/` until `state` is `ONLINE`. Record the elapsed time and the license state shown by the API.

- [ ] **Step 5: Commit the bootstrap finding and record license status**

### Task 4: VAST tenant, pool, view, and the client log

**Files:**
- Modify (local): `docs/lab-vast-spike-2026-11-24.md`

**Interfaces:**
- Produces (recorded in the run log under `## VAST object commands`): exact create/read commands for a VAST tenant, a shared `PROTOCOLS` pool, a view and a view policy, and a list-client observation. Task 8 implements these; Task 12 consumes the observation.

- [ ] **Step 1: Discover the object commands**

Run `vcli --help`, `vcli tenant --help`, `vcli vippool --help`, `vcli view --help`, `vcli viewpolicy --help`, and the matching `/api/latest/` REST calls. Record one worked example for each object with its exact JSON fields (`vlan: 0`, `subnet_cidr: 24`, `gw_ip: "192.168.124.1"`, `role: PROTOCOLS`, `ip_ranges: [["192.168.124.20","192.168.124.23"]]`, `cnode_ids: [1,2]`).

- [ ] **Step 2: Create the lab objects**

Create tenant `lab-t1` with client IP range `198.51.100.24/29`, the pool above, view `/lab-t1`, and a view policy allowing `198.51.100.24/29`. Expected: the VIP answers ARP on the guest (`ip neigh` from the host) and `nc -vz 192.168.124.20 2049` succeeds from the host.

- [ ] **Step 3: Prove a mount from the host**

`mount -t nfs -o vers=4.1 192.168.124.20:/lab-t1 /mnt/vast && touch /mnt/vast/host.txt && umount /mnt/vast`. Expected: success. This is a sanity check only, not evidence of the SNAT path.

- [ ] **Step 4: Start the client observation and record the observation command**

Install `tcpdump` if absent; run `tcpdump -ni eth1 -l 'tcp port 2049'` under a systemd unit writing `/var/log/osac-vast-clients.log`, and record the exact unit plus the command that proves a client line appears.

- [ ] **Step 5: Commit the object commands and observation recipe**

### Task 5: Prove the SNAT path from two tenants

**Files:**
- Modify (local): `docs/lab-vast-spike-2026-11-24.md`

**Interfaces:**
- Produces: observed client addresses per tenant and the hub-path decision (fabric egress SNAT vs host route) that Task 10 and Task 17 rely on.

- [ ] **Step 1: From tenant1's VM, mount tenant1's view**

Use the existing FR5-01 harness in `/root/osac-storage-e2e` pointed at `192.168.124.20:/lab-t1` (override `OSAC_STORAGE_*` in the shell). Expected: mount succeeds; the client log shows a source inside `198.51.100.24/29`.

- [ ] **Step 2: From tenant2's VM (same CIDR), mount tenant2's view**

Repeat with `tenant2` credentials and `192.168.124.20:/lab-t2`. Expected: success, and a **different** source inside `198.51.100.24/29`.

- [ ] **Step 3: Attempt the cross-tenant mount**

From tenant1, mount `192.168.124.20:/lab-t2`. Expected: refused by VAST.

- [ ] **Step 4: Probe the hub path from the SNO**

From `h00`, `ip route get 192.168.124.20`, then try a mount/NVMe probe. Record whether it leaves via the fabric egress (SNAT source) or directly via `192.168.16.254`. Decide the stage-3 path here and write it in the run log under `## Hub path`.

- [ ] **Step 5: Commit the evidence**

Include the two source addresses, the cross-tenant refusal, and the hub decision.

---

## Stage 1 — Lab code

### Task 6: Import the storage WIP baseline

**Files:**
- Create: `infra/netris/roles/lab_nfs_storage/{defaults,tasks,templates}/…`
- Create: `infra/netris/playbooks/deploy-storage.yml`, `infra/netris/playbooks/verify-storage.yml`
- Create: `infra/netris/contracts/storage-nat`
- Modify: `Makefile` (test-storage-nat), `infra/netris/Makefile`, `infra/netris/inventory/group_vars/all.yml`, `infra/netris/roles/deploy-infra/tasks/main.yml`, `infra/netris/roles/prep-osac/tasks/{main,generate-values}.yml`

**Interfaces:**
- Produces: the NFS fallback in git, the `netris_storage_endpoint_enabled`/`_cidr` vars, and `OSAC_STORAGE_*` exports that later tasks extend.

- [ ] **Step 1: Create the branch and copy storage-only WIP**

From the lab, copy the untracked `lab_nfs_storage` role and the two playbooks, and the `contracts/storage-nat` file. Apply only the **storage** hunks of the two Makefiles, `all.yml`, `deploy-infra`, and `prep-osac`; do **not** import the EVPN/BFD/active-backup hunks that share those files.

- [ ] **Step 2: Lint and commit the baseline**

Run: `cd infra/netris && ansible-lint` and `make lint` from the root.
Expected: clean. Commit the baseline with `OSAC-8073: import vendor-neutral lab NFS storage endpoint`.

### Task 7: `lab_vast_storage` role — bridge, image, domain, guards

**Files:**
- Create: `infra/netris/roles/lab_vast_storage/defaults/main.yml`
- Create: `infra/netris/roles/lab_vast_storage/tasks/{main,image,domain}.yml`
- Create: `infra/netris/roles/lab_vast_storage/templates/domain.xml.j2`
- Create: `infra/netris/roles/lab_vast_storage/meta/main.yml`

**Interfaces:**
- Vars: `lab_vast_domain`, `lab_vast_vcpu` (16), `lab_vast_memory_mib` (131072), `lab_vast_disk_gb` (1024), `lab_vast_base_image`, `lab_vast_overlay`, `lab_vast_bridge` (`br-vast`), `lab_vast_bridge_ip` (`192.168.124.1/24`), `lab_vast_mgmt_mac`, `lab_vast_data_mac`, `lab_vast_min_free_mem_mb` (65536).
- Produces: a running domain `vast-5-4` with a virtio disk and both bridges; idempotent on re-run.

- [ ] **Step 1: Write the failing verification**

Add to `playbooks/verify-storage.yml`, guarded by `lab_storage_backend | default('nfs') == 'vast'`:
`virsh dominfo vast-5-4` reports `running`; `virsh domblklist` shows `/var/lib/libvirt/images/vast/vast_5_4-lab.qcow2`; `virsh domiflist` shows both MACs on `br-mgmt`/`br-vast`; the disk bus is virtio.

- [ ] **Step 2: Run it to see it fail**

Run from `infra/netris`: `ansible-playbook playbooks/verify-storage.yml -e lab_storage_backend=vast`.
Expected: FAIL, domain not found.

- [ ] **Step 3: Implement the role**

`image.yml`: assert `lab_vast_base_image` exists, verify sha256, `qemu-img check`, create the overlay only when absent. `domain.yml`: assert free memory ≥ `lab_vast_min_free_mem_mb` **before** define (and assert `h03` is shut off), ensure `br-vast` exists, define the domain from the template, ensure `autostart` is off. `main.yml`: call image then domain. The template uses virtio-blk and the two MACs.

- [ ] **Step 4: Run the role twice**

Run: `ansible-playbook playbooks/deploy-storage.yml -e lab_storage_backend=vast` twice, then the verification.
Expected: second run reports no changes except the domain state; verification passes.

- [ ] **Step 5: Negative memory test**

Run with `-e lab_vast_memory_mib=400000`. Expected: the role fails before `virsh define` with the free-memory message.

- [ ] **Step 6: Commit**

`OSAC-8073: add the lab_vast_storage domain role`

### Task 8: Role — guest network, bootstrap, cluster, objects, client log

**Files:**
- Create: `infra/netris/roles/lab_vast_storage/tasks/{network,bootstrap,cluster,objects,clientlog}.yml`
- Create: `infra/netris/roles/lab_vast_storage/templates/{ifcfg-eth0,ifcfg-eth1,route-eth1,99-vast-arp.conf,osac-vast-clients.service}.j2`

**Interfaces:**
- Vars: `lab_vast_mgmt_ip` (`192.168.16.60`), `lab_vast_mgmt_prefix` (20), `lab_vast_mgmt_gateway` (`192.168.16.1`), `lab_vast_data_ip` (`192.168.124.11`), `lab_vast_data_prefix` (24), `lab_vast_build`, `lab_vast_admin_user/password`, `lab_vast_pool_name`, `lab_vast_pool_range`, `lab_vast_pool_gateway`, `lab_vast_view_prefix`, `lab_vast_client_log`, `lab_vast_ssh_user/key`.
- Produces: cluster `ONLINE`, pool/view/tenant created, client log running. Uses the commands recorded in Task 4's `## VAST object commands`.

- [ ] **Step 1: Write the failing verification**

Extend `verify-storage.yml`: `curl -sk -u … https://192.168.16.60/api/clusters/` reports `ONLINE`; the pool exists with the expected range/vlan/gw; `nc -vz 192.168.124.20 2049` passes; `systemctl is-active osac-vast-clients` is `active`.

- [ ] **Step 2: Run it to see it fail**

Expected: FAIL, API unreachable.

- [ ] **Step 3: Implement the guest network and bootstrap**

`network.yml`: discover the DHCP address by MAC, install the SSH key (`sshpass` + `ssh-copy-id`, password from a vaulted var, never logged), write the ifcfg/route/sysctl templates, reboot when they change, wait for the static address. `bootstrap.yml`: write `mgmt-vip`, run `vast_bootstrap.sh`, assert the API answers.

- [ ] **Step 4: Implement the cluster create**

`cluster.yml`: delete any cluster in `INSTALLING`, start `vman.sh` with `EXTRA_VOLUME_MOUNTS`/`DISABLE_IPV6`, assert `get_registry_url()` is the local registry, create the cluster, poll `ONLINE` with `retries`/`delay` and a clear failure message.

- [ ] **Step 5: Implement the objects and client log**

`objects.yml`: create the tenant/pool/view/view policy idempotently (look up by name first). `clientlog.yml`: install the `tcpdump` unit.

- [ ] **Step 6: Test the INSTALLING cleanup**

Create a dummy cluster entry via the API in `INSTALLING`, run the role, and confirm it is deleted before create and the run reaches `ONLINE`.

- [ ] **Step 7: Run end to end and verify**

Run `deploy-storage` then `verify-storage` with `lab_storage_backend=vast`. Expected: all assertions pass.

- [ ] **Step 8: Commit**

`OSAC-8073: bootstrap the VAST cluster and its lab objects from the role`

### Task 9: Dispatch, contract, `.env.infra`, exclusion, destroy

**Files:**
- Modify: `infra/netris/playbooks/deploy-storage.yml`, `playbooks/verify-storage.yml`
- Create: `infra/netris/playbooks/destroy-storage.yml`
- Modify: `infra/netris/Makefile`, `infra/netris/contracts/storage-nat`, `infra/netris/inventory/group_vars/all.yml`, `infra/netris/roles/prep-osac/tasks/main.yml`, `infra/netris/roles/prep-osac/tasks/generate-values.yml`

**Interfaces:**
- Vars: `lab_storage_backend` (`nfs`|`vast`, default from `OSAC_STORAGE_BACKEND`), `netris_storage_endpoint_cidr` (nfs `192.168.123.0/24`, vast `192.168.124.0/24`).
- Exports: `OSAC_STORAGE_BACKEND`, `OSAC_STORAGE_NFS_SERVER` (VIP for vast), `OSAC_STORAGE_NFS_EXPORT` (view prefix), `OSAC_STORAGE_SSH_HOST` (`centos@192.168.16.60`), `OSAC_STORAGE_SSH_IDENTITY` (`/root/.ssh/lab-vast`), `OSAC_STORAGE_LOG_PATH`, `OSAC_STORAGE_VAST_API/USER/PASSWORD/POOL`.
- Targets: `deploy-storage`, `verify-storage`, `destroy-storage`; `destroy-full` runs `destroy-storage` first.

- [ ] **Step 1: Write the failing contract check**

Run `make _validate-suite-contract INFRA=netris TEST_SUITE=storage-nat` after sourcing `.env.infra`.
Expected: FAIL on missing `OSAC_STORAGE_BACKEND`.

- [ ] **Step 2: Implement the dispatch and exports**

`deploy-storage.yml` includes `lab_nfs_storage` or `lab_vast_storage` by `lab_storage_backend`; `destroy-storage.yml` stops/undefines the domain, removes the overlay and `br-vast`, and leaves the base image; the Makefile exports the new variables; the contract lists both backends' required vars; the exclusion uses the backend's CIDR.

- [ ] **Step 3: Run the full storage lifecycle**

`make destroy-storage && make deploy-storage OSAC_STORAGE_BACKEND=vast && make verify-storage OSAC_STORAGE_BACKEND=vast`.
Expected: destroy is clean, deploy reproduces the cluster, verify passes.

- [ ] **Step 4: Deploy OSAC with the exclusion in place**

Enable the endpoint (`-e netris_storage_endpoint_enabled=true`), rerun `make prep-osac` and the OSAC install (or a fresh `make deploy-osac`), then assert the deployed `global.networking.excludedIpv4Cidrs` contains `192.168.124.0/24` and fulfillment is healthy. Without this, a tenant can claim the storage range.

- [ ] **Step 5: Confirm normal CI is unaffected**

`grep netris_storage_endpoint_enabled infra/netris/inventory/group_vars/all.yml` shows `false`; `git diff` adds no CI workflow.

- [ ] **Step 6: Commit**

`OSAC-8073: dispatch and report the lab storage backend`

### Task 10: Per-tenant VAST objects from the live allocations

**Files:**
- Create: `infra/netris/playbooks/configure-vast-tenants.yml`
- Create: `infra/netris/roles/lab_vast_storage/tasks/tenants.yml`
- Modify: `infra/netris/Makefile` (`prepare-suite` hook or a `configure-vast-tenants` target), `infra/netris/contracts/storage-nat`

**Interfaces:**
- Produces: one VAST tenant per OSAC tenant, client-IP ranges equal to the tenant's `default-nat` `status.address`, one view per tenant `{{ lab_vast_view_prefix }}{{ tenant }}`, one view policy per tenant.

- [ ] **Step 1: Write the failing assertion**

Add to `verify-storage.yml` for vast: for each tenant in `tenant1 tenant2`, the VAST tenant exists, its client range equals the hub's `ExternalIP` address for that tenant's `default-nat`, and its view policy admits exactly that address.

- [ ] **Step 2: Run it to see it fail**

Expected: FAIL, `lab-t1`/`lab-t2` ranges do not match the live addresses.

- [ ] **Step 3: Implement**

Read the tenant names and their `default-nat` addresses from the hub (`kubectl get externalip -o json`, name `default-nat`, label/annotation for the tenant; tenant2 may need its namespace/tenant filter). For each, `vcli tenant create-or-update` and the view policy. Refuse to run when a tenant has no allocated address (do not fall back to the pool CIDR).

- [ ] **Step 4: Test idempotency and address change**

Run twice: second run changes nothing. Then delete and recreate one tenant's `default-nat` (or use a scratch tenant), rerun, and assert the range follows the new address.

- [ ] **Step 5: Commit**

`OSAC-8073: configure VAST tenants from live NAT allocations`

---

## Stage 2 — E2E matrix

### Task 11: Re-home the WIP suite onto a mono-repo branch

**Files:**
- Create (lab host, mono-repo): `tests/e2e/networking/storage/{__init__,conftest,endpoint,test_endpoint,test_storage_nat}.py`
- Modify: `tests/e2e/core/wait_kinds.py`, `tests/e2e/AGENTS.md`

**Interfaces:**
- Produces: `/root/osac-storage-work` on branch `storage-nat-vast` with the suite running against the NFS backend.

- [ ] **Step 1: Create the checkout and branch**

`git clone --local /opt/osac /root/osac-storage-work && cd /root/osac-storage-work && git checkout -b storage-nat-vast`.
Copy the five suite files from `/root/osac-storage-e2e`, plus the `wait_kinds.py` and `AGENTS.md` deltas (diff them against the clone first; port only the storage additions).

- [ ] **Step 2: Run the NFS baseline**

Source `infra/netris/.env.infra` with `OSAC_STORAGE_BACKEND=nfs` (the lab-nfs endpoint), then `uv run pytest tests/e2e/networking/storage/test_storage_nat.py -x -n 0 -v`.
Expected: FR5-01 passes against NFS. If it fails for an unrelated harness reason, fix or record before touching VAST.

- [ ] **Step 3: Commit**

`OSAC-8073: re-home the storage-over-SNAT suite`

### Task 12: VAST endpoint selection and VM-path tests

**Files:**
- Modify (mono-repo): `tests/e2e/networking/storage/endpoint.py`, `tests/e2e/networking/storage/conftest.py`, `tests/e2e/networking/storage/test_endpoint.py`

**Interfaces:**
- Add: `StorageEndpoint.export_for(tenant: str) -> str` (returns `f"{export_root}/{tenant}"` when the backend is vast, else `export`); `from_env` reads `OSAC_STORAGE_BACKEND` and raises when a vast var is missing.
- Produces: FR5-01/02, FR6-01, NFR2-01, NFR3-01 passing against VAST.

- [ ] **Step 1: Write the failing unit tests**

In `test_endpoint.py`: `from_env` with `OSAC_STORAGE_BACKEND=vast` builds a VAST endpoint; `export_for("tenant1")` returns `/lab-t1`; a client line `198.51.100.27.5000 > 192.168.124.20.2049` yields source `.27`; a source outside the pool is rejected by the new `assert_client_in_range(endpoint, expected_addr, run=…)` helper.

- [ ] **Step 2: Run them to see them fail**

`uv run pytest tests/e2e/networking/storage/test_endpoint.py -v` → FAIL.

- [ ] **Step 3: Implement the endpoint additions**

`export_for`, backend-aware `from_env`, and `assert_client_in_range` that fails when the observed source is not the tenant's API-reported address.

- [ ] **Step 4: Run the VM-path tests against VAST**

`OSAC_STORAGE_BACKEND=vast uv run pytest tests/e2e/networking/storage/test_storage_nat.py -k "fr5_01 or fr5_02 or fr6_01 or nfr2 or nfr3" -x -n 0 -v`.
Expected: pass, each asserting the API-reported NAT address.

- [ ] **Step 5: Commit**

`OSAC-8073: select the VAST endpoint and assert the translated source`

### Task 13: CaaS and BMaaS prerequisites

**Files:** none in git; lab state only.

**Interfaces:**
- Produces: one CaaS cluster and one BMaaS host in tenant1, with their NATGateways ready.

- [ ] **Step 1: Create the CaaS cluster**

From the runtime checkout: `make setup-caas && make deploy-caas` (or `make deploy-suite DEPLOY_SUITE=caas CAAS_WORKER_COUNT=1`). Expected: the cluster reaches Ready and its `default-nat` address is allocated.

- [ ] **Step 2: Create the BMaaS host**

`make setup-bmaas && make deploy-bmaas`, or the BMI creation the suite expects. Expected: one `BareMetalInstance` Running with its tenant NATGateway.

- [ ] **Step 3: Record the resource impact**

`free -m` and `virsh list`; record in the run log. If the SNO is unhealthy, stop and reassess before running the matrix.

### Task 14: Full matrix against VAST

**Files:** none new; possible test fixes in `test_storage_nat.py`.

**Interfaces:**
- Produces: `reports/storage-nat.xml` with FR5-01..04, FR6-01, NFR2-01, NFR3-01 against VAST.

- [ ] **Step 1: Run the full suite**

`OSAC_STORAGE_BACKEND=vast make test-storage-nat` from the runtime checkout.
Expected: all cases pass; FR5-03 and FR5-04 observe the tenant NAT address, not the worker's own.

- [ ] **Step 2: Prove the evidence gate fails when bypassed**

Run FR5-01 with an intentionally wrong expected source (for example, patch the expected address to `192.168.16.254`). Expected: FAIL with the source-mismatch message. Revert.

- [ ] **Step 3: Commit test fixes and the JUnit evidence path**

---

## Stage 3 — Storage as a service on VAST

### Task 15: Lab values wiring for VAST

**Files:**
- Modify: `infra/netris/roles/prep-osac/tasks/*` (values generation), `infra/netris/values/*/…` or the runtime `netris.yaml` overlay
- Test: `playbooks/verify-storage.yml`

**Interfaces:**
- Sets: `operator.vendorControllers` for VAST, `osac-csi-backends` VAST controller, `osac-csi-driver` VAST node plugin, and the `storage-operations-ig` values (VAST API URL, credentials Secret, pool, tier map).

- [ ] **Step 1: Write the failing verification**

`verify-storage.yml`: the VAST controller and node pods exist and are Ready, the `storage-operations-ig` ConfigMap is populated, and the VAST CRDs/regsitrations are present.

- [ ] **Step 2: Run it to see it fail**

Expected: FAIL, no VAST CSI pods and empty ConfigMap.

- [ ] **Step 3: Implement the values**

Read `osac-csi-driver/charts/csi-backends/values.yaml` and `csi-driver/values.yaml` for the exact keys and image references; read `osac-installer/charts/osac/values.yaml` `vendorControllers` and `storageFulfillment` for the shape. Keep credentials in the generated 0600 runtime overlay. Redeploy with the overlay and wait for readiness.

- [ ] **Step 4: Verify and commit**

### Task 16: StorageBackend, StorageClass, and a CaaS PVC

**Files:**
- Create (mono-repo): `tests/e2e/networking/storage/test_storage_service.py`
- Modify: `tests/e2e/networking/storage/conftest.py` (fixtures for the backend/class/PVC)

**Interfaces:**
- Produces: a PVC on the CaaS cluster bound to a VAST-backed PV, and a VAST-side volume visible under the right tenant.

- [ ] **Step 1: Write the failing test**

`test_saas_nfs_pvc_binds`: create a StorageBackend (VAST management endpoint + credentials from env), wait for its tier's StorageClass, create a PVC in the hosted cluster, wait Bound, write/read a file, assert the VAST API lists the volume under the tenant, then clean up.

- [ ] **Step 2: Run it to see it fail**

Expected: FAIL (no StorageClass / no bind).

- [ ] **Step 3: Implement the fixtures/registration**

Use the public/private API the way the existing storage suite does; do not pre-create the class by hand if the API can. Where the product path cannot yet do it, create the backend/tier through the API and record the failure precisely.

- [ ] **Step 4: Run to pass and commit**

### Task 17: VM disk from VAST with NQN isolation

**Files:**
- Create (mono-repo): `tests/e2e/networking/storage/test_storage_service_vm.py`

**Interfaces:**
- Consumes: Task 16's backend/class fixtures; the hub path decision from Task 5.

- [ ] **Step 1: Write the failing test**

`test_saas_vm_disk_from_vast`: create a ComputeInstance whose disk comes from the VAST class, wait Running, assert the VAST API shows the volume mapped to the VM's host NQN; from tenant2's VM, assert the volume is not mounted/visible.

- [ ] **Step 2: Run it to see it fail**

- [ ] **Step 3: Implement and pass**

Use the recorded hub path (SNAT or host route). If the hub path decision from Task 5 needs revisiting, record it in the run log before changing the test.

- [ ] **Step 4: Commit**

### Task 18: Documentation and final clean run

**Files:**
- Modify: `infra/netris/README.md`, `AGENTS.md` (lab layer), `docs/lab-vast-spike-2026-11-24.md`
- Create: `docs/storage-over-snat.md` (operator runbook: deploy, verify, destroy, evidence)

**Interfaces:** none.

- [ ] **Step 1: Write the runbook**

Cover: prerequisites (image cache, RAM floor, h03 off), `make deploy-storage OSAC_STORAGE_BACKEND=vast`, `make configure-vast-tenants`, `make verify-storage`, `make test-storage-nat`, `make destroy-storage`; the SNAT evidence rule; what not to do (IDE disk, mgmt-vip, ECR pull, widening routes).

- [ ] **Step 2: Final clean run**

`make destroy-storage && make deploy-storage && make configure-vast-tenants && make verify-storage && make test-storage-nat` on the lab, from a clean state.
Expected: green, JUnit XML attached to the run log.

- [ ] **Step 3: Commit and open the two PRs**

`osac-test-infra` branch for lab code; mono-repo branch for tests. PR descriptions link the design and the run log.

---

## Self-review notes

- Spec §Goals 1–6 map to Tasks 7–9 (1), 12/14 (2), 12 (3), 10/12 (4), 15–17 (5), 9/12 (6).
- Spec §Open items are owned by the spike tasks: license (3.4), SoftGate routing and hub path (5.4), object/view APIs (4.1–4.4), CaaS/BMaaS cost (13.3).
- Review Focus items each have a named test.
