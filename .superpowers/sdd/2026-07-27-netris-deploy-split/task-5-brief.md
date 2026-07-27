### Task 5: Update root Makefile and inventory variables

**Files:**
- Modify: `Makefile` (root), `infra/netris/inventory/group_vars/all.yml`

**Interfaces:**
- Consumes: contract.mk targets from Task 4
- Produces: `deploy-ocp` and `destroy-ocp` in root contract, `osac_deploy_mode` variable with flavor derivation

- [ ] **Step 1: Add deploy-ocp and destroy-ocp to root Makefile**

In the root `Makefile`, add `deploy-ocp` and `destroy-ocp` to the `.PHONY` list and the `e2e` target:

Change the `.PHONY` line:
```makefile
.PHONY: e2e setup-infra deploy-infra deploy-ocp deploy-osac setup-suite run-tests \
        destroy-ocp destroy-osac destroy-infra gather-infra gather-suite redeploy-osac \
        _validate-backend _validate-suite-contract
```

Change the `e2e` target:
```makefile
e2e: _validate-backend setup-infra deploy-infra deploy-ocp deploy-osac setup-suite run-tests
```

Add `deploy-ocp` target (after `deploy-infra`):
```makefile
deploy-ocp: _validate-backend
	$(MAKE) -C $(INFRA_DIR) -f contract.mk deploy-ocp EXTRA_VARS='$(EXTRA_VARS)'
```

Add `destroy-ocp` target (after `destroy-osac`):
```makefile
destroy-ocp:
	$(MAKE) -C $(INFRA_DIR) -f contract.mk destroy-ocp EXTRA_VARS='$(EXTRA_VARS)'
```

- [ ] **Step 2: Update inventory variables**

In `infra/netris/inventory/group_vars/all.yml`, replace the snapshot flavor variables and add the deploy mode toggle. Find the snapshot config section and replace:

Remove the static `snapshot_flavor_image` and `snapshot_flavor_dir` lines. Replace with:

```yaml
# Deploy mode: "fresh" (OCP-only snapshot + Helm install) or
# "snapshot" (CaaS snapshot with baked OSAC + refresh)
osac_deploy_mode: "fresh"

# Snapshot flavor — derived from deploy mode, overrideable directly
snapshot_flavor_image: >-
  {{ (osac_deploy_mode == 'snapshot')
     | ternary('quay.io/rh-ee-ovishlit/cluster-flavors:caas',
               'quay.io/osac-project/cluster-flavors:sno-4.19-x86_64') }}
snapshot_flavor_dir: >-
  {{ (osac_deploy_mode == 'snapshot')
     | ternary('/var/cache/netris-lab/cluster-flavors/caas',
               '/var/cache/netris-lab/cluster-flavors/sno-4-19-x86_64') }}
```

Keep `snapshot_recert_image`, `snapshot_osac_namespace`, `snapshot_osac_values_file` unchanged.

Also remove `ocp_version` reference to assisted installer in the comment if present, and remove any `caas_ocp_version` variable (PR #217 already merged it into `ocp_version`).

- [ ] **Step 3: Verify root Make targets resolve**

```bash
cd /home/dmanor/dev/osac-project/osac-workspace/osac-test-infra
make -n deploy-ocp INFRA=netris SUITE=caas
make -n destroy-ocp INFRA=netris SUITE=caas
make -n e2e INFRA=netris SUITE=caas
```

Expected: `deploy-ocp` shows delegation to `infra/netris/contract.mk deploy-ocp`. The `e2e` target lists all 6 steps including `deploy-ocp`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -s -m "Add deploy-ocp to root contract, add osac_deploy_mode variable

Add deploy-ocp and destroy-ocp targets to root Makefile.
Update e2e pipeline: setup-infra -> deploy-infra -> deploy-ocp ->
deploy-osac -> setup-suite -> run-tests.
Add osac_deploy_mode variable (fresh/snapshot) with flavor derivation.

Assisted-by: Claude Code <noreply@anthropic.com>"
```

---

