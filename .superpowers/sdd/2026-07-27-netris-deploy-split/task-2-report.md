### Task 2 Report: Rename all roles from underscores to hyphens

**Status:** DONE

**Commits:**
- `8f3a462a193ee94e495140458ec854ccdb4e1f64` - Rename all roles from underscores to hyphens

**Work Completed:**

1. **Role Directory Renames** - Renamed 13 role directories from underscore to hyphen naming:
   - `lab_setup` → `setup-infra`
   - `lab_deploy` → `deploy-infra`
   - `netris_configure` → `netris-configure`
   - `ocp_dns` → `ocp-dns`
   - `osac_install` → `prep-osac`
   - `osac_refresh` → `prep-refresh-osac`
   - `osac_post_refresh` → `post-refresh-osac`
   - `caas_discovery` → `caas-discovery`
   - `caas_setup` → `caas-setup`
   - `caas_create` → `caas-create`
   - `destroy` → `destroy-infra`
   - `destroy_caas` → `destroy-caas`
   - `gather_lab` → `gather-infra`
   - `gather_caas` → `gather-caas`
   - `snapshot_pull` → `snapshot-pull`

2. **Role Deletions** - Removed 3 Assisted Installer roles:
   - `assisted_service`
   - `ocp_install`
   - `vm_resize`

3. **Internal Role Reference Updates** - Updated all references to old role names:
   - `roles/gather/tasks/main.yml`: Updated includes for `gather-infra` and `gather-caas`
   - `roles/setup-infra/tasks/main.yml`: Updated path reference to `deploy-infra` and include for `snapshot-pull`

4. **Playbook Updates** - Updated 14 playbooks to reference new hyphenated role names:
   - `playbooks/setup-ocp.yml`
   - `playbooks/setup-caas.yml`
   - `playbooks/prep-osac.yml`
   - `playbooks/post-snapshot-refresh.yml`
   - `playbooks/prep-snapshot-refresh.yml`
   - `playbooks/restore-ocp-snapshot.yml`
   - `playbooks/deploy-caas.yml`
   - `playbooks/site.yml`
   - `playbooks/gather-lab.yml`
   - `playbooks/gather.yml`
   - `playbooks/gather-caas.yml`
   - `playbooks/destroy-caas.yml`
   - `playbooks/deploy-lab.yml` (comment update)
   - `playbooks/setup.yml` (comment update)

**Test Summary:**
- Verified all role directories were successfully renamed using `git mv`
- Confirmed all Assisted Installer roles were deleted
- Verified no remaining references to old underscore role names via comprehensive grep
- Checked final directory structure matches hyphenated naming convention

**Final Role Structure:**
```
caas-create
caas-discovery
caas-setup
deploy-infra
destroy-caas
destroy-infra
gather
gather-caas
gather-infra
netris-configure
ocp-dns
post-refresh-osac
prep-osac
prep-refresh-osac
restore-snapshot
setup-infra
snapshot-pull
```

**Concerns:** None. All role renames and deletions completed successfully. All internal references and playbook references have been updated. The `gather` role (without underscore) was preserved as a meta-role that orchestrates `gather-infra` and `gather-caas`.
