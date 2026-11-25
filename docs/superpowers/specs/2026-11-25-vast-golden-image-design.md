# VAST golden image — design

**Status:** approved approach, implementation pending validation
**Date:** 2026-11-25
**Context:** `docs/superpowers/specs/2026-11-24-lab-vast-storage-snat-design.md`

## Intent

A fresh VAST loopback deploy costs ~2.5 h on the lab host, dominated by three
CPU-bound phases: `install.sh` + image import, the 1 TiB loopback format inside
ACTIVATING, and the management-DB copy. None of that changes between test runs.
Capture one green appliance once and make every later deploy a copy-on-write
clone of it, so a redeploy is minutes.

## Goals

- Redeploy `deploy-storage` → `verify-storage` green in well under 15 minutes.
- Keep a full-install path for a fresh cluster identity or a new VAST build.
- No change to the E2E suite: it still consumes `OSAC_STORAGE_*`.

## Non-goals

- A golden lifecycle/database (versions, pruning). One lab, one golden artifact.
- Running two VAST appliances at once. The lab has one data bridge, one fixed
  data address and one VIP range.

## Decisions

- **Golden point:** after `verify-storage` is green (cluster ONLINE, management
  DB ready, objects created, client log active). Capturing earlier would leave
  the expensive format and DB copy in every deploy.
- **Identity:** a clone keeps the captured cluster identity (GUID, SSH host
  keys, DB, lab objects) and boots with the captured libvirt domain UUID, the
  one the cluster was created under (recorded in `.meta`). Accepted for one
  sequential lab VM; opt-out is `destroy-storage` then
  `lab_vast_use_golden=false`, or deleting the golden file.
- **Capture:** a one-time lab operation, not part of the deploy path, done
  with `make capture-golden`. It re-checks green on the running appliance,
  shuts it down gracefully (never forced off), and writes the image and its
  `.meta` together. Capture happens before per-tenant VAST objects
  (`configure-vast-tenants`) are first created, and only after a cold boot of
  the same disk has been rehearsed green.
- **Mechanism:** flatten the green overlay once with `qemu-img convert` into a
  standalone golden qcow2 (uncompressed by default; `-c` only when the measured
  size requires it, since compressed backing makes every post-clone first read
  decompress); later deploys create an overlay backed by it. Chosen over chained
  or libvirt-snapshot approaches because it is independent of the base image and
  has no backing-chain depth.

## How it works

Artifacts under `/var/lib/libvirt/images/vast/`:

| File | Role |
|---|---|
| `vast_5_4.qcow2` | pristine base (checksum-pinned, never modified) |
| `vast_5_4-golden.qcow2` | captured green appliance (optional, lab-local) |
| `vast_5_4-golden.qcow2.meta` | required with the golden: `build=`, `uuid=`, plus capture facts |
| `vast_5_4-lab.qcow2` | per-deploy overlay; deleted by `destroy-storage` |
| `vast_5_4-lab.qcow2.prepared` | marker: overlay needs no preparation |

- `image.yml`: if `lab_vast_use_golden` and the golden exists, it requires the
  `.meta` (matching `build=`, a `uuid=`), does not read the base image, backs
  the new overlay with the golden and writes the prepared marker, so
  `prepare.yml` (IDE boot + dracut) is skipped. On every run it asserts that an
  existing overlay is backed by the selected image.
- `domain.yml`: a new domain is defined with the captured UUID.
- `install.yml`: the completeness probe waits for dockerd in the guest, then
  checks `vman.sh` **and** the `vast_vms` container, so `install.sh` is skipped.
  A clone that does not look installed fails instead of reinstalling.
- `cluster.yml`: starts `registry`, `vast_vms` and `mcvms` (containers do not
  autostart) and requires `vast_vms` running, repairs the management plane,
  finds the existing ONLINE cluster and waits for the DB to report ready. On a
  clone it never deletes a `FAILED` cluster or creates one; it fails instead.
- `objects.yml` is idempotent by name; the lab objects already exist.
- `clientlog.yml`: a new overlay starts with an empty client log.
- `destroy-storage` removes only the deploy overlay and marker; the golden
  stays.

## Refresh and opt-out

- `lab_vast_use_golden=false` forces the full install path (new identity) **after
  `destroy-storage`**; an existing overlay keeps its backing, so the role
  asserts the overlay's backing file and fails with that instruction rather than
  silently ignoring the flag.
- Capture a new golden after a green verify with the optional playbook; the
  playbook re-asserts green itself instead of trusting the previous run.
- A stale golden (new build, base image change) is replaced the same way. The
  captured `.meta` records the build, and the role refuses a golden whose build
  does not match `lab_vast_build`.

## Risks

| Risk | Mitigation |
|---|---|
| Two clones running simultaneously collide on `192.168.124.11`/VIP | one domain name and one data bridge; documented as sequential-only |
| A clone inherits test tenants/views from the captured state | capture after a clean verify; tests use unique names; the lab view admits the pool CIDR |
| Golden drifts from the base image checksum | golden is standalone; base is only needed for a fresh install |
| Golden drifts from `lab_vast_build` | `.meta` records the build; the role refuses a mismatch or a missing `.meta` |
| A clone comes back with its cluster `FAILED` or missing | the role refuses to delete or create on a clone; the operator decides |
| Captured per-tenant objects carry stale NAT allowlists | capture before `configure-vast-tenants` first runs; re-run it after every clone deploy |
| Capture leaves the VM stopped | the playbook says to run `destroy-storage` then `deploy-storage` |
| Disk growth (golden + overlay) | measured before capture (`qemu-img measure`); uncompressed flatten by default, `-c` only if the measured space requires it |
| The suite passes on evidence inherited from the golden | the client observation log is truncated when a deploy creates a new overlay, and the suite matches only lines after that baseline |

## Verification

- Rehearse a cold boot of the overlay itself: containers up, cluster ONLINE, DB
  ready, no create/format/copy. This is the go/no-go before any capture.
- Time `deploy-storage` + `verify-storage` on a clone; target < 15 min.
- `verify-storage` green (cluster ONLINE, DB ready, client log active).
- Prove the refusals on the lab: opt-out without a destroy fails before the
  domain is touched; a warm re-run does not reset the client log.
- Run the VM-path storage cases against the clone, with the suite reading only
  client-log lines written after its own mount.

## Open items (resolved during validation)

1. Clone boot time until SSH, containers and the API are back.
2. Whether the platform's internal NFS mount and clustered PG recover without
   intervention after a clone boot (expected: watchdog remounts and starts).
3. Whether the golden must be recaptured after any OSAC-side change (no: OSAC
   state lives outside the VM).
