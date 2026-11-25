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
  keys, DB, lab objects). Accepted for one sequential lab VM; documented, and
  opt-out via `lab_vast_use_golden=false` or deleting the golden file.
- **Capture:** a one-time lab operation, not part of the deploy path. The
  optional `make capture-golden` playbook only exists so the step is repeatable
  and documented; it stops the VM for a consistent capture.
- **Mechanism:** flatten the green overlay with `qemu-img convert -c` into a
  standalone golden qcow2; later deploys create an overlay backed by it.
  Chosen over chained or libvirt-snapshot approaches because it is independent
  of the base image and has no backing-chain depth.

## How it works

Artifacts under `/var/lib/libvirt/images/vast/`:

| File | Role |
|---|---|
| `vast_5_4.qcow2` | pristine base (checksum-pinned, never modified) |
| `vast_5_4-golden.qcow2` | captured green appliance (optional, lab-local) |
| `vast_5_4-lab.qcow2` | per-deploy overlay; deleted by `destroy-storage` |
| `vast_5_4-lab.qcow2.prepared` | marker: overlay needs no preparation |

- `image.yml`: if `lab_vast_use_golden` and the golden exists, the new overlay
  is backed by the golden and the prepared marker is written, so `prepare.yml`
  (IDE boot + dracut) is skipped.
- `install.yml`: its completeness check (`vman.sh` **and** the `vast_vms`
  container) passes on a golden clone, so `install.sh` is skipped.
- `cluster.yml`: starts `registry`, `vast_vms` and `mcvms` (containers do not
  autostart), repairs the management plane, finds the existing ONLINE cluster
  and waits for the DB to report ready. No create, no format, no DB copy.
- `objects.yml` is idempotent by name; the lab objects already exist.
- `destroy-storage` removes only the deploy overlay and marker; the golden
  stays.

## Refresh and opt-out

- `lab_vast_use_golden=false` forces the full install path (new identity).
- Capture a new golden after a green verify with the optional playbook.
- A stale golden (new build, base image change) is replaced the same way.

## Risks

| Risk | Mitigation |
|---|---|
| Two clones running simultaneously collide on `192.168.124.11`/VIP | one domain name and one data bridge; documented as sequential-only |
| A clone inherits test tenants/views from the captured state | capture after a clean verify; tests use unique names; the lab view admits the pool CIDR |
| Golden drifts from the base image checksum | golden is standalone; base is only needed for a fresh install |
| Capture leaves the VM stopped | the playbook says to run `destroy-storage` then `deploy-storage` |
| Disk growth (golden + overlay) | `qemu-img convert -c`; host has 2.4 TiB free |

## Verification

- Time `deploy-storage` + `verify-storage` on a clone; target < 15 min.
- `verify-storage` green (cluster ONLINE, DB ready, client log active).
- Run `test_storage_nat.py -k fr5_01` against the clone.

## Open items (resolved during validation)

1. Clone boot time until SSH, containers and the API are back.
2. Whether the platform's internal NFS mount and clustered PG recover without
   intervention after a clone boot (expected: watchdog remounts and starts).
3. Whether the golden must be recaptured after any OSAC-side change (no: OSAC
   state lives outside the VM).
