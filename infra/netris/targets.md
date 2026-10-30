# Netris targets: DEPLOY_SUITE and TEST_SUITE

`DEPLOY_SUITE` selects what is deployed (OSAC profile, setup target, EVPN underlay). `TEST_SUITE` selects the OSAC
tests and defaults to `DEPLOY_SUITE`. Test code lives in the OSAC mono-repo and is selected by directory, never by
markers. See [`README.md`](README.md) for the lab itself and [`../contract.md`](../contract.md) for the backend contract.

## How to run

Run from the repository root of this checkout on the lab host. `IMG` is the same in all three commands.

```bash
IMG='osac_branch=<branch> fulfillment_service_image=<reg>/fulfillment-service:<tag> osac_operator_image=<reg>/osac-operator:<tag> osac_aap_image=<reg>/osac-aap:<tag>'
make e2e INFRA=netris DEPLOY_SUITE=vmaas EXTRA_VARS="$IMG"                         # VMaaS networking
make e2e INFRA=netris DEPLOY_SUITE=bmaas EXTRA_VARS="$IMG"                         # BMaaS networking
make e2e INFRA=netris DEPLOY_SUITE=full TEST_SUITE=stretched EXTRA_VARS="$IMG"     # stretched VM/BM
```

The image overrides are required for `vmaas` and `full` (the guard in `check_images.yml`); pass them for `bmaas` too,
since the PR branch needs its own images. `DEPLOY_SUITE=bmaas` runs the slow cross-tenant class unless
`TEST='not TestCrossTenantBmaasNetworking'` is added, as CI does. Every OSAC install is fresh.

## DEPLOY_SUITE

| `DEPLOY_SUITE` | `OSAC_PROFILE` | k8s manager | EVPN underlay | bare metal services | setup target | default `TEST_SUITE` |
|---|---|---|---|---|---|---|
| `caas` (default) | `caas-ci` | profile's | no | true | `setup-caas` | `caas` |
| `maas` | `caas-ci` | profile's | no | true | `setup-maas` | `maas` |
| `bmaas` | `bmaas-ci` | none (`""`) | no | true | `setup-bmaas` | `bmaas` |
| `vmaas` | `cudn-evpn-netris-test` | `cudn_evpn` | yes | false | `setup-vmaas` | `vmaas` |
| `full` | `full-ci` | `cudn_evpn` | yes | true | `setup-full` | `full` |

`setup-full` runs `setup-caas`, `setup-bmaas` and `setup-vmaas`. Agentless-Net (`infra/agentless-net`) supports only
`caas`; it is a standalone CaaS flow that the root `make e2e` does not wire up.

## TEST_SUITE

| `TEST_SUITE` | Selects | Valid on |
|---|---|---|
| `vmaas` | `tests/e2e/networking/vmaas/` | `vmaas` |
| `bmaas` | `tests/e2e/networking/bmaas/` | `bmaas` only: its `PROTOCOL_ICMP` rules are rejected with cudn_evpn |
| `stretched` | `tests/e2e/networking/stretched/` | `full` |
| `full` | `tests/e2e/` minus `networking/vmaas` and `networking/bmaas` | `full` |
| `caas` | `tests/e2e/caas/` | `caas`, `full` |

`maas`, `caas_networking`, `maas_networking`, `storage`, `metering` and `references` also exist as `test-<suite>`
targets. The generic `tests/e2e/vmaas` tree on Netris is covered by `DEPLOY_SUITE=full`.
`tests/e2e/networking/vmaas/` is one ordered module: never pass `TEST=` (`-k`) to slice it.

## Make variables

| Variable | Default | Meaning |
|---|---|---|
| `INFRA` | `netris` | Backend under `infra/` |
| `DEPLOY_SUITE` | `caas` | What is deployed (table above) |
| `TEST_SUITE` | `$(DEPLOY_SUITE)` | Which tests run (table above) |
| `TEST` | none | pytest `-k` filter for `test-<suite>` (not for `vmaas`) |
| `EXTRA_VARS` | none | Ansible extra vars (`key=value` or JSON) |
| `SUITE_STAGE` | `all` | `deploy-suite` stage: `all`, `setup` or `workload` |
| `KUBECONFIG` | `/root/.kube/config` | Hub kubeconfig, passed to Ansible as `kubeconfig_path` |
| `OSAC_VM_KUBECONFIG` | `$(KUBECONFIG)` | VM cluster kubeconfig (`.env.infra`) |
| `OSAC_NAMESPACE` | `osac-e2e-ci` | OSAC namespace |
| `OSAC_PULL_SECRET_PATH` | `/root/pull-secret` | Pull secret, passed to Ansible as `pull_secret_path` |
| `OSAC_PROFILE` | from `DEPLOY_SUITE` | OSAC installer values profile |
| `CAAS_*`, `MAAS_*` | see `Makefile` | CaaS and MaaS worker, image and template settings |

Precedence: `EXTRA_VARS` comes first and the backend's own mappings follow and win. For `kubeconfig_path`,
`pull_secret_path`, `osac_namespace` and `deploy_suite` use the Make variable, not `EXTRA_VARS`. `CAAS_*` and `MAAS_*` are the exception: their `-e caas_*` come before the backend mappings, so `EXTRA_VARS` wins over them.

Tenant CIDRs: prep-osac always adds all of `10.0.0.0/8` (the lab's Netris private allocation, `netris_private_allocation_cidr`) to `global.networking.excludedIpv4Cidrs` and asserts that the default tenant network and subnet are outside it. The lab sets no 10.x tenant network; the E2E suites use 172.16-172.31 except 172.27 (ExternalIP test pools) and 172.30 (OpenShift services). Keep any you add inside that set.

The VMaaS and stretched tests reach guests through a helper Pod, not `virtctl`. The pytest host needs `kubectl` or `oc`, `ssh` and `ssh-keygen`; the cluster must be able to pull `OSAC_E2E_SSH_HELPER_IMAGE` (default: the digest-pinned `ghcr.io/osac-project/osac-aap` image the cluster already pulls for AAP jobs; the lab exports nothing, set it to the deployed tag or a mirror only when ghcr.io is unreachable).

The `deploy-suite` target (persistent workloads) is unrelated to the `DEPLOY_SUITE` variable.

## .env.infra

`deploy-osac` writes `infra/netris/.env.infra` with `KUBECONFIG`, `OSAC_NAMESPACE`, `OSAC_VM_KUBECONFIG` and
`OSAC_PULL_SECRET_PATH`. `setup-bmaas` appends the BMaaS keys (`OSAC_BMH_SSH_HOSTS`, `OSAC_BMI_INSTANCE_TYPE`,
`OSAC_BMI_NETWORK_INTERFACE`) that the contracts in `infra/netris/contracts/<test-suite>` require (`bmaas`,
`stretched`, `full`; `vmaas` needs only `KUBECONFIG`, `OSAC_NAMESPACE`, `OSAC_VM_KUBECONFIG`). `setup-vmaas` adds `OSAC_NETRIS_VM_EXTERNAL_PATH_ENABLED=true` only when the `172.27.0.0/16`
return path is acknowledged.

## Old names

| Old | New |
|---|---|
| `SUITE=vmaas_networking` | `DEPLOY_SUITE=vmaas` |
| `SUITE=bmaas_networking` | `DEPLOY_SUITE=bmaas` |
| `SUITE=stretched_networking` | `DEPLOY_SUITE=full TEST_SUITE=stretched` |
| `SUITE=vmaas` (generic tree) | `DEPLOY_SUITE=full` |
| `OSAC_DEPLOY_MODE=fresh` | removed (every install is fresh) |
| `OSAC_DEPLOY_MODE=snapshot`, `make deploy-fast` | removed; the OCP SNO snapshot restore stays |

`make` stops with an error when `SUITE` or `OSAC_DEPLOY_MODE` is set, at the root and in `infra/netris`.
