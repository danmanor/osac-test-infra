# VAST storage in the Netris lab, tested over tenant SNAT

**Status:** design for approval
**Date:** 2026-11-24
**Owner:** Dan Manor
**Lab host:** `rdu-infra-edge-06.ecosys.eng.rdu2.dc.redhat.com`
**Repos:** `osac-test-infra` (lab code) and `osac` (E2E tests, per OSAC-3593)

## Intent and why

OSAC tenants can bring arbitrary, overlapping CIDRs, so tenant VPCs are never
peered to storage. The storage network design under test is the SNAT model:
tenant workloads and the management cluster reach a shared storage endpoint
through a NAT boundary, and the storage system identifies the tenant by the
translated source address. See
`OSAC Storage-as-a-Service Network Attachment Requirements` (Model 3, "peering
with NAT") and `r212-vast-nat-overlap.md`.

Today the lab proves only that a **plain NFS server** is reachable over SNAT
(`lab-nfs`, FR5-01/FR5-02). We want the real backend: a VAST cluster in the
Netris lab, reachable over SNAT from a tenant VM, a CaaS PVC, and a BMaaS host,
including two tenants that chose the same CIDR — and then storage-as-a-service
through OSAC on that VAST cluster.

Success is evidence, not configuration: each workload mounts or attaches over
the SNAT path, and the storage side shows the translated source address, not
the tenant's own address.

## Goals

1. A VAST 5.4 loopback cluster running in the Netris lab, reproducible from
   lab code, with no hand steps after `make deploy-storage`.
2. Tenant-to-storage traffic over the VirtualNetwork NATGateway: VM guest,
   CaaS PVC and BMaaS host, each proved by a storage-side observation of the
   tenant's NAT address.
3. Negative cases hold: a VPC without a NATGateway has no storage path, and
   storage is not reachable inbound from outside.
4. Two tenants using the same workload CIDR reach VAST with different
   translated addresses and do not see each other.
5. Stage 3: OSAC storage onboarding against VAST, so a PVC and a VM disk are
   served by VAST through the product path.
6. The lab reports its storage endpoint to the test harness the same way for
   both backends (plain NFS and VAST), so suite code is backend-agnostic.

## Non-goals

- The peering architecture in `osac-vast-netris-architecture.html` (storage
  VPC, hidden storage V-Nets, hybrid CNode ports, mgmt↔VAST peering). The
  data-NIC parameters stay variables so a later move onto a Netris V-Net is a
  config change, not a rewrite.
- Two-NIC L2 attachment, RDMA, S3, multi-node VAST, HA, or performance
  testing. The loopback appliance is a functional test fixture.
- Production licensing, capacity planning, or VAST supportability.
- Changing OSAC's product code. Lab-only helpers stand in until the product
  path exists.
- Adding tests to `osac-test-infra` (OSAC-3593); test changes land in the
  mono-repo's `tests/e2e/networking/storage/`.

## Anti-goals

What would make this a failure even if it "works":

- A VAST install that cannot be reproduced from a clean lab host — a
  hand-built VM that only one person can rebuild.
- Proving the mount with a payload that bypasses the tenant NAT (for example
  from the lab host or from the hub's node network), so the SNAT path is
  unverified.
- Making the VAST appliance reachable from every VPC by widening routes or
  leaks, which would hide the very isolation the test exists to check.
- Leaving the lab in a state where a normal Netris redeploy breaks because an
  unmanaged VM, bridge, or route is in the way.
- Credentials (VAST admin, quay, AWS) committed to either repo.

## Constraints and current state

Lab, as found on 2026-11-24:

| Item | Value |
|---|---|
| Host | 80 cores, 376 GiB RAM (~234 GiB available), 2.5 TiB free on `/` |
| Lab VMs | netris-lab (spines, leaves, softgates, isp, mgmt), `h00` OCP SNO, `h01`/`h02` running, `h03` shut off, `lab-nfs` running |
| Bridges | `br-mgmt` 192.168.16.254/20, `br-public` 198.51.100.9/29, `br-storage` 192.168.123.1/24 |
| External IP pool | `198.51.100.24/29`; live tenant NAT addresses `.25` and `.26` |
| BMaaS provisioning SNAT | `198.51.100.32/29` |
| OSAC | installed 18 h ago in `osac-e2e-ci`; storage classes are local `topolvm` only |
| VAST image | `/home/dmanor/Downloads/vast_5_4.qcow2`, 23 GiB, 1 TiB virtual, sha256 `be2cbdab…186dd7` |

Existing untracked WIP in `/home/test/osac-test-infra` on the lab host (kept,
not replaced, and committed as part of stage 1): `roles/lab_nfs_storage`,
`playbooks/deploy-storage.yml`, `playbooks/verify-storage.yml`, the
`storage-nat` contract, `OSAC_STORAGE_*` exports in `.env.infra`. The
`storage/` E2E suite (FR5-01..04, FR6-01, NFR2-01, NFR3-01) lives in
`/root/osac-storage-e2e`, a **copied monorepo tree with no `.git`**; stage 2
re-homes those files onto a mono-repo feature branch. Its NFS log already
shows mounts from `198.51.100.25`/`.26`.

Installed OSAC in `osac-e2e-ci` has the `storageFulfillment` AAP instance
group enabled and an empty `storage-operations-ig` ConfigMap, so the storage
service surface exists; the operator's `vendorControllers` is `{}` and no VAST
CSI controller is deployed. Stage 3 therefore needs lab values wiring, not a
profile change.

VAST appliance facts from the guides that constrain the build:

- Recommended profile 16 vCPU / 128 GiB / 1 TiB; 24 GiB exhausts memory and
  breaks cluster create.
- **Virtio** boot disk. On IDE the management-DB copy takes 42 minutes and
  `vcli cluster create` times out after ~10.
- `/vast/vman/mgmt-vip` must equal the management address, and bootstrap runs
  as `centos`, not root.
- `EXTRA_VOLUME_MOUNTS="-v /file_server:/file_server"` must be set before
  starting `vast_vms`, or image pulls fall through to private AWS ECR.
- A leftover `INSTALLING` cluster must be deleted before retrying create.
- Guest defaults: `centos`/`centos`; VMS UI `admin`/`123456`.

## Approaches considered

1. **Bridge-attached appliance, fabric SNAT (chosen).** VAST VM on the lab
   host; management NIC on `br-mgmt`, data NIC on a new host bridge outside the
   fabric gateway. Tenants reach the VIP pool through the NATGateway/SoftGate
   SNAT; the hub reaches the infra VIP through the host. Mirrors the proven
   `lab-nfs` path and `r212-vast-nat-overlap.md`; one excluded-CIDR line in
   Netris. Does not exercise Netris server ports/V-Nets.
2. **Appliance as a Netris server port in a storage V-Net.** Closer to
   production: V-Net membership, hybrid ports, EVPN VIP mobility. Needs leaf
   changes, DNAT plus peering, and inherits the VRF/reload fragility recorded
   in r212. Not needed to prove SNAT.
3. **Option 1 now, option 2 later.** Build 1, keep the data NIC parameters as
   variables, so the move is configuration.

Chosen: **option 1**, with option 3's seam (bridge name, guest address,
prefix, and VIP range are role variables). Option 2 is out of scope.

Decisions taken with the owner while writing this:

- SNAT/NAT path is the contract; the peering architecture is out of scope.
- Test scope is the full attachment matrix first, then real storage-as-a-service
  volumes (stage 3 done = a CaaS PVC binds to a VAST volume and a VM disk is
  served by VAST).
- VAST stays up on this lab, `h03` stays off, storage is on-demand and not in
  scheduled or PR CI.
- The existing NFS endpoint and suite stay as the vendor-neutral fallback.
- Per-tenant VAST tenants and views make isolation real at the storage layer,
  and the matrix includes a cross-tenant mount that must be refused.

## Design

### Topology and addressing

```
 tenant VPC (tenant-1)            tenant VPC (tenant-2)
 vm-a 10.0.1.5  bm-1 10.0.1.11    vm-b 10.0.1.5  bm-3 10.0.1.21   (same CIDR)
        |                               |
        +--> NATGateway SNAT --> 198.51.100.25 / .26
                                            |
                                    SoftGate (lab)        hub: h00 mgmt 192.168.16.x
                                            |                      |
                                            +------> host routing <+
                                                       (rdu-infra-edge-06)
                                                             |
                                        br-vast 192.168.124.0/24
                                                             |
                                     VAST eth1 192.168.124.11  (VIP pool .20-.23)
                                     VAST eth0 192.168.16.60 on br-mgmt (API/UI)
```

| Role | Address | Where |
|---|---|---|
| VAST management / API / UI | `192.168.16.60/20`, gw `192.168.16.1` | guest `eth0` on `br-mgmt` |
| VAST data | `192.168.124.11/24`, no default route | guest `eth1` on `br-vast` |
| VAST shared VIP pool | `192.168.124.20`–`192.168.124.23`, gw `192.168.124.1`, subnet `/24`, `vlan 0` | VAST API |
| Host data-side router | `192.168.124.1/24` | `br-vast` on the lab host |
| Tenant NAT sources seen by VAST | `198.51.100.24/29` (workloads) and `198.51.100.32/29` (BMaaS provisioning); the per-tenant observation is whatever address that tenant's NATGateway reports, never a hard-coded `.25`/`.26` | lab ExternalIP pool |
| Reserved range | `192.168.124.0/24` | `netris_extra_excluded_cidrs` |

The host already routes tenant NAT traffic to `br-storage` for `lab-nfs`; the
new range uses the same mechanics, which is why the spike must first confirm
the SoftGate's next hop for `192.168.124.0/24` before any test work.

### VAST appliance lifecycle

- Base image copied to `/var/lib/libvirt/images/vast/vast_5_4.qcow2`, sha256
  and `qemu-img check` verified on every run.
- One qcow2 overlay per deploy (`vast_5_4-lab.qcow2`), so a redeploy gives a
  fresh cluster identity and the base is never modified.
- System libvirt domain `vast-5-4` (r212 used a user session; the lab runs
  system domains), 16 vCPU, 131072 MiB, virtio-blk disk, two virtio NICs with
  fixed MACs, autostart off (the lab's destroy path owns it).
- First boot: DHCP on `eth0` gives a provisional address; the role discovers
  it by MAC, then writes the static `ifcfg-eth0`/`ifcfg-eth1`, the
  `mgmt-vip` file, and the ARP/rp_filter sysctls from `r212-vast-bridge.md`
  §2.1 (both NICs must answer for the pool VIP; `eth0` only for its own).
- Bootstrap and cluster create run detached (`tmux`-equivalent via `nohup`) and
  the role waits on the API for `ONLINE`, not on the UI, with the
  `EXTRA_VOLUME_MOUNTS` and `DISABLE_IPV6_FOR_LOOPBACK` environment set.
- Stage-1 VAST objects, created by the role for the endpoint itself and then
  refreshed per tenant by a `configure-vast-tenants` step that runs after
  `prepare-suite`: one shared `PROTOCOLS` pool on the data network, one VAST
  tenant per OSAC tenant whose client-IP ranges are that tenant's allocated
  NAT addresses (read from the hub's `ExternalIP`, never hard-coded), and one
  NFS view per tenant pinned to its own view policy. That makes tenant
  isolation real at the storage layer: a cross-tenant mount fails at VAST, not
  only on the fabric. The shared pool is what resolves tenant by client IP.
- `configure-vast-tenants` is idempotent and re-runnable; it is the lab
  stand-in for the product code that will do this per tenant.
- Destroy removes the domain, overlay, bridges' guest side, and the reserved
  CIDR lease; the base image stays cached.

### Why the SNAT path is the contract

The tenant's NAT address is the tenant identity VAST sees. That makes the
following observable and testable, and each test must observe it:

- A VM on a tenant default network with a NATGateway mounts the view; VAST's
  own view/client accounting (or a packet capture on the appliance) shows the
  tenant's `default-nat` address.
- A VPC without a NATGateway cannot reach the VIP (no route leaves the VPC).
- Two tenants with `10.0.1.0/24` each mount, each is seen from a different
  translated address, and a cross-tenant mount of the other tenant's view is
  refused by VAST.
- No inbound path exists: the storage network is not reachable from outside
  the tenant VPC except through the NAT boundary. The probe runs from a VPC
  with no NATGateway and from the lab's ISP-side host, never from the lab host
  that owns both bridges.

### Hub and VM-disk path (stage 2)

The hypervisor/SNO (`h00`) is on `br-mgmt`. Two candidate paths, decided by
spike evidence, in this order:

1. Route `192.168.124.0/24` on the hub through the fabric's existing egress so
   the hub's storage traffic is SNATed like a tenant's (the design's stated
   intent; source becomes the OCP SNAT address).
2. If the fabric egress cannot carry it, a host route on the hub via
   `192.168.16.254` (the lab host is the router). The source is then the hub's
   unique `192.168.16.x`, which is still safe because mgmt space cannot
   overlap tenant space.

Per-tenant VM-disk identity does not come from the source address: NVMe/TCP
volumes are mapped to a host NQN. Stage 2 therefore uses **one shared infra
pool** for VM disks and proves tenant isolation through NQN mapping, and uses
**BLOCK** for the per-tenant proof. NFS-tier per-tenant isolation by client IP
is not possible behind one hub SNAT address; that limitation is recorded in
the test docstring and in the design's open items.

### Lab code (osac-test-infra)

```
infra/netris/
  roles/lab_vast_storage/            # new: appliance, bootstrap, cluster, objects
    defaults/main.yml                # all addresses/counts as variables
    tasks/main.yml                   # bridge, image, domain, wait, bootstrap, cluster, objects
    templates/domain.xml.j2
    templates/ifcfg-eth0.j2, ifcfg-eth1.j2, route-eth1.j2, 99-vast-arp.conf.j2
  roles/lab_nfs_storage/             # existing WIP, unchanged fallback
  playbooks/deploy-storage.yml       # dispatch: lab_storage_backend=nfs|vast
  playbooks/verify-storage.yml       # backend-aware endpoint checks
  contracts/storage-nat              # required OSAC_STORAGE_* for both backends
  inventory/group_vars/all.yml       # netris_storage_endpoint_cidr per backend; vast vars
  Makefile                           # deploy-storage/verify-storage already added; add destroy-storage
```

`.env.infra` gains `OSAC_STORAGE_BACKEND`, `OSAC_STORAGE_VAST_API`,
`OSAC_STORAGE_VAST_USER/PASSWORD`, `OSAC_STORAGE_VAST_VIEW`, alongside the
existing `OSAC_STORAGE_NFS_*`. Secrets stay in `.env.infra` (0600) or a
Secret; never committed.

`prep-osac` adds the chosen storage CIDR to
`global.networking.excludedIpv4Cidrs`, so no tenant can capture storage
traffic — the existing WIP hook is reused with the VAST CIDR. The endpoint is
**opt-in**: `netris_storage_endpoint_enabled` defaults to false and
`deploy-storage` is a standalone target, so scheduled and PR CI keep running
without storage. On this lab the intent is to run it once after `deploy-osac`
(a CIDR change later restarts fulfillment; accepted for a lab).

### Appliance image provenance

`vast_5_4.qcow2` cannot live in git. The role treats it as a documented
one-time precondition placed at `/var/lib/libvirt/images/vast/vast_5_4.qcow2`
(the libvirt image directory, so the qemu user can read it; a staging copy
under `/home/test` is not readable by qemu), and fails with that path in the
message when absent. The copy from a developer machine is a one-time step
recorded in the run log, not a role task.

### Tests (osac mono-repo)

The WIP suite already has the right seam: `StorageEndpoint` in
`tests/e2e/networking/storage/endpoint.py` plus `mount_command`,
`wait_for_client`, `marker_on_server`. Work:

1. Add a VAST `StorageEndpoint` implementation: endpoint address from
   `.env.infra`, and the storage-side observation from the VAST API (NFS
   client/connection listing and view policy) instead of the NFS server log.
   Every assertion compares against the tenant's API-reported NAT address
   (the `default-nat` `ExternalIP` `status.address`), not a literal.
2. Keep the NFS `StorageEndpoint` as the fallback; select by
   `OSAC_STORAGE_BACKEND`.
3. Keep FR5-01..04, FR6-01, NFR2-01, NFR3-01 as the stage-1 matrix; extend
   the VM guest case to assert the translated source on the VAST side, and add
   a cross-tenant read attempt that must be refused.
4. Stage 3 tests: register the VAST StorageBackend, resolve the tier's
   StorageClass, create/bind a PVC from a CaaS cluster, and attach a VM disk
   from the infra pool; assert the volume exists in VAST under the right
   tenant and is mapped to the right host NQN. Stage 3 also carries the lab
   values wiring it needs: `operator.vendorControllers` for VAST, the
   `osac-csi-backends` VAST controller and `osac-csi-driver` VAST node
   templates (both exist in the chart and are not deployed today), and the
   `storage-operations-ig` values (endpoint, credentials, tier-to-pool map).

### Delivery stages and evidence

| Stage | Work | Done when |
|---|---|---|
| 0. Spike | Manual install on the lab host per the guides: image, domain, bootstrap, cluster ONLINE, pool/view, mount from a tenant VM | `vcli` shows ONLINE; a tenant VM mounts over NAT; VAST shows `198.51.100.25`; a second tenant shows `.26`; run log committed under `docs/` |
| 1. Codify | `lab_vast_storage` role, dispatch, contract, `.env.infra`, exclusion | `make destroy-storage && make deploy-storage` on the lab reproduces stage 0; `make verify-storage` passes |
| 2. Matrix | Port the E2E suite to the VAST endpoint; create the CaaS cluster and BMaaS host the matrix needs (none exist in the lab today) | FR5-01..04, FR6-01, NFR2-01, NFR3-01 pass against VAST (`make test-storage-nat`) |
| 3. SaaStests | Lab values wiring (vendor controller, CSI templates, `storage-operations-ig`), StorageBackend, StorageClass, PVC, VM disk on VAST | a CaaS PVC binds to a VAST volume and a VM disk is served by VAST via OSAC |

The spike is throwaway in form but its commands and findings must be recorded;
the role is written from that record, not from memory.

### Verification and evidence

- Stage 0/1: cluster `ONLINE` via API, `exportfs`/view policy on VAST, tenant
  VM mount, VAST-side observation of `.25`/`.26`, and packet capture on the
  appliance as secondary evidence.
- Stage 2: JUnit XML in `reports/storage-nat.xml`, one test per workload, with
  the storage-side assertion in the failure message.
- Every stage records the exact commands and observed addresses in the run
  log, so a reviewer can reproduce without the session.

### Resource and risk budget

| Risk | Mitigation |
|---|---|
| 128 GiB VAST competes with the lab | Host has ~234 GiB free. VAST stays up by default on this lab, `h03` stays off, and the role asserts at least 64 GiB free before starting rather than OOMing the SNO. Storage is not part of scheduled or PR CI; it runs on demand only |
| 23 GiB image copy + 1 TiB thin overlay | Copy once to `/var/lib/libvirt/images/vast/`; overlays are dropped on destroy; monitor the 2.5 TiB free pool |
| VAST license/demo expiry | Loopback demo is what r212 ran; confirm during spike that create and mount work without a license. If a license is required, stop and ask before spending more |
| IDE disk regression | Domain XML uses virtio-blk from the start; role asserts the disk bus |
| `mgmt-vip` / ECR pull traps | Role sets both explicitly and asserts `get_registry_url()` before create |
| SoftGate cannot route `192.168.124.0/24` | Verify in the spike before any test work; fall back to putting the data bridge on the existing `br-storage` range (proven) |
| Hub cannot reach the VIP | Decided by spike; hub route via the lab host is the fallback |
| OSAC VAST support is Dev Preview | Stage 3 is allowed to leave the product path failing; failures are reported, not worked around in lab code |
| Unmanaged VM/bridge breaks redeploy | `destroy-full`/`destroy-infra` gain a storage teardown; `deploy-storage` is additive and idempotent |

### Rollback

`make destroy-storage` stops and undefines the domain, removes the overlay and
`br-vast`, drops the excluded CIDR from generated values, and leaves the base
image. `make destroy-full` runs it first. The `lab-nfs` fallback stays intact,
so removing VAST never leaves the suite without an endpoint.

## Open items (resolved in the spike, not by guessing)

1. Does the loopback VAST create and serve NFS without a purchased license?
2. Does the lab SoftGate route `192.168.124.0/24` to the host as it does
   `192.168.123.0/24`, or is a DNAT/route needed?
3. Which hub path carries VM-disk traffic: fabric egress SNAT or host route?
4. Which VAST 5.4 API/CLI calls create a tenant, shared pool with client IP
   ranges, view and view policy, and what is the exact call that lists clients
   for the storage-side assertion?
5. Does VAST resolve a shared pool's tenant by client IP range for NFSv4.1, and
   does it report the translated source (not the VIP) in that listing?
6. How long does creating the CaaS cluster and BMaaS host take on this lab
   before the matrix can run, and does the CaaS worker fit alongside VAST?

## What is left to the builder

- Exact domain XML details (machine type, PCI slots, CPU model) within the
  stated constraints.
- How to make first-boot configuration idempotent (provision address discovery,
  timeouts, retries).
- Role/file layout inside `lab_vast_storage`, and the dispatch variable shape.
- Test-helper structure for the VAST-side observation, and how much of the WIP
  suite is shared versus backend-specific.
- Whether stage 3 needs a lab-side helper (for example, registering the
  StorageBackend by hand) before the product path is complete.
