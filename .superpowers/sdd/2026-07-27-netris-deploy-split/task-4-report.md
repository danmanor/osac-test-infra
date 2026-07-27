# Task 4 Report: Rewrite Makefile and contract.mk

## Status
DONE

## Commits
- 3a79492 - Rewrite Makefile and contract.mk for deploy split

## Changes Summary

### Makefile
- **New contract-aligned targets**: `setup-infra`, `deploy-infra`, `deploy-ocp`, `deploy-osac`
- **OSAC_DEPLOY_MODE toggle**: `deploy-osac` now branches on `OSAC_DEPLOY_MODE` (default: `fresh`)
  - Fresh mode: calls `install-osac` (prep-osac → run-osac-setup → post-osac)
  - Snapshot mode: calls `refresh-osac` (prep-refresh-osac → run-refresh-osac → post-refresh-osac)
- **Default namespace/values**: `OSAC_NAMESPACE=osac-e2e-ci`, `OSAC_VALUES_FILE=values/caas-ci/values.yaml`
- **Removed legacy targets**: `deploy`, `deploy-fast`, `deploy-lab`, `deploy-ocp-snapshot`, `restore-ocp-snapshot`, `snapshot-refresh`, all workaround helpers
- **Destroy targets**: Updated to match contract (`destroy-osac`, `destroy-ocp`, `destroy-infra`, `destroy-caas`)
- **CaaS targets**: Preserved (`setup-caas`, `deploy-caas`)
- **Utilities**: Preserved (`connectivity`, `vendor-update`, `lint`, `gather-infra`, `gather-caas`, `cleanup-dns`)

### contract.mk
- **Thin passthrough**: Each contract target delegates to the same-named Makefile target
- **Removed snapshot-specific logic**: No longer hardcodes snapshot path — `deploy-osac` delegates to Makefile which uses `OSAC_DEPLOY_MODE`
- **Added `deploy-ocp`**: New contract target for OCP deployment (was missing in old contract)
- **Added `destroy-caas`**: New contract target for CaaS teardown (was missing)

## Test Summary

Verified all contract targets resolve correctly with `make -n`:
- `setup-infra` → `ansible-playbook playbooks/setup-infra.yml`
- `deploy-infra` → `ansible-playbook playbooks/deploy-infra.yml`
- `deploy-ocp` → `ansible-playbook playbooks/deploy-ocp.yml`
- `deploy-osac` (fresh) → `install-osac` subtargets + `.env.infra` generation
- `deploy-osac OSAC_DEPLOY_MODE=snapshot` → `refresh-osac` subtargets + `.env.infra` generation
- `setup-caas` → `ansible-playbook playbooks/setup-caas.yml`
- `destroy-osac` → OSAC uninstall + cleanup
- `destroy-ocp` → `ansible-playbook playbooks/destroy-ocp.yml`
- `destroy-infra` → `ansible-playbook playbooks/destroy-infra.yml` + `.env.infra` cleanup

All targets correctly use the renamed playbooks from Task 3.

## Concerns

None. Implementation matches the task brief exactly:
- Makefile provides all required contract targets
- contract.mk is a thin passthrough as specified
- OSAC_DEPLOY_MODE toggle works as expected
- Default values match CI configuration (osac-e2e-ci namespace, caas-ci values)
- .env.infra generation works for both fresh and snapshot modes
