# Task 3 Report: Rename and Update Playbooks

## Status
**DONE**

## Commits
- `e927c33` - Rename playbooks to match contract targets

## Changes Summary

### Created Playbooks (8 new)
- `playbooks/setup-infra.yml` (was `setup.yml`) — preserved `module_defaults` for get_url CA workaround
- `playbooks/deploy-infra.yml` (was `deploy-lab.yml`) — preserved comment referencing CA bug fix location
- `playbooks/deploy-ocp.yml` (was `restore-ocp-snapshot.yml`) — netris-configure + ocp-dns + restore-snapshot
- `playbooks/prep-refresh-osac.yml` (was `prep-snapshot-refresh.yml`) — single role include
- `playbooks/post-refresh-osac.yml` (was `post-snapshot-refresh.yml`) — single role include
- `playbooks/destroy-infra.yml` (was `destroy.yml`) — single role include
- `playbooks/gather-infra.yml` (was `gather-lab.yml`) — single role include
- `playbooks/connectivity.yml` (was `connectivity-lab.yml`) — preserved netris-lab vars loading

### Updated Playbooks (1 modified)
- `playbooks/prep-osac.yml` — updated description from "Install OSAC on OCP SNO" to "Prepare OSAC installation"

### Already-Correct Playbooks (4 unchanged)
- `playbooks/setup-caas.yml` — already references `caas-discovery` and `caas-setup`
- `playbooks/deploy-caas.yml` — already references `caas-create`
- `playbooks/destroy-caas.yml` — already references `destroy-caas`
- `playbooks/gather-caas.yml` — already references `gather-caas`

### Deleted Playbooks (12 removed)
- `setup.yml`, `deploy-lab.yml`, `restore-ocp-snapshot.yml`, `prep-snapshot-refresh.yml`, `post-snapshot-refresh.yml`
- `destroy.yml`, `gather-lab.yml`, `gather.yml`, `connectivity-lab.yml`
- `setup-ocp.yml`, `install-ocp.yml`, `site.yml` (Assisted Installer path, no longer used)

### Additional Fixes
- Updated stale comments in `roles/prep-refresh-osac/tasks/main.yml` (lines 75 and 84):
  - Changed `roles/lab_setup` references to `roles/setup-infra`

## Test Summary
All playbooks pass `ansible-playbook --syntax-check`:
- 16 playbooks verified (including cleanup-dns.yml, destroy-ocp.yml, post-osac.yml which weren't part of this task)
- No syntax errors
- All role references use hyphenated names matching Task 2 role renames

## Final Playbook Structure
```
playbooks/
├── cleanup-dns.yml         (unchanged)
├── connectivity.yml         (renamed, vars loading preserved)
├── deploy-caas.yml          (already correct)
├── deploy-infra.yml         (renamed, comment preserved)
├── deploy-ocp.yml           (renamed)
├── destroy-caas.yml         (already correct)
├── destroy-infra.yml        (new)
├── destroy-ocp.yml          (unchanged)
├── gather-caas.yml          (already correct)
├── gather-infra.yml         (new)
├── post-osac.yml            (unchanged)
├── post-refresh-osac.yml    (renamed)
├── prep-osac.yml            (description updated)
├── prep-refresh-osac.yml    (renamed)
├── setup-caas.yml           (already correct)
└── setup-infra.yml          (renamed, module_defaults preserved)
```

## Concerns
None. All special playbook structures were preserved:
- `setup-infra.yml` retains the `module_defaults` block for `ansible.builtin.get_url` checksum workaround
- `deploy-infra.yml` retains the OpenSSL CA bug comment referencing the role-level fix
- `connectivity.yml` retains the netris-lab vars loading task
- All role references use the new hyphenated names from Task 2
- Stale `lab_setup` references in prep-refresh-osac were updated to `setup-infra`
