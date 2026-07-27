### Task 2: Rename all roles from underscores to hyphens

**Files:**
- Rename: every `infra/netris/roles/<underscore_name>/` directory to `<hyphen-name>/`
- Delete: `infra/netris/roles/assisted_service/`, `infra/netris/roles/ocp_install/`, `infra/netris/roles/vm_resize/`

**Interfaces:**
- Produces: all roles under hyphenated directory names — every subsequent task references these names

Role directory renames. Internal role content (tasks/main.yml, templates, etc.) does NOT change — Ansible resolves roles by directory name, so renaming the directory is sufficient. Any `include_role` or `roles:` references in playbooks are updated in Task 3.

- [ ] **Step 1: Rename role directories**

```bash
cd /home/dmanor/dev/osac-project/osac-workspace/osac-test-infra/infra/netris

# Rename underscore roles to hyphens
mv roles/lab_setup roles/setup-infra
mv roles/lab_deploy roles/deploy-infra
mv roles/netris_configure roles/netris-configure
mv roles/ocp_dns roles/ocp-dns
mv roles/osac_install roles/prep-osac
mv roles/osac_refresh roles/prep-refresh-osac
mv roles/osac_post_refresh roles/post-refresh-osac
mv roles/caas_discovery roles/caas-discovery
mv roles/caas_setup roles/caas-setup
mv roles/caas_create roles/caas-create
mv roles/destroy roles/destroy-infra
mv roles/destroy_caas roles/destroy-caas
mv roles/gather_lab roles/gather-infra
mv roles/gather_caas roles/gather-caas
mv roles/snapshot_pull roles/snapshot-pull
```

- [ ] **Step 2: Delete removed roles (Assisted Installer path)**

```bash
rm -rf roles/assisted_service roles/ocp_install roles/vm_resize
```

- [ ] **Step 3: Update internal role references**

The `setup-infra` role (was `lab_setup`) includes `snapshot_pull` as a sub-role via `include_role`. Update:

```bash
grep -rn 'snapshot_pull\|lab_setup\|lab_deploy\|netris_configure\|ocp_dns\|osac_install\|osac_refresh\|osac_post_refresh\|caas_discovery\|caas_setup\|caas_create\|gather_lab\|gather_caas\|destroy_caas' roles/
```

For each hit, replace the underscore name with the hyphenated name. Key known references:
- `roles/setup-infra/tasks/main.yml`: `include_role: name=snapshot_pull` → `name=snapshot-pull`
- `roles/deploy-infra/tasks/main.yml`: any references to `lab_setup` → `setup-infra`
- `roles/caas-discovery/tasks/main.yml`: if it includes `ocp_dns` → `ocp-dns`

- [ ] **Step 4: Verify role directory structure**

```bash
ls roles/ | sort
```

Expected output:
```
caas-create
caas-discovery
caas-setup
connectivity
deploy-infra
destroy-caas
destroy-infra
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

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -s -m "Rename all roles from underscores to hyphens

Rename role directories to use consistent hyphen-case naming.
Remove assisted_service, ocp_install, vm_resize roles (Assisted
Installer path removed).

Assisted-by: Claude Code <noreply@anthropic.com>"
```

---

