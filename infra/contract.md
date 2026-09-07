# Infrastructure Backend Contract

Each backend lives in `infra/<name>/` and must provide:

## Required Files

- `Makefile` — implements the contract targets below
- `capabilities` — shell-sourceable file declaring `SUPPORTED_SUITES`

## Contract Targets

| Target | Purpose |
|---|---|
| `setup-infra` | Install prerequisites and dependencies |
| `deploy-infra` | Provision the lab infrastructure |
| `deploy-ocp` | Deploy an OpenShift cluster |
| `deploy-osac` | Deploy OSAC on the cluster, write `.env.infra` |
| `setup-<suite>` | Suite-specific infra prep (can be no-op) |
| `destroy-ocp` | Tear down the OpenShift cluster |
| `destroy-osac` | Tear down OSAC only |
| `destroy-infra` | Tear down everything |
| `gather-infra` | Collect infrastructure diagnostics |
| `gather-<suite>` | Collect suite-specific diagnostics |

## .env.infra

After `deploy-osac`, write `.env.infra` in the backend directory:

```
KUBECONFIG=<path>
OSAC_NAMESPACE=<namespace>
OSAC_VM_KUBECONFIG=<path>          # if supporting vmaas
OSAC_PULL_SECRET_PATH=<path>       # if supporting caas
```

The top-level Makefile sources this file before running tests.

## Variables

Backends receive `EXTRA_VARS` and `OSAC_DEPLOY_MODE` from the top-level Makefile.
