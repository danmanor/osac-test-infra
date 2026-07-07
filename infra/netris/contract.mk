.PHONY: deploy-infra deploy-osac setup-vmaas setup-caas \
       destroy-osac destroy-infra gather

DEPLOY_MODE ?= snapshot
EXTRA_VARS ?=
ENV_CLUSTER := .env.cluster

deploy-infra:
ifeq ($(DEPLOY_MODE),snapshot)
	$(MAKE) -f Makefile setup EXTRA_VARS='$(EXTRA_VARS)'
	$(MAKE) -f Makefile deploy-lab EXTRA_VARS='$(EXTRA_VARS)'
	$(MAKE) -f Makefile restore-ocp-snapshot EXTRA_VARS='$(EXTRA_VARS)'
else
	$(MAKE) -f Makefile setup EXTRA_VARS='$(EXTRA_VARS)'
	$(MAKE) -f Makefile deploy-lab EXTRA_VARS='$(EXTRA_VARS)'
	$(MAKE) -f Makefile deploy-ocp EXTRA_VARS='$(EXTRA_VARS)'
endif

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

setup-vmaas:
	@true

setup-caas:
	$(MAKE) -f Makefile setup-caas EXTRA_VARS='$(EXTRA_VARS)'

destroy-osac:
	$(MAKE) -f Makefile destroy-osac EXTRA_VARS='$(EXTRA_VARS)'
	@rm -f $(ENV_CLUSTER)

destroy-infra:
	$(MAKE) -f Makefile destroy EXTRA_VARS='$(EXTRA_VARS)'
	@rm -f $(ENV_CLUSTER)

gather:
	$(MAKE) -f Makefile gather EXTRA_VARS='$(EXTRA_VARS)'
