# OSAC Test Infrastructure

> [!IMPORTANT]
> **The e2e test suite has moved (OSAC-3593).** Test suites now live in the
> [osac mono-repo](https://github.com/osac-project/osac). **Do not add, modify,
> or delete tests in this repository** — make those changes in the mono-repo
> instead. The `tests/` directory here is retained only for the infrastructure
> backend contract and a placeholder; new tests added here will not be
> maintained.

Unified repository for OSAC end-to-end infrastructure and test orchestration. Pluggable backends provision clusters; active pytest suites run from the OSAC mono-repo.

**AI coding agents**: see [AGENTS.md](AGENTS.md) for repository constraints and infrastructure workflows. E2E test guidance is maintained in the [OSAC mono-repo](https://github.com/osac-project/osac/blob/main/tests/e2e/AGENTS.md).

## Architecture

The repo has two layers:

- **`infra/`** — infrastructure backends that provision a cluster and deploy OSAC. Each backend lives in its own directory and can use any technology (Ansible, shell, Go, etc.).
- **OSAC mono-repo** — the active pytest E2E suites live in the [osac mono-repo](https://github.com/osac-project/osac), under `tests/e2e/`. They are infrastructure-agnostic and consume environment variables rather than knowing which backend provisioned the cluster. This repository's `tests/` directory is legacy scaffolding; do not add or change E2E tests here.

A **contract** connects the layers. Each backend implements standard Makefile targets (`setup-infra`, `deploy-infra`, `deploy-osac`, etc.) and writes `.env.infra` with the configuration its suites need. Optional shell-sourceable suite contracts live at `infra/<backend>/contracts/<suite>` and list required environment variables. The top-level Makefile orchestrates the full flow.

```
infra/<backend>/                    osac/tests/e2e/<suite>/
┌──────────────────────┐            ┌──────────────────────┐
│ setup-infra          │            │                      │
│ deploy-infra         │            │ uv run pytest        │
│ deploy-osac ──────────── .env.infra ──▶                │
│ setup-<suite>        │            │                      │
│ destroy-osac         │            │                      │
│ destroy-infra        │            │                      │
│ gather-infra         │
│ gather-<suite>       │            │                      │
└──────────────────────┘            └──────────────────────┘
```

### Infrastructure Backends

| Backend | Technology | Description | Deploy Time |
|---------|-----------|-------------|-------------|
| **netris** | Ansible | Simulated Netris Spectrum-X GPU cluster with OCP and OSAC on KVM/libvirt | ~25 min (snapshot) / ~2h (full) |

### Netris Suite Identifiers

`DEPLOY_SUITE` selects what is deployed; `TEST_SUITE` selects the OSAC tests and defaults to the same name. The Netris backend supports the `DEPLOY_SUITE` values in `infra/netris/capabilities` (`SUPPORTED_DEPLOY_SUITES`). Test code and fixtures live in the OSAC mono-repo, and tests are selected by directory, not by markers. The full mapping and the commands are in [`infra/netris/targets.md`](infra/netris/targets.md).

| DEPLOY_SUITE | Profile | Default TEST_SUITE | Description |
|---|---|---|---|
| **caas** (default) | `caas-ci` | `caas` | BMaaS-backed cluster setup |
| **maas** | `caas-ci` | `maas` | BMaaS-backed MaaS cluster setup |
| **bmaas** | `bmaas-ci` | `bmaas` | BareMetalInstance setup and BMaaS networking E2E (`tests/e2e/networking/bmaas/`) |
| **vmaas** | `cudn-evpn-netris-test` | `vmaas` | VMaaS networking E2E on the CUDN EVPN profile (`tests/e2e/networking/vmaas/`) |
| **full** | `full-ci` | `full` | Broad serial OSAC E2E run on `full-ci`; `TEST_SUITE=stretched` runs only the shared-subnet BMI/ComputeInstance test |

`caas_networking` and `maas_networking` are extra `TEST_SUITE` values (Netris CaaS/MaaS entry points; dedicated OSAC tests are pending). Agentless-Net is a standalone CaaS flow that the root `make e2e` does not wire up.

### Compatibility Matrix

Each backend declares its supported `DEPLOY_SUITE` values in a `capabilities` file. The system validates the selected value before deployment starts.

| Backend | caas | maas | bmaas | vmaas | full |
|---------|:----:|:----:|:-----:|:-----:|:----:|
| netris  | yes | yes | yes | yes | yes |

The Netris PR workflow exposes three manual checks: `/test vmaas-netris` calls `e2e-vmaas-netris-full-install.yml` with `deploy-suite: vmaas`; `/test bmaas-netris` calls `e2e-bmaas-netris-full-install.yml` with `deploy-suite: bmaas`; `/test stretched-netris` calls `e2e-stretched-netris-full-install.yml` with `deploy-suite: full` and `test-suite: stretched` to test shared-subnet VM↔BM connectivity. `DEPLOY_SUITE=full` with the default `TEST_SUITE=full` runs the broad full-profile suite and includes the stretched test; it ignores `tests/e2e/networking/vmaas` (one ordered module) and `tests/e2e/networking/bmaas` (its `PROTOCOL_ICMP` rules are rejected with the `cudn_evpn` manager). `TEST_SUITE=bmaas` is valid only on `DEPLOY_SUITE=bmaas`, which keeps `k8sManager: ""`. The `vmaas` and `full` paths register the `cudn_evpn` Kubernetes manager and Netris fabric manager, so VM and bare-metal instances can share a subnet; `full` keeps the `full-ci` services enabled and overlays the same Netris EVPN NetworkClass. The OCP target must be converged OCP 4.22 with OVNKubernetes; its platform type may be `None`. ExternalIP and reference tests additionally require a separately provisioned and acknowledged return path for `172.27.0.0/16`.

### Backend Setup: Netris

The Netris backend requires the following files placed in `infra/netris/` before running:

| File | Description | How to obtain |
|------|-------------|---------------|
| `license.key` | Netris controller license | Obtain from Netris |
| `license.zip` | OSAC/AAP license (base64-encoded zip) | Obtain from Red Hat |
| `config` | INI file with lab name, AWS credentials, and Quay credentials | Create manually (see below) |

The `config` file format:

```ini
[default]
lab_name = <unique-name>
aws_access_key_id = <your-key>
aws_secret_access_key = <your-secret>
aws_region = us-east-1
netris_password = <your-netris-password>
quay_username = <your-quay-username>
quay_password = <your-quay-password>
```

- `lab_name` — unique identifier for your lab to avoid DNS collisions in Route 53. The backend uses it as the first DNS label in `ocp_base_domain`. Use a hostname-compatible label of at most 63 characters: ASCII letters, digits, and hyphens only, with a letter or digit at each end. Do not use underscores (for example, `qa-lab-1` is valid).
- AWS credentials — used for Route 53 DNS record management
- Quay credentials — the account must have pull access to `quay.io/osac-project/cluster-flavors`; `setup-infra` logs in automatically when it downloads the snapshot flavor image

The Netris backend's `dns_server` defaults to `8.8.8.8`. Some environments block that resolver. If it is unreachable from your lab and you only need a DNS override, export:

```bash
export EXTRA_VARS="dns_server=<reachable-dns-server>"
```

`OSAC_PROFILE` selects the OSAC Helm values preset; it is separate from `DEPLOY_SUITE` and `TEST_SUITE`, which select what is deployed and which tests run. Netris defaults `OSAC_PROFILE` to `caas-ci`. Both `caas-ci` and `bmaas-ci` enable Metal3, the OSAC component for bare-metal provisioning. Its installer check requires a cluster-scoped Kubernetes `Provisioning` resource with `watchAllNamespaces: true`. Netris defaults `bare_metal_services` to `false`, so `prep-osac` skips creating or updating that resource unless the flag is true. If the resource already exists with the required setting, the flag is not needed just for the installer check.

The same flag enables Netris's BMC (Baseboard Management Controller) support: `deploy-infra` starts `sushy-tools`, which emulates a server's management interface, and `deploy-ocp` reserves the OCP VM's BMC address. Without the flag those conditional setup tasks are skipped, even though the commands can still succeed. Use the flag when you need these bare-metal services as well as the Metal3 prerequisite.

This flag is profile-dependent, not required for every OSAC deployment:

| OSAC profile | When `bare_metal_services=true` is needed |
|--------------|-------------------------------------------|
| `caas-ci` | The current profile enables Metal3; set it if the required `Provisioning` resource is absent. |
| `bmaas-ci` | The profile enables Metal3; set it if the required `Provisioning` resource is absent. |
| `vmaas-ci` | Not needed in the current VMaaS full-install workflow. |

For another profile, check whether its values enable `bmf.metal3.enabled`. For `caas-ci` or `bmaas-ci`, if you also need to override DNS, combine both settings in one export; a second `export EXTRA_VARS=...` would replace the first value:

```bash
export EXTRA_VARS="bare_metal_services=true dns_server=<reachable-dns-server>"
```

The deployment example below exports `EXTRA_VARS` once; the top-level Makefile forwards it to each backend stage. For a profile that does not need bare-metal services, use only the DNS override if required.

Additionally, an OCP pull secret must be present at `/root/pull-secret` on the host.

All secret files are gitignored.

## How It Works

When you run `make e2e INFRA=netris DEPLOY_SUITE=full` with the required lab variables exported, the following happens:

1. **Validate** — checks that the `netris` backend exists and supports the `full` deployment suite
2. **`setup-infra`** — installs prerequisites, caches images (`ansible-playbook playbooks/setup-infra.yml`)
3. **`deploy-infra`** — deploys the Netris lab (`ansible-playbook playbooks/deploy-infra.yml`)
4. **`deploy-ocp`** — restores the OCP snapshot into the lab and waits for the cluster to become healthy. With `DEPLOY_SUITE=vmaas` or `DEPLOY_SUITE=full`, it also runs the `configure-cudn-evpn` role, which derives the Netris peer settings and configures the OCP CUDN/EVPN prerequisites. This path requires OCP 4.22 with OVNKubernetes, but does not require `platformStatus.type: BareMetal`.
5. **`deploy-osac`** — installs OSAC on the cluster (always a fresh Helm install) and writes `.env.infra` with cluster access credentials.
6. **`prepare-suite`** — `setup-full` prepares BMaaS-backed CaaS prerequisites, reapplies BMaaS defaults, then runs the read-only VMaaS EVPN prerequisite check.
7. **`run-tests`** — checks the backend's suite contract when one is defined, sources `.env.infra`, then runs `test-full`: the serial OSAC mono-repo E2E run with its configured exclusions.
When you run `make e2e INFRA=netris DEPLOY_SUITE=caas TEST_SUITE=caas_networking`, the following happens:

1. **Validate** — checks backend support for the suite.
2. **`deploy-setup`, `deploy-infra`, `deploy-ocp`, `deploy-osac`** — prepares the lab and installs OSAC.
3. **`prepare-suite`** — runs `setup-caas` to prepare the CaaS infrastructure.
4. **`run-tests`** — runs the dedicated OSAC monorepo suite when available; its pytest fixtures create tenant1 and tenant2. If the dedicated test path is absent, this target exits with an error.

For a persistent cluster on an already installed lab, run `make deploy-suite INFRA=netris DEPLOY_SUITE=caas` or `DEPLOY_SUITE=maas`. For persistent BMIs, use `DEPLOY_SUITE=bmaas`; this creates one BMI per test tenant and occupies two of the three BMaaS hosts.

Each step can be run independently — you don't have to run the full pipeline every time.

## Quick Start

### Run tests against an existing cluster

```bash
(cd /opt/osac && uv sync)

OSAC_NAMESPACE=osac-devel KUBECONFIG=~/.kube/config \
  OSAC_VM_KUBECONFIG=~/.kube/config make test-vmaas
```

### Full E2E with infrastructure provisioning

```bash
# Full profile: provision + deploy + broad OSAC E2E run
# If the default resolver is blocked, append dns_server=<reachable-dns-server> as shown above.
export EXTRA_VARS="bare_metal_services=true"
make e2e INFRA=netris DEPLOY_SUITE=full

# VMaaS networking on the CUDN EVPN profile (needs branch-built image overrides in EXTRA_VARS)
# Release gate equivalent: test_00..test_10 (phases A and B); NAT and ExternalIP are
# test_11..test_17 (phase C, not a gate); deletes are test_18..test_21 (phase D)
make e2e INFRA=netris DEPLOY_SUITE=vmaas

# BMaaS networking
make e2e INFRA=netris DEPLOY_SUITE=bmaas

# Stretched VM/BM test only, on the full profile
make e2e INFRA=netris DEPLOY_SUITE=full TEST_SUITE=stretched

# Or step by step
make setup-infra INFRA=netris DEPLOY_SUITE=full
make deploy-infra INFRA=netris DEPLOY_SUITE=full
make deploy-ocp INFRA=netris DEPLOY_SUITE=full
make deploy-osac INFRA=netris DEPLOY_SUITE=full
make setup-suite INFRA=netris DEPLOY_SUITE=full
make run-tests INFRA=netris DEPLOY_SUITE=full
# Full pipeline: provision + deploy + test when the dedicated suite is available
make e2e INFRA=netris DEPLOY_SUITE=caas TEST_SUITE=caas_networking

# Or, on an installed lab, leave a cluster or BMIs running
make deploy-suite INFRA=netris DEPLOY_SUITE=maas
make deploy-suite INFRA=netris DEPLOY_SUITE=bmaas
```

For a manual shared-subnet setup, pass `DEPLOY_SUITE=vmaas` (the focused profile) or `DEPLOY_SUITE=full` to `deploy-ocp`; each configures the CUDN/EVPN peer, VTEP, and route advertisements. The VMaaS prerequisite check verifies the underlay, BGP session, and PodNetwork advertisements. ExternalIP and EgressIP dataplane tests need their separate route policy enabled and acknowledged.

### Iterate on OSAC

```bash
# Redeploy OSAC without reprovisioning the lab
make redeploy-osac INFRA=netris

# Then re-run tests
make run-tests INFRA=netris DEPLOY_SUITE=full
make run-tests INFRA=netris DEPLOY_SUITE=caas TEST_SUITE=caas_networking
```

### Tear down

```bash
make destroy-osac INFRA=netris       # OSAC only, keep the lab
make destroy-ocp INFRA=netris        # Reset OCP, keep the Netris lab
make destroy-infra INFRA=netris      # Everything
```

### Gather diagnostics

```bash
make gather-infra INFRA=netris
make gather-suite INFRA=netris DEPLOY_SUITE=full
```

## Configuration

Configuration is supplied through environment variables and backend-specific Make/Ansible variables.

| Variable | Default | Description |
|----------|---------|-------------|
| `OSAC_NAMESPACE` | `osac-devel` | Namespace where OSAC is deployed |
| `KUBECONFIG` | `~/.kube/config` | Kubeconfig for the hub cluster |
| `OSAC_VM_KUBECONFIG` | **(required for vmaas)** | Kubeconfig for the VM cluster |
| `OSAC_PULL_SECRET_PATH` | **(required for caas)** | Path to OCP pull secret |
| `OSAC_FULFILLMENT_ADDRESS` | auto-derived | Fulfillment API address |
| `OSAC_VM_TEMPLATE` | `osac.templates.ocp_virt_vm` | VM template |
| `caas_cluster_template` | `osac.templates.ocp_small` | Netris CaaS cluster template for BMaaS-backed workers |
| `OSAC_CLI_PATH` | `osac` | Path to the CLI binary |
| `TEST` | (none) | pytest `-k` filter |
| `INFRA` | `netris` | Infrastructure backend |
| `DEPLOY_SUITE` | `caas` | What is deployed: `caas`, `maas`, `bmaas`, `vmaas`, `full` |
| `TEST_SUITE` | `DEPLOY_SUITE` | Which OSAC tests run (see `infra/netris/targets.md`) |
| `EXTRA_VARS` | (none) | Extra variables passed to the backend |

For E2E fixture and test guidance, see [the OSAC mono-repo E2E documentation](https://github.com/osac-project/osac/tree/main/tests/e2e).

## Adding a New Backend

Create `infra/<name>/` with:
- `Makefile` — Makefile implementing the contract targets (see `infra/contract.md`)
- `capabilities` — shell-sourceable file declaring `SUPPORTED_DEPLOY_SUITES="suite1 suite2"`
- Optional `contracts/<test-suite>` files — shell-sourceable `REQUIRED_VARS` lists for suite environment validation

Test code belongs in the OSAC mono-repo. Add backend capability and suite contract files as needed; the root Makefile needs a runner target when introducing a suite.
