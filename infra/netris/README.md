# netris-test-infra

Ansible automation to deploy OCP SNO on a [Netris Spectrum-X simulated lab](https://github.com/danmanor/netris-lab) and exercise the suites currently advertised by the backend.

## Architecture

The [netris-lab](https://github.com/danmanor/netris-lab) deploys a full simulated Spectrum-X GPU cluster network on a single bare-metal host using KVM/libvirt:

- **Netris controller** on K3s — manages all network devices via REST/gRPC API
- **~13 switch VMs** (Cumulus Linux) — leaf/spine fabric for North-South connectivity
- **4 softgate VMs** — provide NAT/L4LB and BGP peering for internet access
- **4 server VMs** (hgx-00 to hgx-03) — simulated GPU servers, managed by Netris

This repo takes the first server (hgx-00), resizes it for OCP, configures Netris networking (VPC, VNet, Subnet), and installs OpenShift SNO on it using the Assisted Installer. CaaS and MaaS use the remaining three servers as BMaaS-managed worker VMs. BMaaS provides the BareMetalHosts; the OSAC cluster order provisions and assigns only the requested worker count.

```
Bare-metal host
└── netris-lab (~15 VMs)
    ├── Netris controller (K3s)
    ├── Switches (leaf/spine fabric)
    ├── Softgates (NAT → internet)
    ├── hgx-00 (resized: 20 vCPU, 64G RAM)
    │   ├── VPC/VNet/Subnet configured via Netris API
    │   ├── OCP SNO installed via Assisted Installer
    │   └── OSAC deployed on top
    └── hgx-01..03 (BMaaS worker VMs)
        ├── Registered as BareMetalHosts and sized by the CaaS/MaaS setup
        └── Selected by BareMetalInstanceType when the OSAC cluster order runs
```

Internet access for OCP image pulls flows through: hgx-00 → NS VNet → softgate SNAT → host iptables masquerade → internet.

## Prerequisites

- **Bare-metal host** running a RHEL-family distribution (RHEL, Rocky Linux, CentOS Stream, or Fedora) with KVM support
- **System packages** — `dnf install -y git make python3-pip ansible-core && /usr/bin/python3 -m pip install --ignore-installed ansible`. `make setup-infra` then installs the rest of the BM bootstrap (`sshpass`, `tmux`, `policycoreutils-python-utils`), EPEL from the Fedora URL (required on RHEL), and the Python dependencies into the Ansible interpreter's environment.
- **Resources**: ~32+ CPU cores, 128+ GB RAM (lab VMs + OCP SNO VM)
- **Storage**: ~400GB+ for OCP disk images, K3s, and containers. If the root partition is smaller, use a secondary data disk and enable automatic provisioning with `disk_setup_enabled=true` (via `EXTRA_VARS` or in the config). Run `make disk-setup` standalone or pass the variable during setup: `make setup-infra EXTRA_VARS="disk_setup_enabled=true"`
- **Netris license key** — place at repo root as `license.key`
- **OSAC/AAP license** — place at repo root as `license.zip`
- **OpenShift pull secret** — place at `/root/pull-secret` (or set `pull_secret_path`; download from [console.redhat.com](https://console.redhat.com/openshift/downloads))
- **Config file** — place `infra/netris/config` (INI format, gitignored) with your lab name, AWS credentials, and Quay username/password. The Quay account must have pull access to `quay.io/osac-project/cluster-flavors` for the snapshot flavor download to work. AWS credentials can be obtained from the [CI vault](https://vault.ci.openshift.org/ui/vault/secrets/kv/kv/selfservice%2Fosac%2Fpacket-osac). See Quick Start below. The IAM user needs `route53:ChangeResourceRecordSets`, `route53:ListHostedZones`, and `route53:GetChange` permissions on the hosted zone.

All system packages, tools, and SSH keys are installed automatically by `make setup-infra`. A pre-flight check validates all required files, KVM support, and minimum memory before deploying.

## Quick Start

```bash
git clone --recurse-submodules https://github.com/danmanor/netris-test-infra.git
cd netris-test-infra

# Place prerequisites
cp /path/to/license.key ./license.key
cp /path/to/license.zip ./license.zip
cp /path/to/pull-secret /root/pull-secret

# Create infra/netris/config (unique lab name, AWS credentials, and Quay credentials)
# lab_name becomes a subdomain under the shared hosted zone (e.g., jsmith.ecoeng-osac-ci.devcluster.openshift.com)
cat > infra/netris/config << EOF
[default]
lab_name = <unique-lab-name>
aws_access_key_id = <your-key>
aws_secret_access_key = <your-secret>
aws_region = us-east-1
netris_password = <your-netris-password>
quay_username = <your-quay-username>
quay_password = <your-quay-password>
EOF

# Install prerequisites and cache images (shared, run once)
make setup-infra

# Full deployment — installs OCP + OSAC from scratch
make deploy

# Or leave a CaaS cluster running
make deploy-suite DEPLOY_SUITE=caas  # setup, pytest tenants, Netris tenant network, persistent cluster
```

After deployment, the kubeconfig is at `/root/.kube/config`.

## Make Targets

### Deploy

| Target | Description | Time |
|--------|-------------|------|
| `make deploy` | Full pipeline: deploy-infra → deploy-ocp → deploy-osac (fresh Helm install) | ~2-3 hrs |
| `make setup-infra` | Install prerequisites, cache images + snapshot flavor, build tools | ~10 min |
| `make deploy-infra` | Deploy netris-lab (K3s, topology, VMs, connectivity) | ~12 min |
| `make deploy-ocp` | Configure Netris networking + restore OCP SNO from snapshot | ~15 min |
| `make deploy-osac` | Prepare OSAC values + Helm install (always a fresh install) | ~30-60 min |

The `caas` and `maas` suites use BMaaS-backed workers and the persistent
cluster roles.

## CaaS (run after deploy)

| Target | Description | Time |
|--------|-------------|------|
| `make setup-caas` | Prepare BMaaS worker VMs, register worker types, DiskImage, Netris ExternalIPPool, and catalog | ~30 min |
| `make deploy-caas` | Create the CaaS catalog cluster with one `ci-worker` BareMetalInstanceType | ~60 min |
| `make setup-maas` | Configure all three BMaaS worker VMs as 10 vCPU / 20GiB `g5` hosts; deploy-maas requests two | ~30 min |
| `make deploy-maas` | Create the MaaS catalog cluster with two `g5` BareMetalInstanceTypes and template defaults | ~60 min |
| `make deploy-suite DEPLOY_SUITE=caas` or `DEPLOY_SUITE=maas` | Run setup, shared pytest tenant fixtures, tenant Netris networking, and persistent cluster deployment | setup + deploy |
| `make deploy-suite DEPLOY_SUITE=bmaas` | Run BMaaS setup, shared pytest tenant fixtures, and create one persistent BMI in each tenant | setup + provisioning |
| `make e2e INFRA=netris DEPLOY_SUITE=caas TEST_SUITE=caas_networking` (or `maas`) from the repo root | Run setup and then the OSAC pytest suite when it exists; the suite fixtures will create tenants | varies |

CaaS and MaaS setup do not add a router to worker management DHCP leases.
A full `redeploy-fresh` recreates the management VM and its DHCP file; a partial
redeployment that retains the VM may retain an older injected router line.
The tenant VNet DHCP should supply the worker default gateway. Cluster API and
ingress use the Netris external-access flow configured in AAP; the shared
ExternalIPPool is used for tenant egress. The guest network task restores
`routingViaHost: false` only if an older cluster has it set to true, then waits
for the Network operator. Fresh clusters keep their default setting. The OCP
data uplink is discovered from the live Netris topology; `eth10` remains the
VMaaS EVPN underlay when enabled.

### VMaaS and BMaaS shared-subnet networking

The Netris VMaaS and full paths use the single-node OCP 4.22 OVNKubernetes cluster with the `None` platform type. For `DEPLOY_SUITE=vmaas` or `DEPLOY_SUITE=full`, `deploy-infra` reuses h00's Netris-managed leaf-1 link (`eth10` ↔ `swp1s0`) for the `/31` underlay and enables underlay on that link; leaf-0's `eth9` link remains the `br-ex` data path. h00's Linux interface names are resolved from the MAC addresses correlated across Netris, the leaf interface, and the libvirt tunnel, so the guest NIC enumeration may change without changing which path carries data or underlay. It sets h00's server ASN and EVPN-VTEP inventory role so Netris can generate the leaf-side peer from the managed link. `deploy-ocp` validates the OpenShift inputs and writes an ignored, site-specific `infra/netris/.evpn-values.yaml`; the fresh `deploy-osac` path passes those values to `osac-installer` `install-infra`, which configures OVN route advertisements, NMState, the unmanaged VTEP, node uplink addresses, and OCP-side FRR. The separate Netris deployment configures the fabric side; this flow does not install or rely on the Netris host agent. No standalone VLAN-backed BGP object is created for the routed `/31`. The OSAC `cudn-evpn-netris-test` profile enables both VMaaS and BMaaS and selects Netris plus CUDN EVPN, allowing both instance types to attach to one subnet. BMaaS continues to use the Netris server-port names and its separate per-BMH MAC mapping for `eth9`/`eth10`; assigning h00's `eth10` to the underlay does not change h01–h03 provisioning NIC selection. `setup-bmaas` publishes the configured BMI guest interface name as `OSAC_BMI_NETWORK_INTERFACE`; BMaaS and stretched networking tests consume that value instead of embedding a server-port name in the test code.

The commands below run from the repository root of a checkout of this branch on the lab host. `IMG` holds the branch-built images (the same value in all three commands); the guard in `check_images.yml` requires them for `vmaas` and `full`, and the PR branch needs its own images for `bmaas` too.

```bash
IMG='osac_branch=<branch> fulfillment_service_image=<reg>/fulfillment-service:<tag> osac_operator_image=<reg>/osac-operator:<tag> osac_aap_image=<reg>/osac-aap:<tag>'
make e2e INFRA=netris DEPLOY_SUITE=vmaas EXTRA_VARS="$IMG"                      # VMaaS networking
make e2e INFRA=netris DEPLOY_SUITE=bmaas EXTRA_VARS="$IMG"                      # BMaaS networking
make e2e INFRA=netris DEPLOY_SUITE=full TEST_SUITE=stretched EXTRA_VARS="$IMG"  # stretched VM/BM
```

Add `osac_repo=https://github.com/<fork>/osac.git` to `IMG` when the branch lives on a fork. `DEPLOY_SUITE=bmaas` runs the slow cross-tenant class unless `TEST='not TestCrossTenantBmaasNetworking'` is added, as CI does. Never pass `TEST=` (a `-k` filter) to `DEPLOY_SUITE=vmaas`: `tests/e2e/networking/vmaas/` is one ordered module. `SUITE=` and `OSAC_DEPLOY_MODE=` stop `make` with an error; see [`targets.md`](targets.md) for the old-to-new names, the full mapping and every variable.

`DEPLOY_SUITE=vmaas` selects the `cudn-evpn-netris-test` OSAC profile by default and runs `tests/e2e/networking/vmaas` (selected by directory, not by markers; the target has no `-x`, so one NAT failure does not hide the rest). Set `OSAC_PROFILE=cudn-evpn-netris-test` explicitly to pin the profile. It selects the CUDN EVPN and Netris managers; `deploy-infra` provisions the fabric side, `deploy-ocp` validates inputs and generates the installer values, and `deploy-osac` configures the OpenShift side through `install-infra`. The VMaaS and stretched tests no longer use `virtctl`: they reach guests through a helper Pod (`osac-e2e-ssh-helper`, created per VM namespace) and `kubectl exec`. The pytest host needs `kubectl` or `oc`, `ssh` and `ssh-keygen`. The helper image defaults to the digest-pinned OSAC execution-environment image (`ghcr.io/osac-project/osac-aap`), which the cluster already pulls for AAP jobs. The lab exports nothing; set `OSAC_E2E_SSH_HELPER_IMAGE` to the deployed tag or a mirror (an image with an ssh client and a passwd entry for uid 65534) only when ghcr.io is unreachable. The pytest identity must be allowed to create Pods running as uid 65534 in the VM namespaces. `DEPLOY_SUITE=bmaas` keeps `global.networking.k8sManager: ""` (prep-osac asserts it); with cudn_evpn its `PROTOCOL_ICMP` SecurityGroup rules would be rejected.

#### VMaaS with the Netris Fabric Manager

VMaaS EVPN runs the OSAC Netris Fabric Manager (`osac.templates.netris`) and the `cudn_evpn` Kubernetes Manager from the networking contract of the OSAC installer chart (`global.networking`, `aap.instanceGroups.networkFulfillment`). The installer chart renders both registrations (`osac-network-fabric-manager-netris`, `osac-network-k8s-manager-cudn-evpn`, immutable) and creates the default NetworkClass; nothing is applied by hand. `prep-osac` writes these values into the profile `instance.yaml` and the password into a separate mode-0600 file:

| Value | Source |
|-------|--------|
| `global.networking.provisioningEnabled: true`, `fabricManager: netris` | fixed |
| `global.networking.k8sManager` | `cudn_evpn` for `DEPLOY_SUITE` in `netris_k8s_manager_suites` (vmaas, full); otherwise the profile's value (`cudn_evpn` for caas-ci, `""` for bmaas-ci, asserted) |
| `global.networking.networkClass.defaults` | `virtualNetworkIPv4CIDR` and `subnetIPv4CIDR` from `netris_tenant_network_cidr` / `netris_tenant_subnet_cidr` (`192.168.101.0/24`, the CaaS tenant default network) |
| `global.networking.excludedIpv4Cidrs` | computed: all of `10.0.0.0/8` (the Netris private allocation; tenant networks must not use 10.x, the E2E suites use 172.16-172.31 except 172.27 and 172.30), the bare-metal resolver `/32` (`dns_server`, handed to bare metal by the Netris default DHCP option set), OCP SNAT/DNAT `/32`, node subnet, `192.168.16.0/20`, BMC network, provisioning SNAT range, then from `.evpn-values.yaml` the VTEP CIDR, the Netris loopbacks (`acceptPrefixes`) and the node uplink networks, plus `netris_extra_excluded_cidrs` |
| `aap.instanceGroups.networkFulfillment.config` | `NETRIS_CONTROLLER_URL` (HTTP NodePort), `NETRIS_USERNAME`, `NETRIS_VALIDATE_CERTS: "false"`, `NETRIS_SITE_ID`, `NETRIS_TENANT_ID: "1"`, `NETRIS_TENANT_NAME`, `NETRIS_MGMT_VPC_ID`, `NETRIS_MGMT_VPC_NAME`, `NETRIS_BM_PROVISIONING_VNET`, `NETRIS_RESOURCE_CLASS_MAP` (the FabricDomain needs it). There is no DNS key: OSAC has no per-resource DNS |
| `aap.instanceGroups.clusterFulfillment.config` | CaaS profiles only: `NETWORK_CLASS: netris` and `NETWORK_STEPS_COLLECTION: netris.steps` (the controller URL, TLS and CA are bridged from `networkFulfillment.config` by the chart). Other keys: `NETRIS_USERNAME`, `NETRIS_SITE_ID`, `NETRIS_TENANT_ID`, `NETRIS_TENANT_NAME`, `NETRIS_MGMT_VPC_ID`, `NETRIS_MGMT_VPC_NAME`, `NETRIS_RESOURCE_CLASS_MAP` |
| `aap.instanceGroups.networkFulfillment.secret.NETRIS_PASSWORD` | `values/<profile>/netris-private.local.yaml` (mode 0600), passed to `install-osac` as `INSTANCE_VALUES_EXTRA` |
| `aap.instanceGroups.clusterFulfillment.secret.NETRIS_PASSWORD` | only when the profile enables CaaS; it lands in the mode-0600 `instance.yaml` itself (like the AWS and SSH secrets there) |
| `aap.configAsCode.projectGitUri` / `projectGitBranch` | `osac_repo` / `osac_branch` unless `aap_project_git_uri` / `aap_project_git_branch` are set |

The AAP project checkout wins over the execution environment image for collections (`osac-aap/ansible.cfg`), so the default execution environment image (`aap.configAsCode.eeImage`) works and no derived image is built. The AAP bootstrap image is different: the bootstrap job runs `osac.config_as_code.configure` from `aap.bootstrap.image`, so a `main` image registers main's job templates. `osac_repo` must point at a repository AAP can clone (for example `EXTRA_VARS="osac_repo=https://github.com/<user>/osac.git osac_branch=<branch>"`).

The lab needs an osac (#2051) commit that has the DNS removal (no `CUDN_EVPN_DNS_RESOLVERS` or Netris DNS SNAT requirement in the NetworkClass step) and the `security_group_icmp` capability (the Netris registration declares `eastWestEthernet,security_group_icmp`, which `setup-vmaas` asserts); use that commit for `osac_branch` and build the operator, fulfillment-service and AAP images from it. `prep-osac` also patches the cloned aap chart to accept the lab's plain-HTTP Netris controller URL (task "Allow HTTP Netris controller URL in the isolated lab", which fails when the chart text changes). `KUBECONFIG` may be non-default: `restore-ocp` also writes `/root/.kube/config`, which many roles read.

Images from the PR branch are required. The profile's operator, fulfillment-service and AAP bootstrap images are ghcr `:latest`/`:main`. For an install of `DEPLOY_SUITE=vmaas` or `full`, `deploy-setup` and `deploy-infra` fail early on a lab host (`_check-osac-images`; it is skipped under GitHub Actions, where the images are built after `deploy-ocp`) and `prep-osac` checks again, unless `fulfillment_service_image`, `osac_operator_image` and `osac_aap_image` are set to a tagged image (a tag, not a `@sha256` digest) other than `:latest` or `:main`. Konflux builds them for each PR commit as `quay.io/redhat-user-workloads/osac-tenant/{osac-operator,fulfillment-service,osac-aap}:on-pr-<full commit sha>` (expire after 5 days); take the sha from `git rev-parse origin/<branch>`. The hub pull secret (`pull_secret_path`) must be able to pull from `quay.io/redhat-user-workloads`; this repository does not configure that registry anywhere, so verify it before the run.

`setup-vmaas` checks the registrations (`immutable`, `ansible_role == osac.templates.netris`, `network_types` containing `evpn`) and waits through the private API until the default NetworkClass is `NETWORK_CLASS_STATE_READY` with `fabric_manager=netris` and `k8s_manager=cudn_evpn`.

DNS: OSAC has no per-resource DNS. VMs on the primary UDN use the cluster DNS that OVN-K DHCP hands out. Bare metal gets an installation-level resolver (`dns_server`, default `8.8.8.8`) from the Netris default DHCP option set. `configure-netris` (run by `deploy-ocp` for every deployment suite) writes it through `/api/v2/dhcp-option-set` and fails when the default option set is missing. This is the lab's copy of the provider install step; it is not OSAC code. Bare metal without internet access needs no DNS reachability.

Prerequisites outside this repository:

- D-1/D-2: the Netris controller reachable from AAP at the HTTP NodePort URL.
- The helper Pod image (`OSAC_E2E_SSH_HELPER_IMAGE`) pullable by the cluster (see above).
- NAT and ExternalIP tests (`test_11` to `test_17`) use the routed `198.51.100.24/29` pool (`connectivity_mode: isolated`) and run without `ocp_vmaas_external_ip_*`. Only the `external_ip/` and `references/` directories use the `172.27.0.0/16` pool: for those, set `ocp_vmaas_external_ip_tests_enabled` and `ocp_vmaas_external_ip_return_path_acknowledged` to true (then `setup-vmaas` exports `OSAC_NETRIS_VM_EXTERNAL_PATH_ENABLED=true` into `.env.infra`) and provide the `172.27.0.0/16` return path.

Release gate: the module `test_vmaas_networking.py` is ordered, `test_00` to `test_21`. The gate equivalent is phases A and B, `test_00` to `test_10`. NAT and ExternalIP (phase C, `test_11` to `test_17`) are not part of the gate until Netris builds the VPC VRF on the SoftGates; they always run and fail with a diagnosis rather than skip. Phase D, `test_18` to `test_21`, are the explicit deletes. Helper Pods, Secrets and NetworkPolicies that an aborted run leaves behind carry the label `osac-e2e/ssh-helper=true`; `make destroy-vmaas` and `make gather-vmaas` delete them (nothing found is fine).

Expected results of `make e2e INFRA=netris DEPLOY_SUITE=vmaas`, by test number in `test_vmaas_networking.py`:

| Tests | Expectation |
|---|---|
| `test_00` to `test_04` | Connectivity and isolation (gate). Should pass once the helper Pod reaches the VMs over SSH; never run automated before |
| `test_05` | ICMP rule rejection; passes with the ICMP capability images, fails on older ones |
| `test_06` | Cluster DNS from OVN-K DHCP; unknown until run on the lab |
| `test_07` to `test_09` | SecurityGroup allow, deny and update; should pass, not lab-tested |
| `test_10` | Cross-tenant isolation; should pass |
| `test_11` | External IP pool; depends on Netris accepting the pool allocation |
| `test_12` to `test_17` | NAT and ExternalIP paths; expect failure until Netris builds the VPC VRF on the SoftGates without member ports (see the probe findings) and imports the `0:<VNI>` route targets (SoftGates import `0:<VNI>`, same as `cudn_evpn`; the leaves auto-generate `<ASN>:<VNI>`). A red `test_12` is the honest result and replaces the earlier skips |
| `test_18` to `test_21` | Explicit deletes; run only when everything before passes (finalizers clean up otherwise) |

The Netris gateway stays on `gateway_ipv4` (`.1`) of the EVPN Subnets (the lab underlay steps are unchanged). The module is ordered and runs about 45-60 minutes when green.

Lab probe findings (2026-10-29, one-off Netris API and FRR probe): the Netris API assigned VNIs (VPC 11, V-Net 14, V-Net with gateway 17) but none of them, nor the probe VPC VRF, appeared on any leaf or SoftGate, with or without a gateway. Netris appears to deploy a V-Net/VRF only where member ports exist (the probe V-Nets had none); a bare-metal V-Net member made the earlier spike work. Open question: with the hub as underlay (no V-Net member port), does Netris ever build the VPC VRF on the leaves and SoftGate? This is needed for routed/NAT/ExternalIP traffic (`test_12` to `test_17`), not for `test_00` to `test_10`. Explicit `vxlanID` values are honoured, 44-character VPC and V-Net names are accepted (47 characters, `osac-natgw-<uuid>`, untested), and Netris exposes no route-target field.

The focused BMaaS Netris networking invocation is:

`make e2e INFRA=netris DEPLOY_SUITE=bmaas EXTRA_VARS="$IMG"`

`DEPLOY_SUITE=bmaas` (profile `bmaas-ci`, `k8sManager: ""`) runs `tests/e2e/networking/bmaas` by directory. The standard BMaaS suite does not select that directory. It is valid only with `DEPLOY_SUITE=bmaas`: its `PROTOCOL_ICMP` rules are rejected with cudn_evpn.

The stretched VMaaS↔BMaaS Netris invocation is:

```bash
make e2e INFRA=netris DEPLOY_SUITE=full TEST_SUITE=stretched EXTRA_VARS="$IMG"
```

`DEPLOY_SUITE=full TEST_SUITE=stretched` uses the `full-ci` profile, prepares CaaS, BMaaS and VMaaS prerequisites plus the CUDN EVPN underlay, and runs only `tests/e2e/networking/stretched`. The same test is also included in `TEST_SUITE=full`. Both contracts require the BMI guest interface name published by BMaaS setup.

### Full-profile E2E

```bash
make e2e INFRA=netris DEPLOY_SUITE=full EXTRA_VARS="$IMG"
```

`DEPLOY_SUITE=full` uses the `full-ci` OSAC profile and configures the same h00 underlay and CUDN EVPN prerequisites. `setup-full` prepares BMaaS-backed CaaS prerequisites, reapplies BMaaS defaults, then runs the VMaaS prerequisite check. `test-full` runs the serial OSAC mono-repo E2E set with its configured exclusions; it ignores `tests/e2e/networking/vmaas` (an ordered module) and `tests/e2e/networking/bmaas` (its `PROTOCOL_ICMP` rules are rejected with cudn_evpn) and includes the shared-subnet stretched test. The Netris PR workflow exposes `bmaas-netris`, `vmaas-netris`, and `stretched-netris`; the stretched check runs only the shared-subnet BMI/ComputeInstance test.

VMaaS requires `KUBECONFIG`, `OSAC_NAMESPACE`, and `OSAC_VM_KUBECONFIG` in `.env.infra`. For the single-cluster profile, the VM kubeconfig may default to the hub kubeconfig; configure a separate path when a separate workload cluster is used.

Suite fixtures create their own tenant `VirtualNetwork`, `Subnet`, `SecurityGroup`, and `ExternalIPPool` resources. Lab setup owns the cluster/fabric prerequisites and must not pre-create fixture-owned tenant resources. PodNetwork route advertisements support shared-subnet VMaaS/BMaaS traffic. ExternalIP and EgressIP dataplane tests require a separately provisioned and acknowledged route/return path for `172.27.0.0/16`; enable `ocp_vmaas_external_ip_tests_enabled` only after verifying that path.

To collect diagnostics from an existing deployment, run `make gather-suite INFRA=netris DEPLOY_SUITE=vmaas`. The CUDN EVPN captures are written under `infra/netris/logs/cudn-evpn/`. Collection is read-only and best-effort; unavailable APIs or peers get an explicit marker in the output. Captured Kubernetes YAML, FRR logs, and Netris responses are scrubbed for credential-like values before they are written.

### Destroy

| Target | Description |
|--------|-------------|
| `make destroy-full` | Tear down everything: OSAC + OCP artifacts + netris-lab |
| `make destroy-osac` | Tear down OSAC: helm releases, operators, CRDs, namespaces |
| `make destroy-ocp` | Reset OCP for reinstall: delete cluster, recreate disk, boot VM |
| `make destroy-infra` | Tear down netris-lab (VMs, K3s, topology) |
| `make destroy-caas` | Delete the named OSAC cluster and retain reusable BMaaS hosts |
| `make force-destroy-caas` | Force-clean stuck orders, remove worker BMHs, wipe worker VMs, and sweep Netris orphans |
| `make destroy-maas` | destroy-caas with MaaS cluster/host-type overrides |
| `make force-destroy-maas` | force-destroy-caas with MaaS overrides |
| `make destroy-bmaas` | BMaaS teardown: remove BMH/K8s resources, stop BMaaS VMs, clean disks, delete BMH namespace |

### Recovery and Utilities

| Target | Description |
|--------|-------------|
| `make connectivity` | Re-run lab connectivity (VPN, BGP, softgates) without full redeploy |
| `make run-osac-setup` | Run the infrastructure and application Helm installs after prep-osac |
| `make prep-osac` | Ansible-only OSAC prep (clone, patch values, copy secrets) — no Helm install |
| `make vendor-update` | Refresh vendored Ansible collections |
| `make lint` | Run ansible-lint |
| `make gather-infra` | Gather diagnostic info from the cluster |

### Typical Workflows

**First deploy on a fresh server:**
```bash
make setup-infra          # install prerequisites, cache images, build tools
make deploy         # deploy lab + OCP + OSAC (~2-3 hrs; OCP is restored from a snapshot, OSAC is a fresh install)
```

**Deploy with image overrides (test a PR build):**
```bash
make deploy EXTRA_VARS="fulfillment_service_image=quay.io/osac/fulfillment-service:pr-123"
```

**Deploy with BMaaS values and image overrides:**
```bash
make deploy-ocp
make deploy-osac OSAC_VALUES_FILE=values/bmaas-ci/values.yaml \
  EXTRA_VARS="osac_operator_image=quay.io/dmanor/osac-operator:tag bmf_operator_image=quay.io/dmanor/bare-metal-fulfillment-operator:tag bare_metal_services=true aap_project_git_branch=my-feature-branch"
make setup-bmaas
```

> `aap_project_git_branch` (and `aap_project_git_uri`) point the AAP config-as-code project
> at a specific branch, so AAP syncs osac-aap playbooks/collections from that branch at
> runtime. This is separate from `osac_branch`, which only controls the mono-repo clone used
> for the installer Helm charts — to fully test a PR whose changes include osac-aap Ansible,
> set both `osac_branch` and `aap_project_git_branch` to the PR branch.

**Re-deploy OSAC after code changes:**
```bash
make destroy-osac   # tear down OSAC (keeps OCP and lab)
make deploy-osac    # redeploy
```

**Re-install OCP (e.g., different version):**
```bash
make destroy-ocp    # delete cluster, recreate disk
make deploy-ocp     # reinstall
```

**Fix lab connectivity issues (e.g., softgate/E-BGP):**
```bash
make connectivity   # re-runs VPN, socat, ISP FRR, softgate agents
```

**Deploy CaaS after OSAC is up:**
```bash
make setup-caas     # prepare BMaaS workers and register CaaS prerequisites
make deploy-caas    # create cluster
```

**Deploy MaaS after OSAC is up:**
```bash
make setup-maas     # h01–h03 use 10 vCPU / 20GiB and are registered as g5 BMaaS hosts
make deploy-maas    # create a 2-worker cluster; optional template defaults apply
```

**Rebuild from scratch:**
```bash
make destroy-full   # tear down everything
make deploy         # full redeploy
```

**BM full pipeline (redeploy-server.sh):**
```bash
# CaaS (default)
make redeploy-fresh

# MaaS (setup-maas / deploy-maas)
make redeploy-fresh DEPLOY_SUITE=maas
```

### Bare-Metal Lab Deployment (from laptop)

For persistent bare-metal servers behind NAT (e.g., Red Hat lab infrastructure), use the remote deploy workflow. This handles image caching, bootstrapping, and resilient multi-step deploys from your laptop.

**One-time setup:**
```bash
git clone --recurse-submodules https://github.com/osac-project/osac-test-infra.git
cd osac-test-infra/infra/netris

# Create env file from template (one per server, gitignored)
cp scripts/env.sh.example scripts/env.sh
# Edit scripts/env.sh with: SERVER IP, PASSWORD, LAB_NAME, NETRIS_PASSWORD, secrets paths, AWS keys
# For private snapshot flavor pulls, also set QUAY_USERNAME and QUAY_PASSWORD
# OSAC_PULL_SECRET_PATH (default /root/pull-secret) is where the pull secret lands on the server and what the deploy reads
```

**Deploy:**
```bash
source scripts/env.sh && make deploy-jump
```

`NETRIS_PASSWORD` is required by `deploy-jump` and is written to the remote `config` file. Keep it in the gitignored env file; the script sends the generated config over SSH rather than placing the password in the SSH command.

For a private snapshot flavor pull, set both `QUAY_USERNAME` and `QUAY_PASSWORD` in that env file. `deploy-jump` writes them to the remote `config`; the snapshot cache role uses them to create a temporary Skopeo auth file, so a separate Quay `skopeo login` on the worker is unnecessary. They can be left empty when no private flavor pull is needed.

This single command:
1. Pre-caches container images on your laptop (with retries, avoids rate limits)
2. Rsyncs the repo + cached images to the server
3. Bootstraps packages (EPEL, Ansible, pip deps)
4. Sets up data disk (partition, mount, symlinks, SELinux)
5. Destroys any previous deployment
6. Runs the full pipeline: setup-infra → deploy-infra → deploy-ocp → deploy-osac → post-install → suite setup → suite workload (including tenant and network preparation) → access-doc

**Monitor:**
```bash
ssh root@$SERVER -t tmux attach -t deploy
ssh root@$SERVER tail -f /root/deploy.log
```

**Multiple servers:** Create one env file per server (`scripts/env-mylab.sh`), then:
```bash
source scripts/env-mylab.sh && make deploy-jump
```

**BM-specific make targets (run on server):**

| Target | Description |
|--------|-------------|
| `make redeploy-fresh` | Destroy + wipe progress + full pipeline (`DEPLOY_SUITE`) |
| `make redeploy-continue` | Resume failed redeploy from last incomplete step |
| `make disk-setup` | Auto-detect and mount data disk |
| `make post-install` | Fix Keycloak/UI + generate access doc |
| `make access-doc` | Generate the access document only |
| `make health-check` | Quick status verification |

`redeploy-server.sh` steps: `setup-infra` → `deploy-infra` → `deploy-ocp` → `deploy-osac` → `post-install` → `setup-caas|setup-maas|setup-bmaas` → `deploy-caas|deploy-maas|deploy-bmaas` → `access-doc`. OSAC is always a fresh Helm install; `--snapshot` was removed and exits with an error.

`post-install` generates the initial access document before workload setup. The final `access-doc` step refreshes it with workload-cluster details.

See the PR description for known issues and workarounds specific to BM/RHEL environments.

## Accessing OCP Routes

After `make deploy-osac`, a socat forwarder on port 9444 provides access to OCP routes (AAP UI, OCP console, fulfillment API) from external browsers. Port 443 is intercepted by K3s svclb (Netris controller), so 9444 is used instead.

Add to your local `/etc/hosts`:
```
<server-ip>  osac-aap-osac-devel.apps.ocp-sno.osac.local
<server-ip>  console-openshift-console.apps.ocp-sno.osac.local
<server-ip>  fulfillment-api-osac-devel.apps.ocp-sno.osac.local
```

Then browse to `https://osac-aap-osac-devel.apps.ocp-sno.osac.local:9444` (accept the self-signed cert).

| Service | URL |
|---------|-----|
| AAP UI | `https://osac-aap-osac-devel.apps.ocp-sno.osac.local:9444` |
| OCP Console | `https://console-openshift-console.apps.ocp-sno.osac.local:9444` |
| Assisted Installer UI | `http://<server-ip>:8080` |
| Netris Controller | `http://<server-ip>:9443` |

## How deploy-ocp Works

`make deploy-ocp` deploys OCP SNO from a pre-built VM snapshot. It uses a golden qcow2 disk image (cached during `make setup-infra`) and regenerates the cluster's identity (certificates, hostname, IP, domain) using [recert](https://github.com/rh-ecosystem-edge/recert). It uses the `sno-4-22` flavor (OCP only, no OSAC); OSAC is always installed fresh by `deploy-osac`.

The flow runs three Ansible roles in sequence:

1. **`configure-netris`** — discovers h00's Netris server ports by correlating Netris links, leaf-interface MAC addresses, and libvirt tunnel endpoints. It preserves a verified OCP VNet attachment or chooses an unused verified data port, excluding underlay links. It then configures the VPC/VNet and SNAT/DNAT rules.
2. **`configure-dns`** — creates Route 53 DNS records and local dnsmasq config for the cluster domain
3. **`restore-ocp`** — creates copy-on-write disk overlays backed by the cached flavor, grows the h00 OS disk to `ocp_snapshot_disk_gb` for every suite, then mounts it via qemu-nbd and grows the root partition and XFS filesystem before writing pre-boot config (hostname, nodeip hint, dnsmasq overrides, nmstate config for static IP, OVN/OVS cleanup). It runs recert (via JSON config file, matching LCA's approach) to regenerate all TLS certificates and cluster identity, then waits for cluster health.

The snapshot flavor is pulled and cached during `make setup-infra` (one-time ~60GB download). Subsequent deploys use copy-on-write overlays, so only changed blocks are written.

OSAC itself is handled by `make deploy-osac` (not part of `deploy-ocp`).

## How deploy-osac Works

`make deploy-osac` runs in two phases:

1. **`prep-osac`** (Ansible) — clones the osac mono-repo, resolves the OCP release CLI image, patches the Helm values file with all CI-specific settings (the `global.networking` contract with the computed excluded ranges and the tenant network defaults, the Netris manager settings in `aap.instanceGroups.networkFulfillment`, the Netris password in a private values file, DNS/AWS settings, SSH keys, instance group config for cluster fulfillment), enables LVMS and bundled PostgreSQL while preserving the other operator choices in the selected profile, copies license and pull secret to the values directory, and sets up a socat forwarder for OCP ingress on port 9444.

2. **`run-osac-setup`**:
   - Runs the installer's `make install-infra` for the `osac-deps` and `osac-infra` releases.
   - Runs the installer's `make install-osac` for the application release, including template publishing and resource-seeding hooks.

## Configuration

All parameters are in [`inventory/group_vars/all.yml`](inventory/group_vars/all.yml). Override any variable via `EXTRA_VARS`:

```bash
make deploy-ocp EXTRA_VARS="ocp_version=4.22"
make deploy-osac EXTRA_VARS='{"osac_branch": "feature-x"}'
```

### Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ocp_version` | `4.22` | OpenShift version |
| `ocp_cluster_name` | `ocp-sno` | OCP cluster name |
| `lab_name` | `$LAB_NAME` or `default` | Per-lab subdomain prefix (avoids DNS collisions) |
| `dns_hosted_zone` | `ecoeng-osac-ci.devcluster.openshift.com` | Route 53 hosted zone |
| `ocp_base_domain` | `<lab_name>.<dns_hosted_zone>` | DNS base domain (derived) |
| `ocp_server_vcpu` | `20` | OCP VM vCPUs |
| `ocp_server_memory_gb` | `64` | OCP VM RAM (GB) |
| `ocp_subnet_cidr` | `192.168.40.0/24` | OCP VNet subnet |
| `ocp_dnat_ip` | `198.51.100.2` | DNAT IP for OCP API/apps access |
| `osac_namespace` | `osac-e2e-ci` | OSAC Kubernetes namespace |
| `osac_values_file` | `values/caas-ci/values.yaml` | Helm values file |
| `osac_branch` | `main` | osac mono-repo branch |
| `netris_username` | `netris` | Netris API username |
| `netris_password` | *(required)* | Netris API password — set in your local config, validated at deploy time |
| `ew_fabric_enable` | `0` | East-West fabric (0=NS only) |
| `dns_server` | `8.8.8.8` | Upstream DNS server for the lab (override in environments where public DNS is blocked) |
| `caas_cluster_template` | `osac.templates.ocp_small` | Cluster template for BMaaS-backed CaaS; avoids reattaching a worker port already used by its BMI |
| `caas_cluster_name` | `caas-ci-cluster` | CaaS cluster name |
| `caas_baremetal_instance_type` | `ci-worker` | BMaaS BareMetalInstanceType selected for CaaS workers |
| `snapshot_flavor_image` | `quay.io/osac-project/cluster-flavors:sno-4-22` | OCI image containing the OCP SNO snapshot flavor |

```bash
make deploy-ocp EXTRA_VARS="ocp_version=4.18"

# On an installed OSAC lab, deploy-suite runs setup, pytest tenant fixtures,
# suite networking, and the persistent workload in the required order.
make deploy-suite DEPLOY_SUITE=caas CAAS_WORKER_COUNT=1
make deploy-suite DEPLOY_SUITE=maas MAAS_WORKER_COUNT=2
make deploy-suite DEPLOY_SUITE=bmaas
```

#### Lab & Identity

| Variable | Default | Description | Tested |
|----------|---------|-------------|--------|
| `lab_name` | `$LAB_NAME` or `default` | Per-lab subdomain prefix (avoids DNS collisions) | yes |
| `dns_hosted_zone` | `ecoeng-osac-ci.devcluster.openshift.com` | Route 53 hosted zone | yes |
| `ew_fabric_enable` | `0` | East-West fabric (0=NS only, 1=full EW+NS) | no |

#### OCP Installation

| Variable | Default | Description | Tested |
|----------|---------|-------------|--------|
| `ocp_version` | `4.21` | OpenShift version (e.g., `4.18`, `4.19`, `4.21`) | yes (4.18) |
| `ocp_cluster_name` | `ocp-sno` | OCP cluster name | defaults only |
| `ocp_server_vcpu` | `20` | OCP VM vCPUs | yes (16) |
| `ocp_server_memory_gb` | `64` | OCP VM RAM in GB | yes (48) |
| `ocp_install_disk_gb` | `300` | OCP install disk size in GB | defaults only |
| `ocp_lvm_disk_gb` | `300` | LVM storage disk size in GB | defaults only |
| `ocp_snapshot_disk_gb` | `300` | OCP snapshot OS disk size in GB | defaults only |

#### Netris Networking

| Variable | Default | Description | Tested |
|----------|---------|-------------|--------|
| `ocp_vpc_name` | `ocp-sno` | Netris VPC name | defaults only |
| `ocp_subnet_cidr` | `192.168.40.0/24` | OCP VNet subnet | defaults only |
| `ocp_node_ip` | `192.168.40.2` | OCP node static IP | defaults only |
| `ocp_snat_ip` | `198.51.100.1` | SNAT translated IP | defaults only |
| `ocp_dnat_ip` | `198.51.100.2` | DNAT IP for API/apps access | defaults only |
| `osac_external_ip_pool_cidr` | `198.51.100.24/29` | Shared OSAC ExternalIPPool CIDR; host routes/masquerades it toward the softgate. Must not overlap the mgmt nat/l4lb/bgp pools. OSAC creates the Netris allocation itself. | defaults only |
| `osac_external_ip_pool_name` | `netris-lab-public` | Shared pool name created by setup-caas when the CIDR is not already registered | defaults only |
| `netris_username` | `netris` | Netris API username | defaults only |
| `netris_password` | *(required)* | Netris API password — no default, set in local config | yes |
| `dns_server` | `8.8.8.8` | Upstream DNS server threaded through cloud-init, Netris topology, dnsmasq/DHCP, and the OCP NMState resolver. Override in environments where public DNS (8.8.8.8, 1.1.1.1) is unreachable | yes |

`deploy-suite` runs setup, then the deploy playbook runs a small OSAC monorepo
pytest to activate the shared E2E fixtures. They ensure tenant1 and tenant2,
their test users, memberships, and default subnets. The CaaS/MaaS deploy playbook
then configures tenant1's Netris network before creating the cluster. BMaaS
instead deploys one BMI in each tenant with a reusable shared DiskImage and a
BMI type matched to its BMHs. `destroy-bmaas` deletes these named BMIs and waits
for their BMHs to be released before tearing down BMaaS; it keeps the shared
DiskImage for reuse. The tenants remain after pytest exits.
To retry the deployment after setup, run
`make deploy-suite DEPLOY_SUITE=maas SUITE_STAGE=workload` (choose the suite in use).
That stage reruns tenant preparation and, for CaaS/MaaS, the Netris network
check before creating resources. It requires the /opt/osac checkout installed
by deploy-osac and the CI profile's Keycloak test users. `make e2e` runs
setup and then the monorepo suite; its fixtures create tenants when suite tests
exist. Missing CaaS/MaaS Netris test paths cause an error rather than a
successful run.
If an earlier deployment used `test-infra-tenant`, first remove its cluster with
`make force-destroy-maas OSAC_TEST_TENANT_NAME=test-infra-tenant` (or the CaaS
variant). This force cleanup scans all remaining orders and is not isolated
to the named tenant. Switching the default does not delete that tenant or its
cluster.

CaaS tenant network preparation uses tenant1's default network. The
Helm values set `netris_tenant_network_cidr` and `netris_tenant_subnet_cidr` to
`192.168.101.0/24`. These defaults also apply to newly onboarded BMaaS tenants;
they do not change the management or BMaaS provisioning networks, or migrate
existing tenant networks.

During `deploy-caas` or `deploy-maas`, `configure-caas-tenant-network` reserves
ingress `192.168.101.28` by setting the tenant V-Net DHCP range to
`192.168.101.100`–`192.168.101.254`, before workers are attached. The settings
are `caas_netris_ingress_ip`, `caas_tenant_dhcp_start`, and
`caas_tenant_dhcp_end`. It refuses to change DHCP on an already populated V-Net.

The CaaS/MaaS deploy playbook resolves the tenant Subnet and VirtualNetwork to
the Netris V-Net `osac-sn-<Subnet id>` and VPC `osac-vn-<VirtualNetwork id>`
when configuring DHCP. Separate isolated VPCs can reuse `.28`, but two clusters
in the same subnet need distinct ingress VIPs.

Existing tenants with a different subnet require network recreation or a fresh
deployment. Merely rerunning setup does not migrate their CIDR.

Set `dns_server` when the lab host cannot reach public DNS resolvers. Override per-run via `EXTRA_VARS`, or set it permanently in [`inventory/group_vars/all.yml`](inventory/group_vars/all.yml):

```bash
# Per-run override (highest precedence)
make deploy EXTRA_VARS="dns_server=192.168.1.1"
```

```yaml
# Persistent: inventory/group_vars/all.yml
dns_server: "192.168.1.1"
```

#### OSAC Deployment

| Variable | Default | Description | Tested |
|----------|---------|-------------|--------|
| `osac_namespace` | `osac-e2e-ci` | OSAC Kubernetes namespace | yes |
| `osac_values_file` | `values/caas-ci/values.yaml` | Helm values file for OSAC | defaults only |
| `osac_repo` | `https://github.com/osac-project/osac.git` | osac mono-repo git URI | defaults only |
| `osac_branch` | `main` | osac mono-repo git branch | defaults only |
| `netris_private_allocation_cidr` | `10.0.0.0/8` | Always added to `global.networking.excludedIpv4Cidrs` (asserted); the default tenant CIDRs must stay outside it | VMaaS |
| `netris_extra_excluded_cidrs` | `[]` | Extra CIDRs for `global.networking.excludedIpv4Cidrs` | VMaaS |

#### Container Image Overrides

| Variable | Default | Description | Tested |
|----------|---------|-------------|--------|
| `osac_operator_image` | `""` | osac-operator container image override | no |
| `fulfillment_service_image` | `""` | fulfillment-service container image override | no |
| `osac_aap_image` | `""` | osac-aap bootstrap image override | no |
| `osac_ui_image` | `""` | osac-ui container image override | no |
| `bmf_operator_image` | `""` | bare-metal-fulfillment-operator container image override | no |
| `aap_project_git_uri` | `""` | AAP config-as-code project git URI override (defaults to installer value) | no |
| `aap_project_git_branch` | `""` | AAP config-as-code project git branch override (test PR playbooks/collections) | no |

#### Snapshot Deployment (fast path)

The account configured with `quay_username` and `quay_password` must have pull access to
`quay.io/osac-project/cluster-flavors`. Setup logs in with these credentials when it downloads
the flavor image; it reports an actionable error if the credentials are missing or lack access.

| Variable | Default | Description | Tested |
|----------|---------|-------------|--------|
| `snapshot_flavor_image` | `quay.io/osac-project/cluster-flavors:sno-4-22` | OCI image containing the OCP SNO snapshot flavor | defaults only |
| `snapshot_recert_image` | `quay.io/osac-project/recert:latest` | Recert container image | defaults only |

#### CaaS Configuration

| Variable | Default | Description | Tested |
|----------|---------|-------------|--------|
| `caas_cluster_name` | `caas-ci-cluster` | CaaS cluster name | yes (custom) |
| `caas_cluster_template` | `osac.templates.ocp_small` | Cluster template for BMaaS-backed CaaS | defaults only |
| `caas_baremetal_instance_type` | `ci-worker` | BMaaS BareMetalInstanceType selected for CaaS workers | defaults only |
| `caas_worker_vcpu` | `4` | BMaaS worker VM vCPUs | yes (8) |
| `caas_worker_memory_mb` | `16384` | BMaaS worker VM memory in MB | yes (32768) |
| `caas_worker_disk_gb` | `100` | BMaaS worker VM disk in GB | yes (150) |
| `caas_worker_vm_patterns` | `[hgx-pod00-su0-h01..03]` | BMaaS worker VM names | defaults only |
| `caas_worker_count` | `1` | Number of CaaS BMaaS workers requested; MaaS defaults to `2` | defaults only |

## Testing OSAC Components

All components live in the osac mono-repo. Override `osac_branch` to test a specific branch, and use image variables to override container images.

> **Note**: `OSAC_VALUES_FILE` is a **Make-level** variable (not an Ansible `EXTRA_VARS` key). It controls which Helm values file is used for both `prep-osac` and `run-osac-setup`. Pass it directly to `make`, not inside `EXTRA_VARS`. Default: `values/caas-ci/values.yaml`.

### Examples

**Test a feature branch:**
```bash
make destroy-osac
make deploy-osac EXTRA_VARS='{"osac_branch": "feature-x"}'
```

**Test with image overrides:**
```bash
make destroy-osac
make deploy-osac EXTRA_VARS='{"osac_operator_image": "quay.io/osac-project/osac-operator:pr-42", "osac_aap_image": "quay.io/osac-project/osac-aap-ee:pr-99"}'
```

**Test BMaaS with custom operator images:**
```bash
make destroy-osac
make deploy-osac OSAC_VALUES_FILE=values/bmaas-ci/values.yaml \
  EXTRA_VARS="osac_operator_image=quay.io/dmanor/osac-operator:tag bmf_operator_image=quay.io/dmanor/bare-metal-fulfillment-operator:tag bare_metal_services=true"
```

### Netris server labels for BMaaS workers

`prepare-caas-bmaas` installs `test-infra-netris-agents.service` on the hypervisor.
It maps the configured worker VMs' hardware UUIDs to their Netris server names and
sets `netris.server/name` on matching Agents in the OSAC namespace. It runs after
setup exits, so replacement Agents and later scale-out workers receive the label.

The `test-infra-netris-agent-identity` ValidatingAdmissionPolicy blocks binding
only those configured Agents until their label is correct. This prevents the
OSAC controller and AAP networking job from outrunning the label synchronizer.
The policy uses the stable `admissionregistration.k8s.io/v1` API. If the service
is unavailable, those workers wait; inspect it with
`journalctl -u test-infra-netris-agents -n 50`. Setup must run before deployment.
The service and policy remain across cluster teardown for reuse.

BMaaS owns worker power, disks and discovery; setup only reconfigures VMs whose
persistent hardware/disk configuration differs. Existing claimed, deleting, or
non-available BMHs are rejected before VM mutation. Standalone BMaaS retains its
existing defaults; CaaS passes an explicit list of VMs needing reconfiguration.
