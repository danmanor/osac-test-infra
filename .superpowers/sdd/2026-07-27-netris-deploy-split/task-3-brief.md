### Task 3: Rename and update all playbooks

**Files:**
- Create: `playbooks/setup-infra.yml`, `playbooks/deploy-infra.yml`, `playbooks/deploy-ocp.yml`, `playbooks/prep-refresh-osac.yml`, `playbooks/post-refresh-osac.yml`, `playbooks/destroy-infra.yml`, `playbooks/gather-infra.yml`, `playbooks/connectivity.yml`
- Modify: `playbooks/prep-osac.yml`, `playbooks/setup-caas.yml`, `playbooks/deploy-caas.yml`, `playbooks/destroy-caas.yml`, `playbooks/gather-caas.yml`
- Delete: `playbooks/setup.yml`, `playbooks/deploy-lab.yml`, `playbooks/restore-ocp-snapshot.yml`, `playbooks/prep-snapshot-refresh.yml`, `playbooks/post-snapshot-refresh.yml`, `playbooks/destroy.yml`, `playbooks/gather-lab.yml`, `playbooks/gather.yml`, `playbooks/connectivity-lab.yml`, `playbooks/setup-ocp.yml`, `playbooks/install-ocp.yml`, `playbooks/site.yml`

**Interfaces:**
- Consumes: hyphenated role names from Task 2
- Produces: playbooks named to match Make targets, referencing correct role names

- [ ] **Step 1: Create renamed playbooks with updated role references**

`playbooks/setup-infra.yml` (was `setup.yml`):
```yaml
---
- name: Setup infrastructure prerequisites
  hosts: all
  gather_facts: false
  roles:
    - setup-infra
```

`playbooks/deploy-infra.yml` (was `deploy-lab.yml`):
Copy `deploy-lab.yml` content but replace any role references from underscore to hyphen names. The deploy-lab.yml has a block with `module_defaults` for `ansible.builtin.uri` with `validate_certs: false` around the `deploy-infra` role include. Preserve that structure:

```bash
cp playbooks/deploy-lab.yml playbooks/deploy-infra.yml
sed -i 's/lab_deploy/deploy-infra/g' playbooks/deploy-infra.yml
sed -i 's/Deploy netris lab/Deploy infrastructure/g' playbooks/deploy-infra.yml
```

`playbooks/deploy-ocp.yml` (was `restore-ocp-snapshot.yml`):
```yaml
---
- name: Deploy OCP from snapshot
  hosts: all
  gather_facts: false
  roles:
    - netris-configure
    - ocp-dns
    - restore-snapshot
```

`playbooks/prep-refresh-osac.yml` (was `prep-snapshot-refresh.yml`):
```yaml
---
- name: Prepare OSAC refresh after snapshot restore
  hosts: all
  gather_facts: false
  roles:
    - prep-refresh-osac
```

`playbooks/post-refresh-osac.yml` (was `post-snapshot-refresh.yml`):
```yaml
---
- name: Post-refresh OSAC configuration (Netris, SSH keys, AAP token)
  hosts: all
  gather_facts: false
  roles:
    - post-refresh-osac
```

`playbooks/destroy-infra.yml` (was `destroy.yml`):
```yaml
---
- name: Destroy infrastructure
  hosts: all
  gather_facts: false
  roles:
    - destroy-infra
```

`playbooks/gather-infra.yml` (was `gather-lab.yml`):
```yaml
---
- name: Gather infrastructure diagnostics
  hosts: all
  gather_facts: false
  roles:
    - gather-infra
```

`playbooks/connectivity.yml` (was `connectivity-lab.yml`):
Copy `connectivity-lab.yml` and update role references from underscore to hyphen.

```bash
cp playbooks/connectivity-lab.yml playbooks/connectivity.yml
sed -i 's/Deploy netris lab connectivity/Deploy connectivity/g' playbooks/connectivity.yml
```

- [ ] **Step 2: Update existing playbooks with new role names**

`playbooks/prep-osac.yml` — update role reference:
```yaml
---
- name: Prepare OSAC installation
  hosts: all
  gather_facts: false
  roles:
    - prep-osac
```

`playbooks/setup-caas.yml` — update role references:
```yaml
---
- name: Setup CaaS
  hosts: all
  gather_facts: false
  roles:
    - caas-discovery
    - caas-setup
```

`playbooks/deploy-caas.yml` — update role reference:
```yaml
---
- name: Deploy CaaS cluster
  hosts: all
  gather_facts: false
  roles:
    - caas-create
```

`playbooks/destroy-caas.yml` — update role reference:
```yaml
---
- name: Destroy CaaS
  hosts: all
  gather_facts: false
  roles:
    - destroy-caas
```

`playbooks/gather-caas.yml` — update role reference:
```yaml
---
- name: Gather CaaS diagnostics
  hosts: all
  gather_facts: false
  roles:
    - gather-caas
```

- [ ] **Step 3: Delete old playbooks**

```bash
cd /home/dmanor/dev/osac-project/osac-workspace/osac-test-infra/infra/netris
rm -f playbooks/setup.yml \
      playbooks/deploy-lab.yml \
      playbooks/restore-ocp-snapshot.yml \
      playbooks/prep-snapshot-refresh.yml \
      playbooks/post-snapshot-refresh.yml \
      playbooks/destroy.yml \
      playbooks/gather-lab.yml \
      playbooks/gather.yml \
      playbooks/connectivity-lab.yml \
      playbooks/setup-ocp.yml \
      playbooks/install-ocp.yml \
      playbooks/site.yml
```

- [ ] **Step 4: Verify all playbooks pass syntax check**

```bash
for pb in playbooks/*.yml; do
  echo "=== $pb ==="
  ansible-playbook --syntax-check "$pb" || echo "FAILED: $pb"
done
```

Expected: all playbooks pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -s -m "Rename playbooks to match contract targets

Create hyphenated playbooks aligned with Make targets. Delete old
underscore-named and Assisted-Installer-path playbooks (setup-ocp.yml,
install-ocp.yml, site.yml).

Assisted-by: Claude Code <noreply@anthropic.com>"
```

---

