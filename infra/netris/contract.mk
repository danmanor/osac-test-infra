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
