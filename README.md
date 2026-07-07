# OSAC Test Infrastructure

End-to-end test suite and pluggable infrastructure provisioning for OSAC. Tests the full stack: fulfillment CLI/API, operator, AAP provisioning, and KubeVirt VM lifecycle.

## Directory Structure

```
tests/                          # pytest E2E test suites
├── conftest.py                 # Session fixtures: cli, grpc, k8s, keycloak
├── core/                       # Shared clients and helpers
├── vmaas/                      # VMaaS tests (compute instances, networking, public IPs)
├── caas/                       # CaaS tests (cluster lifecycle, credentials, templates)
├── catalog/                    # Catalog item tests
└── storage/                    # Tenant storage tests
infra/                          # Pluggable infrastructure backends
├── contract.md                 # Backend contract documentation
└── netris/                     # Netris backend (Ansible-based)
    ├── contract.mk             # Contract wrapper
    ├── capabilities            # Supported suites
    ├── Makefile                # Original netris-test-infra targets
    ├── roles/                  # Ansible roles
    ├── playbooks/              # Ansible playbooks
    ├── inventory/              # Ansible inventory
    └── netris-lab/             # Netris lab simulation
```

## Quick Start

### Prerequisites

- Python 3.11+
- `osac` binary (matching the deployed fulfillment-service version)
- `grpcurl`
- `oc` / `kubectl` with cluster-admin access
- A running OSAC deployment

### Install

```bash
uv sync
```

### Run Tests

```bash
# Run against an existing cluster
OSAC_NAMESPACE=osac-devel OSAC_VM_KUBECONFIG=~/.kube/config make test-vmaas
OSAC_NAMESPACE=osac-devel make test-caas

# Filter by test name
TEST=test_cluster_order_lifecycle make test-caas
```

### Full E2E with Infrastructure

```bash
# Deploy infra + OSAC + run CaaS tests (Netris backend)
make e2e INFRA=netris SUITE=caas

# Each phase independently
make setup-infra INFRA=netris
make deploy-infra INFRA=netris
make deploy-osac INFRA=netris
make setup-suite INFRA=netris SUITE=caas
make run-tests INFRA=netris SUITE=caas

# Iterate on OSAC without reprovisioning the lab
make redeploy-osac INFRA=netris

# Tear down
make destroy-osac INFRA=netris
make destroy-infra INFRA=netris
```

### Makefile Targets

```
# Tests
make test                               # All tests
make test-vmaas                         # VMaaS tests
make test-caas                          # CaaS tests
make test-storage                       # Storage tests
make lint                               # Ruff check + format check
make format                             # Ruff format

# Infrastructure orchestration
make e2e INFRA=<backend> SUITE=<suite>  # Full pipeline
make setup-infra INFRA=<backend>        # Install prerequisites
make deploy-infra INFRA=<backend>       # Provision lab + cluster
make deploy-osac INFRA=<backend>        # Deploy OSAC
make setup-suite INFRA=<backend> SUITE=<suite>  # Suite-specific setup
make run-tests INFRA=<backend> SUITE=<suite>    # Run tests
make destroy-osac INFRA=<backend>       # Tear down OSAC
make destroy-infra INFRA=<backend>      # Tear down everything
make gather-infra INFRA=<backend>       # Collect diagnostics
make redeploy-osac INFRA=<backend>      # Destroy + redeploy OSAC
```

## Configuration

All configuration via environment variables.

| Variable | Default | Description |
|----------|---------|-------------|
| `OSAC_NAMESPACE` | `osac-devel` | Namespace where OSAC is deployed |
| `KUBECONFIG` | `~/.kube/config` | Kubeconfig for the hub cluster |
| `OSAC_VM_KUBECONFIG` | **(required for vmaas)** | Kubeconfig for the VM cluster |
| `OSAC_PULL_SECRET_PATH` | **(required for caas)** | Path to OCP pull secret |
| `OSAC_FULFILLMENT_ADDRESS` | auto-derived | Fulfillment API address |
| `OSAC_VM_TEMPLATE` | `osac.templates.ocp_virt_vm` | VM template |
| `OSAC_CLUSTER_TEMPLATE` | `osac.templates.ocp_ci_small` | Cluster template |
| `OSAC_CLI_PATH` | `osac` | Path to the CLI binary |
| `TEST` | (none) | pytest `-k` filter |

## Infrastructure Backends

Backends live in `infra/<name>/` and implement a standard contract (see `infra/contract.md`). Each backend declares which test suites it supports via a `capabilities` file.

### Netris

Ansible-based backend that deploys a simulated Netris Spectrum-X GPU cluster with OCP and OSAC.

- **Supports:** vmaas, caas
- **Deploy modes:** `snapshot` (default, ~25 min) or `full` (~2h)
- **Override:** `make deploy-infra INFRA=netris DEPLOY_MODE=full`

### Adding a New Backend

Create `infra/<name>/` with:
- `contract.mk` — implement the contract targets
- `capabilities` — declare `SUPPORTED_SUITES`

See `infra/contract.md` for the full contract specification.
