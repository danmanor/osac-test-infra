# ─── Variables ──────────────────────────────────────────────────────

ifneq ($(origin SUITE),undefined)
$(error SUITE was replaced: use DEPLOY_SUITE and TEST_SUITE, see targets.md)
endif
ifneq ($(origin OSAC_DEPLOY_MODE),undefined)
$(error OSAC_DEPLOY_MODE was removed: every OSAC install is fresh)
endif
EXTRA_VARS ?=
ENV_INFRA := .env.infra

# DEPLOY_SUITE selects the profile and setup. The root TEST_SUITE selects the tests.
# DEPLOY_SUITE=caas (default) — setup-caas / deploy-caas.
# DEPLOY_SUITE=maas — setup-maas / deploy-maas.
DEPLOY_SUITE ?= caas

OSAC_NAMESPACE ?= osac-e2e-ci
KUBECONFIG ?= /root/.kube/config
OSAC_VM_KUBECONFIG ?= $(KUBECONFIG)
export KUBECONFIG
ifeq ($(origin OSAC_PROFILE),command line)
$(error OSAC_PROFILE is derived from DEPLOY_SUITE; choose the deployment scenario with DEPLOY_SUITE)
endif
OSAC_PROFILE = $(if $(filter vmaas,$(DEPLOY_SUITE)),vmaas-ci,$(if $(filter bmaas,$(DEPLOY_SUITE)),bmaas-ci,$(if $(filter full,$(DEPLOY_SUITE)),full-ci,caas-ci)))
OSAC_PULL_SECRET_PATH ?= /root/pull-secret
export OSAC_PULL_SECRET_PATH
KUBECONFIG_ABS = $(abspath $(KUBECONFIG))
OSAC_VM_KUBECONFIG_ABS = $(abspath $(OSAC_VM_KUBECONFIG))

# Lab VAST storage endpoint (OSAC-8073). Reported to the suite through the
# OSAC_STORAGE_* variables so the suite stays backend-agnostic.
LAB_VAST_SERVER_IP ?= 192.168.124.20
LAB_VAST_MGMT_IP ?= 192.168.16.60
LAB_VAST_EXPORT ?= /lab-storage
LAB_VAST_SSH_HOST ?= centos@$(LAB_VAST_MGMT_IP)
LAB_VAST_SSH_IDENTITY ?= /root/.ssh/lab-vast
LAB_VAST_LOG_PATH ?= /var/log/osac-vast-clients.log
