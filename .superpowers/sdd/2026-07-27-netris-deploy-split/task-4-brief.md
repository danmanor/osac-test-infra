### Task 4: Rewrite Makefile and contract.mk

**Files:**
- Modify: `infra/netris/Makefile`, `infra/netris/contract.mk`

**Interfaces:**
- Consumes: renamed playbooks from Task 3
- Produces: Make targets aligned with the contract, `OSAC_DEPLOY_MODE` toggle

- [ ] **Step 1: Rewrite `infra/netris/Makefile`**

Replace the entire file with:

```makefile
.PHONY: setup-infra deploy-infra deploy-ocp deploy-osac \
       install-osac prep-osac run-osac-setup post-osac \
       refresh-osac prep-refresh-osac run-refresh-osac post-refresh-osac \
       restore-ocp \
       setup-caas deploy-caas \
       destroy-osac destroy-ocp destroy-infra destroy-caas \
       connectivity vendor-update lint \
       gather-infra gather-caas cleanup-dns

OSAC_DEPLOY_MODE ?= fresh
EXTRA_VARS ?=
ANSIBLE_EXTRA = $(if $(EXTRA_VARS),-e '$(EXTRA_VARS)')
ENV_INFRA := .env.infra

# Namespace/values defaults — match inventory/group_vars/all.yml
OSAC_NAMESPACE ?= osac-e2e-ci
OSAC_VALUES_FILE ?= values/caas-ci/values.yaml
OSAC_PULL_SECRET_PATH ?= /root/pull-secret

# --- Pipeline targets (contract-aligned) ---

setup-infra:
	ansible-playbook playbooks/setup-infra.yml $(ANSIBLE_EXTRA)

deploy-infra:
	ansible-playbook playbooks/deploy-infra.yml $(ANSIBLE_EXTRA)

deploy-ocp:
	ansible-playbook playbooks/deploy-ocp.yml $(ANSIBLE_EXTRA)

deploy-osac:
ifeq ($(OSAC_DEPLOY_MODE),snapshot)
	$(MAKE) refresh-osac
else
	$(MAKE) install-osac
endif
	@printf '%s\n' \
		'KUBECONFIG=/root/.kube/config' \
		'OSAC_NAMESPACE=$(OSAC_NAMESPACE)' \
		'OSAC_VM_KUBECONFIG=/root/.kube/config' \
		'OSAC_PULL_SECRET_PATH=$(OSAC_PULL_SECRET_PATH)' \
		> $(ENV_INFRA)

# Fresh install sub-targets
install-osac: prep-osac run-osac-setup post-osac

prep-osac:
	ansible-playbook playbooks/prep-osac.yml $(ANSIBLE_EXTRA)

run-osac-setup:
	@echo "=== Installing OSAC via Helm (make install) ==="
	cd /opt/osac-installer && make install \
		INSTALLER_NAMESPACE=$(OSAC_NAMESPACE) \
		VALUES_FILE=$(OSAC_VALUES_FILE)

post-osac:
	ansible-playbook playbooks/post-osac.yml $(ANSIBLE_EXTRA)

# Snapshot-refresh sub-targets
refresh-osac: prep-refresh-osac run-refresh-osac post-refresh-osac

prep-refresh-osac:
	ansible-playbook playbooks/prep-refresh-osac.yml $(ANSIBLE_EXTRA)

run-refresh-osac:
	@echo "=== Running OSAC refresh ==="
	cd /opt/osac-installer && \
		KUBECONFIG=/root/.kube/config \
		VALUES_FILE=$(OSAC_VALUES_FILE) \
		INSTALLER_NAMESPACE=$(OSAC_NAMESPACE) \
		python3 -u scripts/refresh-after-snapshot.py

post-refresh-osac:
	ansible-playbook playbooks/post-refresh-osac.yml $(ANSIBLE_EXTRA)

# CaaS targets
setup-caas:
	ansible-playbook playbooks/setup-caas.yml $(ANSIBLE_EXTRA)

deploy-caas:
	ansible-playbook playbooks/deploy-caas.yml $(ANSIBLE_EXTRA)

# --- Destroy ---

destroy-osac:
	@echo "=== Tearing down OSAC ==="
	cd /opt/osac-installer && make uninstall \
		INSTALLER_NAMESPACE=$(OSAC_NAMESPACE) \
		VALUES_FILE=$(OSAC_VALUES_FILE) 2>/dev/null || true
	rm -rf /opt/osac-installer /opt/osac-installer-full
	@rm -f $(ENV_INFRA)

destroy-ocp:
	ansible-playbook playbooks/destroy-ocp.yml $(ANSIBLE_EXTRA)

destroy-infra:
	ansible-playbook playbooks/destroy-infra.yml $(ANSIBLE_EXTRA)
	@rm -f $(ENV_INFRA)

destroy-caas:
	ansible-playbook playbooks/destroy-caas.yml $(ANSIBLE_EXTRA)

# --- Utilities ---

connectivity:
	ansible-playbook playbooks/connectivity.yml $(ANSIBLE_EXTRA)

vendor-update:
	rm -rf vendor/ansible_collections
	ansible-galaxy collection install -r requirements.yml -p vendor --force
	ansible-galaxy collection install ansible.utils -p vendor --force

lint:
	ansible-lint

gather-infra:
	ansible-playbook playbooks/gather-infra.yml $(ANSIBLE_EXTRA)

gather-caas:
	ansible-playbook playbooks/gather-caas.yml $(ANSIBLE_EXTRA)

cleanup-dns:
	ansible-playbook playbooks/cleanup-dns.yml $(ANSIBLE_EXTRA)
```

- [ ] **Step 2: Rewrite `infra/netris/contract.mk`**

Replace the entire file with:

```makefile
.PHONY: setup-infra deploy-infra deploy-ocp deploy-osac \
       setup-caas \
       destroy-osac destroy-ocp destroy-infra destroy-caas \
       gather-infra gather-caas cleanup-dns

EXTRA_VARS ?=

setup-infra:
	$(MAKE) -f Makefile setup-infra EXTRA_VARS='$(EXTRA_VARS)'

deploy-infra:
	$(MAKE) -f Makefile deploy-infra EXTRA_VARS='$(EXTRA_VARS)'

deploy-ocp:
	$(MAKE) -f Makefile deploy-ocp EXTRA_VARS='$(EXTRA_VARS)'

deploy-osac:
	$(MAKE) -f Makefile deploy-osac EXTRA_VARS='$(EXTRA_VARS)'

setup-caas:
	$(MAKE) -f Makefile setup-caas EXTRA_VARS='$(EXTRA_VARS)'

destroy-osac:
	$(MAKE) -f Makefile destroy-osac EXTRA_VARS='$(EXTRA_VARS)'

destroy-ocp:
	$(MAKE) -f Makefile destroy-ocp EXTRA_VARS='$(EXTRA_VARS)'

destroy-infra:
	$(MAKE) -f Makefile destroy-infra EXTRA_VARS='$(EXTRA_VARS)'

destroy-caas:
	$(MAKE) -f Makefile destroy-caas EXTRA_VARS='$(EXTRA_VARS)'

gather-infra:
	$(MAKE) -f Makefile gather-infra EXTRA_VARS='$(EXTRA_VARS)'

gather-caas:
	$(MAKE) -f Makefile gather-caas EXTRA_VARS='$(EXTRA_VARS)'

cleanup-dns:
	$(MAKE) -f Makefile cleanup-dns EXTRA_VARS='$(EXTRA_VARS)'
```

- [ ] **Step 3: Verify Make targets resolve**

```bash
cd /home/dmanor/dev/osac-project/osac-workspace/osac-test-infra/infra/netris
make -n setup-infra
make -n deploy-infra
make -n deploy-ocp
make -n deploy-osac
make -n deploy-osac OSAC_DEPLOY_MODE=snapshot
make -n setup-caas
make -n destroy-osac
make -n destroy-ocp
make -n destroy-infra
```

Expected: each prints the ansible-playbook or shell command it would run, no errors.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -s -m "Rewrite Makefile and contract.mk for deploy split

Align Make targets with contract names. Add deploy-ocp target.
Add OSAC_DEPLOY_MODE toggle (fresh/snapshot) for deploy-osac.
Remove Assisted Installer targets (deploy, deploy-ocp, deploy-fast),
snapshot-refresh sub-targets, and workaround targets.

Assisted-by: Claude Code <noreply@anthropic.com>"
```

---

