.PHONY: setup-infra deploy-infra deploy-osac \
       setup-vmaas setup-caas \
       destroy-osac destroy-infra \
       gather-infra gather-caas cleanup-dns

DEPLOY_MODE ?= snapshot
EXTRA_VARS ?=
ENV_CLUSTER := .env.infra

# --- Setup: installations and prerequisites ---

setup-infra:
	$(MAKE) -f Makefile setup EXTRA_VARS='$(EXTRA_VARS)'

# --- Deploy: lab + OCP ---

deploy-infra:
ifeq ($(DEPLOY_MODE),snapshot)
	$(MAKE) -f Makefile deploy-fast EXTRA_VARS='$(EXTRA_VARS)'
else
	$(MAKE) -f Makefile deploy-lab EXTRA_VARS='$(EXTRA_VARS)'
	$(MAKE) -f Makefile deploy-ocp EXTRA_VARS='$(EXTRA_VARS)'
endif

# --- Deploy: OSAC ---

deploy-osac:
ifeq ($(DEPLOY_MODE),snapshot)
	$(MAKE) -f Makefile snapshot-refresh EXTRA_VARS='$(EXTRA_VARS)'
else
	$(MAKE) -f Makefile deploy-osac EXTRA_VARS='$(EXTRA_VARS)'
endif
	@printf '%s\n' \
		'KUBECONFIG=/root/.kube/config' \
		'OSAC_NAMESPACE=$(or $(OSAC_NAMESPACE),osac-e2e-ci)' \
		'OSAC_VM_KUBECONFIG=/root/.kube/config' \
		'OSAC_PULL_SECRET_PATH=$(or $(OSAC_PULL_SECRET_PATH),/root/pull-secret)' \
		> $(ENV_CLUSTER)

# --- Suite setup ---

setup-vmaas:
	@true

setup-caas:
	$(MAKE) -f Makefile setup-caas EXTRA_VARS='$(EXTRA_VARS)'

# --- Destroy ---

destroy-osac:
	$(MAKE) -f Makefile destroy-osac EXTRA_VARS='$(EXTRA_VARS)'
	@rm -f $(ENV_CLUSTER)

destroy-infra:
	$(MAKE) -f Makefile destroy EXTRA_VARS='$(EXTRA_VARS)'
	@rm -f $(ENV_CLUSTER)

# --- Gather ---

gather-infra:
	$(MAKE) -f Makefile gather EXTRA_VARS='$(EXTRA_VARS)'
	$(MAKE) -f Makefile gather-lab EXTRA_VARS='$(EXTRA_VARS)'

gather-caas:
	$(MAKE) -f Makefile gather-caas EXTRA_VARS='$(EXTRA_VARS)'

cleanup-dns:
	$(MAKE) -f Makefile cleanup-dns EXTRA_VARS='$(EXTRA_VARS)'
